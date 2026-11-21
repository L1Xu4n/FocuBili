import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/video_note_export_service.dart';
import 'package:focubili/services/video_note_share_service.dart';
import 'package:focubili/services/local_export_service.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:share_plus/share_plus.dart';

/// 创建一条固定笔记，测试可选择是否附带本机截图。
VideoNote _note({
  String? framePath,
  String id = 'note-1',
  String bvid = 'BV1GJ411x7h7',
  int page = 6,
  String title = '德摩根律',
  Duration position = const Duration(minutes: 12, seconds: 34),
}) {
  return VideoNote(
    id: id,
    bvid: bvid,
    videoTitle: '集合的三种常见运算',
    ownerName: '数学老师',
    partCid: 995 + page,
    partPageNumber: page,
    partTitle: '交并补运算',
    title: title,
    body: '交集和并集的补集关系。',
    createdAt: DateTime(2026, 7, 19, 8),
    updatedAt: DateTime(2026, 7, 19, 8, 5),
    position: position,
    framePath: framePath,
  );
}

/// 验证 Markdown、JSON 与截图打包规则。
void main() {
  test(
    'Linux share fallback keeps cancellation distinct from a saved export',
    () async {
      final service = VideoNoteShareService(
        platform: AppPlatform.linux,
        localExportService: LocalExportService(
          platform: AppPlatform.linux,
          saveDialog: (_) async => null,
        ),
      );
      final package = await const VideoNoteExportService().buildPackage([
        _note(),
      ], VideoNoteExportFormat.markdown);
      expect(await service.shareExportPackage(package), isFalse);
    },
  );
  test('Apple 首次使用不存在的临时目录也能导出', () async {
    final root = await Directory.systemTemp.createTemp(
      'focubili_apple_export_',
    );
    addTearDown(() => root.delete(recursive: true));
    final missing = Directory('${root.path}/new/cache');
    final service = VideoNoteShareService(
      temporaryDirectoryLoader: () async => missing,
    );
    final package = await const VideoNoteExportService().buildPackage([
      _note(),
    ], VideoNoteExportFormat.markdown);
    final file = await service.writeExportPackage(package);
    expect(await file.readAsBytes(), package.bytes);
  });

  test('无图片也导出一个含 notes/ 的 Markdown ZIP', () async {
    final VideoNoteExportPackage package = await const VideoNoteExportService()
        .buildPackage(<VideoNote>[_note()], VideoNoteExportFormat.markdown);

    expect(package.extension, 'zip');
    expect(package.imageCount, 0);
    final archive = ZipDecoder().decodeBytes(package.bytes);
    const entryName = 'notes/BV1GJ411x7h7.md';
    expect(archive.files.map((file) => file.name), [entryName]);
    final String markdown = utf8.decode(archive.find(entryName)!.content);
    expect(markdown, contains('# 焦点哔哩时间点笔记'));
    expect(markdown, contains('`12:34`'));
    expect(markdown, contains('德摩根律'));
  });

  test('groups by BV rather than by title, part, or timestamp', () async {
    final notes = [
      _note(title: '第一条'),
      _note(id: 'other-video', bvid: 'BV1Q541167Qg', page: 1, title: '另一视频'),
      _note(
        id: 'other-part',
        page: 7,
        title: '第二条',
        position: const Duration(seconds: 18, milliseconds: 50),
      ),
    ];
    final package = await const VideoNoteExportService().buildPackage(
      notes,
      VideoNoteExportFormat.markdown,
    );
    final archive = ZipDecoder().decodeBytes(package.bytes);
    expect(
      archive.files.map((file) => file.name),
      unorderedEquals(['notes/BV1GJ411x7h7.md', 'notes/BV1Q541167Qg.md']),
    );
    final first = utf8.decode(archive.find('notes/BV1GJ411x7h7.md')!.content);
    final second = utf8.decode(archive.find('notes/BV1Q541167Qg.md')!.content);
    expect(first, allOf(contains('第一条'), contains('P6'), contains('12:34')));
    expect(
      first,
      allOf(contains('第二条'), contains('P7'), contains('00:18.050')),
    );
    expect(first, isNot(contains('另一视频')));
    expect(second, contains('另一视频'));
    expect(second, isNot(contains('第一条')));
    expect(package.noteCount, 3);
  });

  test(
    'malformed and case-colliding BV identifiers cannot collide or escape notes/',
    () async {
      final notes = [
        _note(id: 'a', bvid: '../intro', title: '一'),
        _note(id: 'b', bvid: 'BV1GJ411x7h7', title: '二'),
        _note(id: 'c', bvid: 'BV1gj411x7h7', title: '三'),
      ];
      final service = const VideoNoteExportService();
      final archive = ZipDecoder().decodeBytes(
        (await service.buildPackage(
          notes,
          VideoNoteExportFormat.markdown,
        )).bytes,
      );
      final reordered = ZipDecoder().decodeBytes(
        (await service.buildPackage(
          notes.reversed.toList(),
          VideoNoteExportFormat.markdown,
        )).bytes,
      );
      final names = archive.files.map((file) => file.name);
      expect(names.toSet(), hasLength(3));
      expect(names, everyElement(matches(r'^notes/video-[a-f0-9]{64}\.md$')));
      expect(names, unorderedEquals(reordered.files.map((file) => file.name)));
    },
  );

  test(
    'standalone no-image JSON keeps v2 shape and round-trips a note',
    () async {
      final source = _note();
      final package = await const VideoNoteExportService().buildPackage([
        source,
      ], VideoNoteExportFormat.json);
      expect(package.extension, 'json');
      final json =
          jsonDecode(utf8.decode(package.bytes)) as Map<String, dynamic>;
      expect(json.keys, ['format', 'version', 'exportedAt', 'notes']);
      expect(json['format'], 'focubili.video_notes');
      expect(json['version'], 2);
      final row = (json['notes'] as List).single as Map<String, dynamic>;
      expect(row, {...source.toJson(), 'framePath': null, 'frames': []});
      expect(VideoNote.tryParse(row)!.toJson(), source.toJson());
    },
  );

  /// 验证带截图时生成 ZIP，JSON 使用包内相对图片路径。
  test('带图片笔记导出JSON和images压缩包', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'focubili_note_export_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final File frame = File('${directory.path}/frame.png');
    await frame.writeAsBytes(<int>[137, 80, 78, 71]);

    final VideoNoteExportPackage package = await const VideoNoteExportService()
        .buildPackage(<VideoNote>[
          _note(framePath: frame.path),
        ], VideoNoteExportFormat.json);
    final Archive archive = ZipDecoder().decodeBytes(package.bytes);
    final ArchiveFile? jsonFile = archive.find('focubili_notes.json');
    final ArchiveFile? imageFile = archive.find('images/1_note-1_1.png');

    expect(package.extension, 'zip');
    expect(package.imageCount, 1);
    expect(jsonFile, isNotNull);
    expect(imageFile?.content, <int>[137, 80, 78, 71]);
    final Map<String, dynamic> document =
        jsonDecode(utf8.decode(jsonFile!.content)) as Map<String, dynamic>;
    expect(document['format'], 'focubili.video_notes');
    expect(document['version'], 2);
    expect(
      (document['notes'] as List<dynamic>).single['framePath'],
      'images/1_note-1_1.png',
    );
  });

  test(
    'multiple exported frames retain order, millisecond times and missing entries',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focubili-export-frames-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = await File('${directory.path}/a.png').writeAsBytes([1, 2]);
      final second = await File('${directory.path}/b.jpg').writeAsBytes([3, 4]);
      const source = '    x = 2\n\n**公式**\n';
      final note = _note().copyWith(
        body: source,
        frames: [
          VideoNoteFrame(
            path: second.path,
            position: const Duration(milliseconds: 20015),
          ),
          VideoNoteFrame(
            path: '${directory.path}/missing.png',
            position: const Duration(seconds: 3),
          ),
          VideoNoteFrame(
            path: first.path,
            position: const Duration(milliseconds: 10005),
          ),
        ],
      );
      final package = await const VideoNoteExportService().buildPackage([
        note,
      ], VideoNoteExportFormat.json);
      expect(package.imageCount, 2);
      expect(package.missingImageCount, 1);
      final archive = ZipDecoder().decodeBytes(package.bytes);
      final content = utf8.decode(archive.find('focubili_notes.json')!.content);
      expect(content, isNot(contains(directory.path)));
      final json = jsonDecode(content) as Map<String, dynamic>;
      expect(json['notes'][0]['body'], source);
      final frames = json['notes'][0]['frames'] as List;
      expect(frames.map((frame) => frame['positionMs']), [20015, 3000, 10005]);
      expect(frames[0]['path'], 'images/1_note-1_1.jpg');
      expect(frames[1]['path'], isNull);
      expect(frames[1]['unavailable'], isTrue);
      expect(frames[2]['path'], 'images/1_note-1_3.png');
      final markdownPackage = await const VideoNoteExportService().buildPackage(
        [note],
        VideoNoteExportFormat.markdown,
      );
      final markdownArchive = ZipDecoder().decodeBytes(markdownPackage.bytes);
      expect(markdownPackage.imageCount, 2);
      expect(markdownPackage.missingImageCount, 1);
      final markdown = utf8.decode(
        markdownArchive.find('notes/BV1GJ411x7h7.md')!.content,
      );
      final links = RegExp(
        r'!\[[^\]]*\]\(([^)]+)\)',
      ).allMatches(markdown).map((match) => match.group(1)!);
      expect(links, ['images/1_note-1_1.jpg', 'images/1_note-1_3.png']);
      expect(markdownArchive.find('notes/${links.first}')!.content, [3, 4]);
      expect(markdownArchive.find('notes/${links.last}')!.content, [1, 2]);
      expect(markdown, contains(source));
      expect(
        markdown.indexOf('00:20.015'),
        lessThan(markdown.indexOf('00:03')),
      );
      expect(markdown, contains('00:10.005'));
      expect(markdown, contains('画面文件缺失或无法读取'));
    },
  );

  /// 验证批量分享先生成真实文件，再把正确文件名与 MIME 类型交给系统面板。
  test('批量笔记导出包可写入临时目录并分享', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'focubili_note_share_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    ShareParams? sharedParams;
    final VideoNoteShareService shareService = VideoNoteShareService(
      temporaryDirectoryLoader: () async => directory,
      shareLauncher: (ShareParams params) async {
        sharedParams = params;
        return const ShareResult('test', ShareResultStatus.success);
      },
    );
    final VideoNoteExportPackage package = await const VideoNoteExportService()
        .buildPackage(<VideoNote>[_note()], VideoNoteExportFormat.markdown);

    await shareService.shareExportPackage(package);

    expect(sharedParams, isNotNull);
    expect(sharedParams!.fileNameOverrides, <String>[package.fileName]);
    expect(sharedParams!.files!.single.mimeType, 'application/zip');
    final File sharedFile = File(sharedParams!.files!.single.path);
    expect(await sharedFile.readAsBytes(), package.bytes);
  });
}
