import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/unified_export_service.dart';
import 'package:focubili/services/unified_restore_notes.dart';
import 'package:focubili/services/unified_restore_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _manifest = {
  'format': 'focubili.unified-export',
  'version': 1,
  'exportedAt': '2026-11-22T00:00:00.000Z',
  'sections': ['notes'],
  'credentialsIncluded': false,
  'warnings': <String>[],
};

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aBV4AAAAASUVORK5CYII=',
);

VideoNote _note(String id, {String? image, String body = '复习这个概念'}) =>
    VideoNote(
      id: id,
      bvid: 'BV1GJ411x7h7',
      videoTitle: '课程视频',
      ownerName: 'UP主',
      partCid: 712,
      partPageNumber: 2,
      partTitle: '第二集',
      title: '笔记 $id',
      body: body,
      createdAt: DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 2),
      position: const Duration(milliseconds: 12345),
      frames: [
        if (image != null)
          VideoNoteFrame(
            path: image,
            position: const Duration(milliseconds: 18301),
          ),
      ],
    );

Uint8List _archive({
  Map<String, Object?> manifest = _manifest,
  Map<String, Object?> extras = const {},
}) {
  final archive = Archive()
    ..add(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
  for (final entry in extras.entries) {
    final content = entry.value;
    if (content is Uint8List) {
      archive.add(ArchiveFile.bytes(entry.key, content));
    } else {
      archive.add(ArchiveFile.string(entry.key, jsonEncode(content)));
    }
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late VideoNoteService notes;
  late UnifiedRestoreService restore;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('focubili-restore-test-');
    notes = VideoNoteService();
    restore = UnifiedRestoreService(
      notes: UnifiedRestoreNotes(
        notes,
        root: () async => Directory('${sandbox.path}/private-root'),
      ),
    );
  });
  tearDown(() => sandbox.delete(recursive: true));

  test(
    'real exporter result restores a timestamp image, preserves duplicate notes',
    () async {
      final oldFrame = File('${sandbox.path}/source.png');
      await oldFrame.writeAsBytes(_pixel);
      await notes.saveNote(_note('a', image: oldFrame.path));
      await notes.saveNote(_note('b'));
      final packaged = await UnifiedExportService().buildPackage(
        sections: {UnifiedExportSection.notes},
      );
      SharedPreferences.setMockInitialValues({
        'focubili_bilibili_cookie': 'keep-local',
      });
      await notes.saveNote(_note('b', body: '保留本机编辑'));
      final plan = await restore.inspect(packaged.bytes);
      expect(plan.preview.single, '时间点笔记：2 条');
      expect((await notes.loadNotes()).single.body, '保留本机编辑');

      final result = await restore.apply(plan);
      expect(result.added, 1);
      expect(result.kept, 1);
      expect(result.warnings, isEmpty);
      final saved = await notes.loadNotes();
      expect(saved.where((note) => note.id == 'b').single.body, '保留本机编辑');
      final item = saved.where((note) => note.id == 'a').single;
      expect(item.partCid, 712);
      expect(item.partPageNumber, 2);
      expect(item.position.inMilliseconds, 12345);
      expect(item.body, '复习这个概念');
      expect(item.allFrames.single.position.inMilliseconds, 18301);
      final restoredImage = File(item.allFrames.single.path);
      expect(restoredImage.path, startsWith('${sandbox.path}/private-root'));
      expect(restoredImage.path, isNot(oldFrame.path));
      expect(await restoredImage.readAsBytes(), _pixel);
      final again = await restore.apply(plan);
      expect(again.added, 0);
      expect(again.kept, 2);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'focubili_bilibili_cookie',
        ),
        'keep-local',
      );
    },
  );

  test(
    'reopens the ZIP produced by the stable v1.9.0+32 release source',
    () async {
      final legacy = File('test/fixtures/unified-export-v1.9.0-32.zip');
      final plan = await restore.inspect(await legacy.readAsBytes());
      expect(plan.preview.single, '时间点笔记：1 条');
      expect(plan.warnings, isEmpty);
      expect((await restore.apply(plan)).added, 1);
      final note = (await notes.loadNotes()).single;
      expect(note.id, 'from-stable-v190');
      expect(note.body, '  测试文本，无个人数据。');
      expect(note.partPageNumber, 2);
      expect(note.position.inMilliseconds, 4881);
      expect(note.allFrames.single.position.inMilliseconds, 5512);
      expect(await File(note.allFrames.single.path).readAsBytes(), _pixel);
    },
  );

  test(
    'v1.9.0+32 export v1 manifest and v2 notes restore without old absolute paths',
    () async {
      // The tag v1.9.0 (9e24098) writes this note envelope and images path;
      // it writes notes/notes.json only when there were no notes.
      final populated = _archive(
        extras: {
          'notes/focubili_notes.json': {
            'format': 'focubili.video_notes',
            'version': 2,
            'exportedAt': '2026-11-22T00:00:00.000Z',
            'notes': [
              {
                ..._note('legacy').toJson(),
                'framePath': null,
                'frames': [
                  {'path': null, 'positionMs': 4445, 'unavailable': true},
                  {'path': 'images/1_legacy_2.png', 'positionMs': 7168},
                  {'path': 'images/1_legacy_3.png', 'positionMs': 8170},
                ],
              },
            ],
          },
          'notes/images/1_legacy_2.png': _pixel,
          'notes/BV1GJ411x7h7.md': 'human-readable copy',
        },
      );
      final plan = await restore.inspect(populated);
      expect(plan.warnings.single, contains('2 张笔记截图'));
      expect((await restore.apply(plan)).added, 1);
      final item = (await notes.loadNotes()).single;
      expect(item.position.inMilliseconds, 12345);
      expect(item.allFrames.single.position.inMilliseconds, 7168);

      final empty = await restore.inspect(
        _archive(
          extras: {
            'notes/notes.json': {'notes': []},
          },
        ),
      );
      expect(empty.preview.single, '时间点笔记：0 条');
      expect((await restore.apply(empty)).added, 0);
    },
  );

  test(
    'rejects path traversal, absent manifest, truncation, excessive entry and false credentials flag',
    () async {
      Uint8List valid() => _archive(
        extras: {
          'notes/notes.json': {'notes': []},
        },
      );
      final bomb = valid();
      final view = ByteData.sublistView(bomb);
      final central = view.getUint32(bomb.length - 6, Endian.little);
      final local = view.getUint32(central + 42, Endian.little);
      view.setUint32(central + 24, 100 * 1024 * 1024, Endian.little);
      view.setUint32(local + 22, 100 * 1024 * 1024, Endian.little);
      for (final bytes in [
        _archive(
          extras: {
            'notes/notes.json': {'notes': []},
            'notes/../../write.txt': 'bad',
          },
        ),
        ZipEncoder().encodeBytes(
          Archive()..add(ArchiveFile.string('unrelated.txt', 'not a backup')),
        ),
        Uint8List.sublistView(valid(), 0, valid().length - 4),
        bomb,
        _archive(manifest: {..._manifest, 'credentialsIncluded': true}),
        _archive(
          manifest: {
            ..._manifest,
            'sections': ['notes', 'notes'],
          },
          extras: {
            'notes/notes.json': {'notes': []},
          },
        ),
      ]) {
        await expectLater(restore.inspect(bytes), throwsFormatException);
      }
      expect(await notes.loadNotes(), isEmpty);
      expect(await sandbox.list().toList(), isEmpty);
    },
  );

  test(
    'refuses archive-backed notes paths outside the exported images schema',
    () async {
      for (final path in [
        r'C:\Users\Desktop\private.png',
        '../../manifest.json',
        '/tmp/screenshot.png',
        'images/../1_legit_2.png',
      ]) {
        final invalid = _archive(
          extras: {
            'notes/focubili_notes.json': {
              'format': 'focubili.video_notes',
              'version': 2,
              'notes': [
                {
                  ..._note('hostile-reference').toJson(),
                  'framePath': path,
                  'frames': [
                    {'path': path, 'positionMs': 2},
                  ],
                },
              ],
            },
          },
        );
        await expectLater(restore.inspect(invalid), throwsFormatException);
      }
      expect(await notes.loadNotes(), isEmpty);
    },
  );

  test(
    'legacy notes with more than 100 frame records remain readable',
    () async {
      final zip = _archive(
        extras: {
          'notes/focubili_notes.json': {
            'format': 'focubili.video_notes',
            'version': 2,
            'notes': [
              {
                ..._note('many-frames').toJson(),
                'frames': [
                  for (var i = 0; i < 101; i++)
                    {'path': null, 'positionMs': i, 'unavailable': true},
                ],
              },
            ],
          },
        },
      );
      final plan = await restore.inspect(zip);
      expect(plan.warnings.single, contains('101 张笔记截图'));
      expect((await restore.apply(plan)).added, 1);
      expect((await notes.loadNotes()).single.id, 'many-frames');
    },
  );

  test(
    'CRC corruption and duplicate paths are rejected before storage',
    () async {
      final badCrc = _archive(
        extras: {
          'notes/notes.json': {'notes': []},
        },
      );
      final view = ByteData.sublistView(badCrc);
      final central = view.getUint32(badCrc.length - 6, Endian.little);
      final local = view.getUint32(central + 42, Endian.little);
      final changed = view.getUint32(central + 16, Endian.little) ^ 1;
      view.setUint32(central + 16, changed, Endian.little);
      view.setUint32(local + 14, changed, Endian.little);
      await expectLater(restore.inspect(badCrc), throwsFormatException);

      final collision = _archive(
        extras: {
          'notes/notes.json': {'notes': []},
          'NOTES/NOTES.JSON': {'notes': []},
        },
      );
      await expectLater(restore.inspect(collision), throwsFormatException);
      expect(await notes.loadNotes(), isEmpty);
    },
  );

  test(
    'fresh history export fills only missing search terms and watch rows',
    () async {
      const searchKey = 'focubili_search_history';
      const watchKey = 'focubili_watch_history';
      final watch = {
        'bvid': 'BV1GJ411x7h7',
        'title': '播放记录',
        'ownerName': 'UP',
        'lastPartTitle': '第一节',
        'lastPartPageNumber': 1,
        'watchedAt': '2026-11-21T00:00:00.000Z',
        'lastPositionMs': 4417,
      };
      SharedPreferences.setMockInitialValues({
        searchKey: ['基础化学', '概率论'],
        watchKey: jsonEncode([watch]),
      });
      final zip = await UnifiedExportService().buildPackage(
        sections: {UnifiedExportSection.history},
      );
      SharedPreferences.setMockInitialValues({
        searchKey: ['本机搜索', '概率论'],
      });
      final plan = await restore.inspect(zip.bytes);
      final result = await restore.apply(plan);
      expect(result.added, 2);
      expect(result.kept, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(searchKey), ['本机搜索', '概率论', '基础化学']);
      expect(jsonDecode(prefs.getString(watchKey)!), [watch]);
      expect((await restore.apply(plan)).added, 0);
    },
  );

  test(
    'standalone media and informational archive sections never become device state',
    () async {
      final plan = await restore.inspect(
        _archive(
          manifest: {
            ..._manifest,
            'sections': ['offline', 'diagnostics', 'subtitles'],
          },
          extras: {
            'offline.json': {
              'values': {'focubili_offline_videos_v1': '/old/movie.mp4'},
            },
            'subtitles.json': {'tracks': []},
            'diagnostics.txt': 'info only',
          },
        ),
      );
      expect(plan.preview, isEmpty);
      expect(plan.warnings, hasLength(3));
      expect((await restore.apply(plan)).added, 0);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );
}
