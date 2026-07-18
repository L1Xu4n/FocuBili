import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/video_note_export_service.dart';
import 'package:focubili/services/video_note_share_service.dart';
import 'package:share_plus/share_plus.dart';

/// 创建一条固定笔记，测试可选择是否附带本机截图。
VideoNote _note({String? framePath}) {
  return VideoNote(
    id: 'note-1',
    bvid: 'BV1GJ411x7h7',
    videoTitle: '集合的三种常见运算',
    ownerName: '数学老师',
    partCid: 1001,
    partPageNumber: 6,
    partTitle: '交并补运算',
    title: '德摩根律',
    body: '交集和并集的补集关系。',
    createdAt: DateTime(2026, 7, 19, 8),
    updatedAt: DateTime(2026, 7, 19, 8, 5),
    position: const Duration(minutes: 12, seconds: 34),
    framePath: framePath,
  );
}

/// 验证 Markdown、JSON 与截图打包规则。
void main() {
  /// 验证无截图时直接生成可读取的 Markdown 文件。
  test('无图片笔记直接导出Markdown', () async {
    final VideoNoteExportPackage package = await const VideoNoteExportService()
        .buildPackage(<VideoNote>[_note()], VideoNoteExportFormat.markdown);

    expect(package.extension, 'md');
    expect(package.imageCount, 0);
    final String markdown = utf8.decode(package.bytes);
    expect(markdown, contains('# 焦点哔哩时间点笔记'));
    expect(markdown, contains('`12:34`'));
    expect(markdown, contains('德摩根律'));
  });

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
    final ArchiveFile? imageFile = archive.find('images/note-1.png');

    expect(package.extension, 'zip');
    expect(package.imageCount, 1);
    expect(jsonFile, isNotNull);
    expect(imageFile?.content, <int>[137, 80, 78, 71]);
    final Map<String, dynamic> document =
        jsonDecode(utf8.decode(jsonFile!.content)) as Map<String, dynamic>;
    expect(document['format'], 'focubili.video_notes');
    expect(document['version'], 1);
    expect(
      (document['notes'] as List<dynamic>).single['framePath'],
      'images/note-1.png',
    );
  });

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
    expect(sharedParams!.files!.single.mimeType, 'text/markdown');
    final File sharedFile = File(sharedParams!.files!.single.path);
    expect(await sharedFile.readAsBytes(), package.bytes);
  });
}
