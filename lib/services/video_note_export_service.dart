import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/video_note.dart';

/// 定义用户可选择的笔记导出主文件格式。
enum VideoNoteExportFormat { markdown, json }

/// 保存已经生成、可直接交给系统“另存为”的导出文件。
class VideoNoteExportPackage {
  /// 创建导出包，并记录其中的笔记和图片数量供界面提示。
  const VideoNoteExportPackage({
    required this.fileName,
    required this.bytes,
    required this.noteCount,
    required this.imageCount,
  });

  final String fileName;
  final Uint8List bytes;
  final int noteCount;
  final int imageCount;

  /// 返回导出文件扩展名，供系统文件选择器限制类型。
  String get extension => fileName.split('.').last.toLowerCase();
}

/// 把选中的本地笔记转换成 Markdown 或可回导 JSON，并在需要时打包图片。
class VideoNoteExportService {
  /// 创建无状态导出服务；所有导出内容只在当前设备内生成。
  const VideoNoteExportService();

  /// 生成导出文件：无图片时直接返回 md/json，有图片时返回含 images 目录的 zip。
  Future<VideoNoteExportPackage> buildPackage(
    List<VideoNote> notes,
    VideoNoteExportFormat format,
  ) async {
    if (notes.isEmpty) {
      throw ArgumentError.value(notes, 'notes', '至少选择一条笔记。');
    }
    final Map<String, Uint8List> images = <String, Uint8List>{};
    final Map<String, String> imagePathsByNoteId = <String, String>{};
    for (final VideoNote note in notes) {
      final String? sourcePath = note.framePath;
      if (sourcePath == null || sourcePath.trim().isEmpty) {
        continue;
      }
      try {
        final File file = File(sourcePath);
        if (!await file.exists()) {
          continue;
        }
        final String extension = _safeImageExtension(sourcePath);
        final String archivePath = 'images/${_safeName(note.id)}.$extension';
        images[archivePath] = await file.readAsBytes();
        imagePathsByNoteId[note.id] = archivePath;
      } catch (_) {
        // 单张旧截图损坏时继续导出其余文字和可用图片，不让整个任务失败。
      }
    }
    final String mainExtension = switch (format) {
      VideoNoteExportFormat.markdown => 'md',
      VideoNoteExportFormat.json => 'json',
    };
    final String mainName = 'focubili_notes.$mainExtension';
    final String content = switch (format) {
      VideoNoteExportFormat.markdown => _buildMarkdown(
        notes,
        imagePathsByNoteId,
      ),
      VideoNoteExportFormat.json => _buildJson(notes, imagePathsByNoteId),
    };
    final String timestamp = _fileTimestamp(DateTime.now());
    if (images.isEmpty) {
      return VideoNoteExportPackage(
        fileName: 'focubili_notes_$timestamp.$mainExtension',
        bytes: Uint8List.fromList(utf8.encode(content)),
        noteCount: notes.length,
        imageCount: 0,
      );
    }
    final Archive archive = Archive()
      ..add(ArchiveFile.string(mainName, content));
    for (final MapEntry<String, Uint8List> image in images.entries) {
      archive.add(ArchiveFile.bytes(image.key, image.value));
    }
    archive.add(
      ArchiveFile.string(
        'README.txt',
        '主文件：$mainName\n图片目录：images/\n'
            '由焦点哔哩本地导出，共 ${notes.length} 条笔记。',
      ),
    );
    return VideoNoteExportPackage(
      fileName: 'focubili_notes_$timestamp.zip',
      bytes: ZipEncoder().encodeBytes(archive),
      noteCount: notes.length,
      imageCount: images.length,
    );
  }

  /// 生成通用 Markdown，元数据使用普通列表，截图使用相对路径便于其他软件读取。
  String _buildMarkdown(
    List<VideoNote> notes,
    Map<String, String> imagePathsByNoteId,
  ) {
    final StringBuffer buffer = StringBuffer('# 焦点哔哩时间点笔记\n\n');
    for (final VideoNote note in notes) {
      buffer
        ..writeln('## ${_escapeMarkdown(note.title)}')
        ..writeln()
        ..writeln('- 视频：${_escapeMarkdown(note.videoTitle)}')
        ..writeln('- UP：${_escapeMarkdown(note.ownerName)}')
        ..writeln('- BV：`${note.bvid}`')
        ..writeln(
          '- 分P：P${note.partPageNumber} ${_escapeMarkdown(note.partTitle)}',
        )
        ..writeln('- 时间点：`${_formatPosition(note.position)}`')
        ..writeln('- 创建时间：${note.createdAt.toIso8601String()}')
        ..writeln('- 更新时间：${note.updatedAt.toIso8601String()}')
        ..writeln();
      if (note.body.isNotEmpty) {
        buffer
          ..writeln(note.body)
          ..writeln();
      }
      final String? imagePath = imagePathsByNoteId[note.id];
      if (imagePath != null) {
        buffer
          ..writeln('![${_escapeMarkdown(note.title)}]($imagePath)')
          ..writeln();
      }
      buffer.writeln('---\n');
    }
    return buffer.toString();
  }

  /// 生成带版本号的 JSON；笔记字段保持 VideoNote 结构，图片路径改为包内相对地址。
  String _buildJson(
    List<VideoNote> notes,
    Map<String, String> imagePathsByNoteId,
  ) {
    final Map<String, Object?> document = <String, Object?>{
      'format': 'focubili.video_notes',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'notes': notes
          .map((VideoNote note) {
            final Map<String, Object?> json = Map<String, Object?>.from(
              note.toJson(),
            );
            json['framePath'] = imagePathsByNoteId[note.id];
            return json;
          })
          .toList(growable: false),
    };
    return const JsonEncoder.withIndent('  ').convert(document);
  }

  /// 把视频位置格式化为可读的“时:分:秒”或“分:秒”。
  String _formatPosition(Duration position) {
    final int hours = position.inHours;
    final String minutes = position.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final String seconds = position.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  /// 转义 Markdown 标题和元数据中最常见的控制字符。
  String _escapeMarkdown(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAllMapped(
          RegExp(r'([`*_\[\]#])'),
          // 转义替换函数在控制字符前添加反斜线，避免标题被解析成格式语法。
          (Match match) => '\\${match.group(1)}',
        );
  }

  /// 只允许常见图片扩展名进入导出包，未知格式按 png 处理。
  String _safeImageExtension(String path) {
    final String fileName = path.replaceAll('\\', '/').split('/').last;
    final int dotIndex = fileName.lastIndexOf('.');
    final String extension = dotIndex >= 0
        ? fileName.substring(dotIndex + 1).toLowerCase()
        : '';
    return <String>{'png', 'jpg', 'jpeg', 'webp'}.contains(extension)
        ? extension
        : 'png';
  }

  /// 把笔记编号清理为安全文件名，阻止路径分隔符进入 ZIP 条目。
  String _safeName(String value) {
    final String safe = value.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_');
    return safe.isEmpty ? 'note' : safe;
  }

  /// 生成不含冒号的本地时间戳，确保 Android、Windows 等平台都能保存。
  String _fileTimestamp(DateTime value) {
    return '${value.year}${_twoDigits(value.month)}${_twoDigits(value.day)}_'
        '${_twoDigits(value.hour)}${_twoDigits(value.minute)}'
        '${_twoDigits(value.second)}';
  }

  /// 把单个数字补成两位，供时间戳稳定拼接。
  String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
