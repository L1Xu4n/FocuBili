import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:focubili/features/notes/video_note_detail_page.dart';
import 'package:focubili/features/notes/video_notes_page.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/video_note_service.dart';

const _storageKey = 'flutter.${VideoNoteService.storageKey}';
const _cover = 'https://example.invalid/cover.jpg';
const _writeError = '删除笔记失败，请稍后重试。';

class _NoteDisk extends InMemorySharedPreferencesStore {
  _NoteDisk() : super.withData({});

  bool rejectWrite = false;
  bool rejectRead = false;
  Object? throwOnWrite;
  Completer<void>? writeEntered;
  Completer<bool>? holdWrite;
  int noteWrites = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    if (rejectRead) throw StateError('存储暂时不可读');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == _storageKey) {
      noteWrites++;
      final gate = holdWrite;
      if (gate != null) {
        holdWrite = null;
        writeEntered!.complete();
        if (!await gate.future) return false;
      }
      final failure = throwOnWrite;
      if (failure != null) {
        throwOnWrite = null;
        throw failure;
      }
      if (rejectWrite) {
        rejectWrite = false;
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }

  Future<Map<String, dynamic>> rows() async {
    final raw = (await super.getAll())[_storageKey] as String;
    return {
      for (final row in jsonDecode(raw) as List)
        (row as Map<String, dynamic>)['id'] as String: row,
    };
  }
}

class _OfflineVideoService extends Fake implements BilibiliService {
  @override
  Future<VideoPreview> lookupVideo(String input) async =>
      throw StateError('没有网络');
}

VideoNote _note(String id, {String? framePath}) => VideoNote(
  id: id,
  bvid: 'BV123456789$id',
  videoTitle: '测试课程',
  ownerName: '讲师',
  partCid: 1,
  partPageNumber: 1,
  partTitle: '第一讲',
  title: '课程笔记 $id',
  body: '已保存正文 $id',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  position: Duration.zero,
  framePath: framePath,
);

