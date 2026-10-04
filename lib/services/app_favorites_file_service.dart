import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../models/app_favorites_backup.dart';

/// 使用系统文件选择器交换备份；手机使用系统文档服务，桌面使用另存为。
class AppFavoritesFileService {
  /// 创建不依赖账号或固定下载目录的文件服务。
  const AppFavoritesFileService();

  /// 选择一个备份；取消时返回空值，读取时兼容字节、流和本机缓存路径。
  Future<AppFavoritesBackup?> pickBackup() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '导入软件收藏夹',
      type: FileType.custom,
      allowedExtensions: ['json'],
      withReadStream: true,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return null;
    return AppFavoritesBackup.fromBytes(await readFile(result.files.single));
  }

  /// 限制实际读取大小，兼容云文档缓存和 macOS 仅返回路径的选择器。
  Future<Uint8List> readFile(PlatformFile file) async {
    if (file.size > AppFavoritesBackup.maxBytes) {
      throw const FormatException('收藏夹文件超过 20 MB，请分收藏夹导出后导入。');
    }
    if (file.bytes != null) {
      if (file.bytes!.length > AppFavoritesBackup.maxBytes) {
        throw const FormatException('收藏夹文件超过 20 MB。');
      }
      return file.bytes!;
    }
    final stream =
        file.readStream ??
        (file.path == null ? null : File(file.path!).openRead());
    if (stream == null) throw const FileSystemException('无法读取所选文件。');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > AppFavoritesBackup.maxBytes) {
        throw const FormatException('收藏夹文件超过 20 MB。');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 把实际字节交给插件写入，各原生平台只有成功保存才返回 true。
  Future<bool> saveBackup(AppFavoritesBackup backup) async =>
      await FilePicker.saveFile(
        dialogTitle: '导出软件收藏夹',
        fileName: backup.fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: backup.toBytes(),
        lockParentWindow: true,
      ) !=
      null;
}
