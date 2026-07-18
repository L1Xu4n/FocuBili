import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'video_note_export_service.dart';

/// 把笔记导出包或笔记分享卡交给系统分享面板，所有临时文件只写入本机缓存。
class VideoNoteShareService {
  /// 创建笔记分享服务；测试可替换临时目录和系统分享调用。
  const VideoNoteShareService({
    this.temporaryDirectoryLoader,
    this.shareLauncher,
  });

  final Future<Directory> Function()? temporaryDirectoryLoader;
  final Future<ShareResult> Function(ShareParams params)? shareLauncher;

  /// 把批量导出包写成临时文件并分享，文件名和 MIME 类型与实际格式保持一致。
  Future<void> shareExportPackage(
    VideoNoteExportPackage package, {
    Rect? sharePositionOrigin,
  }) async {
    final File output = await writeExportPackage(package);
    await _share(
      ShareParams(
        files: <XFile>[
          XFile(output.path, mimeType: _mimeTypeFor(package.extension)),
        ],
        fileNameOverrides: <String>[package.fileName],
        text: '焦点哔哩时间点笔记，共 ${package.noteCount} 条。',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  /// 把导出包写入指定目录；公开此步骤便于验证文件内容且不必唤起系统面板。
  Future<File> writeExportPackage(
    VideoNoteExportPackage package, {
    Directory? directory,
  }) async {
    final Directory target = directory ?? await _temporaryDirectory();
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final File output = File(
      '${target.path}/${_safeFileName(package.fileName)}',
    );
    await output.writeAsBytes(package.bytes, flush: true);
    return output;
  }

  /// 捕获完整笔记卡为长 PNG，并在预览确认后交给系统分享面板。
  Future<void> shareBoundary({
    required GlobalKey boundaryKey,
    required String fileName,
    required String text,
    Rect? sharePositionOrigin,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    final RenderObject? renderObject = boundaryKey.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw StateError('笔记分享卡尚未完成绘制。');
    }
    final double pixelRatio = _pixelRatioFor(renderObject.size);
    final ui.Image image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (data == null) {
        throw StateError('无法生成笔记分享图片。');
      }
      final Uint8List bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final Directory directory = await _temporaryDirectory();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final String safeName = '${_safeBaseName(fileName)}.png';
      final File output = File('${directory.path}/$safeName');
      await output.writeAsBytes(bytes, flush: true);
      await _share(
        ShareParams(
          files: <XFile>[XFile(output.path, mimeType: 'image/png')],
          fileNameOverrides: <String>[safeName],
          text: text,
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
    } finally {
      image.dispose();
    }
  }

  /// 长图按高度动态降低像素倍率，避免长正文超过设备纹理上限。
  double _pixelRatioFor(Size size) {
    if (size.height <= 0 || size.width <= 0) {
      return 1;
    }
    final double byHeight = 12000 / size.height;
    final double byWidth = 4000 / size.width;
    return math.min(3, math.min(byHeight, byWidth)).clamp(0.25, 3).toDouble();
  }

  /// 读取应用临时目录，目录缺失时由系统提供方负责创建。
  Future<Directory> _temporaryDirectory() {
    return temporaryDirectoryLoader?.call() ?? getTemporaryDirectory();
  }

  /// 调用可注入的分享函数，默认使用 share_plus 系统面板。
  Future<ShareResult> _share(ShareParams params) {
    return shareLauncher?.call(params) ?? SharePlus.instance.share(params);
  }

  /// 根据导出扩展名提供接收 App 更容易识别的 MIME 类型。
  String _mimeTypeFor(String extension) {
    return switch (extension) {
      'md' => 'text/markdown',
      'json' => 'application/json',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  /// 清理任意导出文件名，同时保留合法扩展名。
  String _safeFileName(String value) {
    final int dot = value.lastIndexOf('.');
    final String base = dot > 0 ? value.substring(0, dot) : value;
    final String extension = dot > 0 ? value.substring(dot + 1) : '';
    final String safeBase = _safeBaseName(base);
    final String safeExtension = extension.replaceAll(
      RegExp(r'[^0-9A-Za-z]'),
      '',
    );
    return safeExtension.isEmpty ? safeBase : '$safeBase.$safeExtension';
  }

  /// 把文件主体限制为跨平台安全字符，空值回退为稳定默认名。
  String _safeBaseName(String value) {
    final String safe = value
        .replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'focubili_note' : safe;
  }
}
