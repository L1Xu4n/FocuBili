import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../platform/app_platform.dart';

/// 使用系统文档服务保存 JSON；桌面选择器只选择路径，仍需应用写入实际内容。
class DataTransferFileService {
  /// 创建文件服务，测试可替换选择窗口并使用合成内容和临时目录。
  const DataTransferFileService({this.platform, this.saveDialog});

  final AppPlatform? platform;
  final Future<String?> Function(String name, Uint8List bytes)? saveDialog;

  /// 取消返回 false；写入失败向上传递，只有保存成功才允许界面报告完成。
  Future<bool> saveJson(String name, String content) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    final path =
        await (saveDialog?.call(name, bytes) ??
            FilePicker.saveFile(
              dialogTitle: '保存焦点哔哩数据',
              fileName: name,
              type: FileType.custom,
              allowedExtensions: ['json'],
              bytes: bytes,
              lockParentWindow: true,
            ));
    if (path == null) return false;
    if ((platform ?? AppPlatformDetector.current).isDesktop) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return true;
  }
}
