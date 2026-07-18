import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 把 Flutter 分享卡渲染成 PNG，并交给系统分享面板，不经过开发者服务器。
class FocusShareService {
  /// 创建专注分享服务；服务本身不保存用户状态。
  const FocusShareService();

  /// 捕获指定 RepaintBoundary、写入临时 PNG，然后打开系统分享面板。
  Future<void> shareBoundary({
    required GlobalKey boundaryKey,
    required String fileName,
    required String text,
    Rect? sharePositionOrigin,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    final BuildContext? boundaryContext = boundaryKey.currentContext;
    final RenderObject? renderObject = boundaryContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw StateError('分享卡尚未完成绘制。');
    }
    final ui.Image image = await renderObject.toImage(pixelRatio: 3);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (data == null) {
        throw StateError('无法生成分享图片。');
      }
      final Uint8List bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final Directory temporaryDirectory = await getTemporaryDirectory();
      final String safeFileName = _safePngName(fileName);
      final File output = File('${temporaryDirectory.path}/$safeFileName');
      await output.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(output.path, mimeType: 'image/png')],
          fileNameOverrides: <String>[safeFileName],
          text: text,
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
    } finally {
      image.dispose();
    }
  }

  /// 清理外部传入的文件名，确保临时分享文件始终是安全 PNG 名称。
  String _safePngName(String value) {
    final String safe = value
        .replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return '${safe.isEmpty ? 'focubili_focus' : safe}.png';
  }
}
