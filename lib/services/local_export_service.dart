import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';

/// 仅含用户选择导出的内容，不持有账号、Cookie 或网络响应。
class LocalExportRequest {
  const LocalExportRequest({
    required this.fileName,
    required this.bytes,
    this.dialogTitle = '保存导出文件',
  });
  final String fileName;
  final Uint8List bytes;
  final String dialogTitle;
  String get extension => fileName.split('.').last.toLowerCase();
}

enum LocalExportStage { save, verify }

/// 错误仅公开平台、阶段及安全错误码，不把本机路径或平台原始详情展示出来。
class LocalExportException implements Exception {
  const LocalExportException({
    required this.platform,
    required this.stage,
    required this.code,
  });
  final AppPlatform platform;
  final LocalExportStage stage;
  final String code;
  String get diagnosticCode => '${platform.name}/${stage.name}/$code';
  String get message => '导出失败，请检查存储位置和写入权限后重试。诊断码：$diagnosticCode';
  @override
  String toString() => message;
}

/// file_picker 11 已在所有支持平台写入 bytes；桌面返回前再校验实际文件。
class LocalExportService {
  const LocalExportService({this.saveDialog, this.verifyFile, this.platform});
  final Future<String?> Function(LocalExportRequest)? saveDialog;
  final Future<void> Function(String path, int expectedLength)? verifyFile;
  final AppPlatform? platform;

  /// 返回 null 代表用户取消；Android 的 content URI 由系统文档提供方管理。
  Future<String?> save({
    required String fileName,
    required Uint8List bytes,
    String dialogTitle = '保存导出文件',
  }) async {
    final currentPlatform = platform ?? AppPlatformDetector.current;
    final request = LocalExportRequest(
      fileName: fileName,
      bytes: bytes,
      dialogTitle: dialogTitle,
    );
    String? path;
    var stage = LocalExportStage.save;
    try {
      path = await (saveDialog ?? _showSaveDialog)(request);
      if (path == null) return null;
      if (currentPlatform.isDesktop) {
        stage = LocalExportStage.verify;
        await (verifyFile ?? _verifyFile)(path, bytes.length);
      }
      return path;
    } catch (error) {
      throw LocalExportException(
        platform: currentPlatform,
        stage: stage,
        code: _safeCode(error),
      );
    }
  }

  static Future<String?> _showSaveDialog(LocalExportRequest request) =>
      FilePicker.saveFile(
        dialogTitle: request.dialogTitle,
        fileName: request.fileName,
        type: FileType.custom,
        allowedExtensions: <String>[request.extension],
        bytes: request.bytes,
      );

  static Future<void> _verifyFile(String path, int expectedLength) async {
    final file = File(path);
    if (!await file.exists()) throw StateError('missing_file');
    if (await file.length() != expectedLength) {
      throw StateError('size_mismatch');
    }
  }

  static String _safeCode(Object error) {
    if (error is FileSystemException) {
      return 'io_${error.osError?.errorCode ?? 'unknown'}';
    }
    if (error is PlatformException) {
      final code = error.code;
      return RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(code)
          ? code
          : 'platform_error';
    }
    if (error is StateError &&
        const ['missing_file', 'size_mismatch'].contains(error.message)) {
      return error.message;
    }
    if (error is MissingPluginException) return 'plugin_unavailable';
    return 'unexpected_error';
  }
}