Future<File> _frameFile() async {
  final folder = await Directory.systemTemp.createTemp('focubili-note-write-');
  addTearDown(() => folder.delete(recursive: true));
  return File('${folder.path}/keep.png').writeAsBytes([1, 2, 3]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NoteDisk disk;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    disk = _NoteDisk();
    SharedPreferencesStorePlatform.instance = disk;
    SharedPreferences.resetStatic();
  });

  test(
    'rejected delete cannot be committed by another service filling a cover',
    () async {
      final author = VideoNoteService();
      final coverWorker = VideoNoteService();
      final a = _note('a');
      final b = _note('b');
      final prefs = await SharedPreferences.getInstance();
      final originalA = {
        ...a.toJson(),
        'futureField': ['保留原始字段'],
      };
      await prefs.setString(
        VideoNoteService.storageKey,
        jsonEncode([originalA, b.toJson()]),
      );

      disk.rejectWrite = true;
      await expectLater(
        author.deleteNote(a.id),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', '笔记删除失败'),
        ),
      );
      expect((await disk.rows())['a'], originalA);
      expect(await coverWorker.fillMissingCovers(b.bvid, _cover), {'b'});
      final saved = await disk.rows();
      expect(saved['a'], originalA);
      expect(saved['b'], {...b.toJson(), 'videoCoverUrl': _cover});
    },
  );

  test(
    'thrown save does not change original note, files or later writes',
    () async {
      final editor = VideoNoteService();
      final reader = VideoNoteService();
      final frame = await _frameFile();
      final a = _note('a', framePath: frame.path);
      final b = _note('b');
      await editor.saveNote(a);
      await editor.saveNote(b);

      final failure = StateError('平台抛出的原始异常');
      disk.throwOnWrite = failure;
      await expectLater(
        editor.saveNote(a.copyWith(body: '未保存正文', clearFrame: true)),
        throwsA(same(failure)),
      );
      await reader.deleteNote(b.id);
      expect(await disk.rows(), {'a': a.toJson()});
      expect(await frame.exists(), isTrue);
    },
  );

  test(
    'rejected cover does not hitch a ride on a later successful edit',
    () async {
      final service = VideoNoteService();
      final a = _note('a');
      final b = _note('b');
      await service.saveNote(a);
      await service.saveNote(b);

      disk.rejectWrite = true;
      await expectLater(
        service.fillMissingCovers(a.bvid, _cover),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', '封面保存失败'),
        ),
      );
      final updatedB = b.copyWith(body: '已提交的修改');
      await service.saveNote(updatedB);
      expect(await disk.rows(), {'a': a.toJson(), 'b': updatedB.toJson()});
    },
  );

  test(
    'failed reload blocks cache consumers and retains referenced frames',
    () async {
      final author = VideoNoteService();
      final other = VideoNoteService();
      final frame = await _frameFile();
      final a = _note('a', framePath: frame.path);
      final b = _note('b');
      await author.saveNote(a);
      await author.saveNote(b);
      disk.rejectRead = true;
      disk.rejectWrite = true;
      await expectLater(
        author.deleteNote(a.id),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', '笔记删除失败'),
        ),
      );
      final attempted = disk.noteWrites;
      expect(await other.loadNotes(), isEmpty);
      await other.discardUnreferencedFrame(frame.path);
      expect(await frame.exists(), isTrue);
      await expectLater(
        other.fillMissingCovers(b.bvid, _cover),
        throwsStateError,
      );
      expect(disk.noteWrites, attempted);
      expect(await disk.rows(), {'a': a.toJson(), 'b': b.toJson()});

      disk.rejectRead = false;
      expect(
        (await other.loadNotes()).map((note) => note.id),
        unorderedEquals(['a', 'b']),
      );
      expect(await other.fillMissingCovers(b.bvid, _cover), {'b'});
      expect((await disk.rows())['a'], a.toJson());
      expect(await frame.exists(), isTrue);
    },
  );

  test('reads and cleanup wait for a pending delete to settle', () async {
    final editor = VideoNoteService();
    final other = VideoNoteService();
    final frame = await _frameFile();
    final a = _note('a', framePath: frame.path);
    await editor.saveNote(a);

    final gate = disk.holdWrite = Completer<bool>();
    final entered = disk.writeEntered = Completer<void>();
    final rejected = expectLater(editor.deleteNote(a.id), throwsStateError);
    await entered.future;
    final cleanup = other.discardUnreferencedFrame(frame.path);
    final read = other.loadNotes();
    gate.complete(false);
    await rejected;
    expect((await read).single.id, 'a');
    await cleanup;
    expect(await frame.exists(), isTrue);
  });

  for (final detail in [false, true]) {
    testWidgets(
      'rejected delete stays on ${detail ? 'detail' : 'list'} and can retry',
      (tester) async {
        final service = VideoNoteService();
        final a = _note('a');
        final b = _note('b');
        await service.saveNote(a);
        await service.saveNote(b);
        await tester.pumpWidget(
          MaterialApp(
            home: VideoNotesPage(
              noteService: service,
              videoService: _OfflineVideoService(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tile = find.byKey(const Key('managed-video-note-a'));
        final body = find.byKey(const Key('note-detail-body-field'));
        final search = find.byKey(const Key('video-notes-search-field'));
        await tester.enterText(search, '课程');
        await tester.pumpAndSettle();
        if (detail) {
          await tester.tap(tile);
          await tester.pumpAndSettle();
          await tester.enterText(body, '未保存草稿');
        }
        Future<void> confirmDelete() async {
          if (detail) {
            await tester.tap(find.byKey(const Key('delete-note-from-detail')));
            await tester.pumpAndSettle();
          } else {
            await tester.tap(
              find.byKey(const Key('managed-video-note-menu-a')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('删除笔记').last);
            await tester.pumpAndSettle();
          }
          await tester.tap(find.widgetWithText(FilledButton, '删除'));
          await tester.pumpAndSettle();
        }

        disk.rejectWrite = true;
        await confirmDelete();
        expect(tester.takeException(), isNull);
        expect(find.text(_writeError), findsOneWidget);
        expect(
          (await service.loadNotes())
              .firstWhere((note) => note.id == a.id)
              .body,
          a.body,
        );
        if (detail) {
          expect(find.byType(VideoNoteDetailPage), findsOneWidget);
          expect(find.text('未保存草稿'), findsOneWidget);
        } else {
          expect(find.byType(VideoNoteDetailPage), findsNothing);
          expect(tile, findsOneWidget);
          expect(find.text('课程'), findsOneWidget);
        }

        await confirmDelete();
        expect(tester.takeException(), isNull);
        expect(find.byType(VideoNoteDetailPage), findsNothing);
        expect(tile, findsNothing);
        expect(find.text('课程'), findsOneWidget);
        expect(find.text(_writeError), findsNothing);
        expect((await service.loadNotes()).single.id, b.id);
      },
    );
  }
}
