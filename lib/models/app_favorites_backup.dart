import 'dart:convert';
import 'dart:typed_data';

import 'app_favorite.dart';

/// 保存可在设备之间迁移的软件收藏夹及其视频，不包含账号会话。
class AppFavoritesBackup {
  /// 创建不可变的收藏快照，保留空文件夹和每个视频的原收藏时间。
  AppFavoritesBackup({
    required List<AppFavoriteFolder> folders,
    required Map<String, List<AppFavoriteItem>> items,
    required this.exportedAt,
  }) : folders = List.unmodifiable(folders),
       items = Map.unmodifiable({
         for (final folder in folders)
           folder.id: List<AppFavoriteItem>.unmodifiable(
             items[folder.id] ?? [],
           ),
       });

  static const format = 'focubili.app-favorites';
  static const version = 1;
  static const maxBytes = 20 * 1024 * 1024;
  final List<AppFavoriteFolder> folders;
  final Map<String, List<AppFavoriteItem>> items;
  final DateTime exportedAt;

  /// 统计收藏记录；同一视频在不同文件夹中分别计数。
  int get itemCount =>
      items.values.fold(0, (total, entries) => total + entries.length);

  /// 生成各系统都能直接保存的文件名，避免日期中的冒号。
  String get fileName =>
      'FocuBili-favorites-${exportedAt.toUtc().microsecondsSinceEpoch}.json';

  /// 序列化为 UTF-8 JSON，并保证导出的文件可以被同一版本完整回导。
  Uint8List toBytes() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'format': format,
          'version': version,
          'exportedAt': exportedAt.toIso8601String(),
          'folders': [
            for (final folder in folders)
              {
                ...folder.toJson(),
                'items': [for (final item in items[folder.id]!) item.toJson()],
              },
          ],
        }),
      ),
    );
    fromBytes(bytes);
    return bytes;
  }

  /// 完整校验后才返回备份，拒绝不支持的版本、损坏字段和错误目录引用。
  static AppFavoritesBackup fromBytes(List<int> bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('收藏夹文件超过 20 MB，请分收藏夹导出后导入。');
    }
    try {
      final text = utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
      final root = jsonDecode(text);
      if (root is! Map || root['format'] != format) {
        throw const FormatException('请选择焦点哔哩导出的软件收藏夹 JSON 文件。');
      }
      if (root['version'] != version) {
        throw const FormatException('不支持这个收藏夹备份版本，请升级焦点哔哩后重试。');
      }
      final exportedAt = _date(root, 'exportedAt');
      if (root['folders'] is! List) throw const FormatException();
      final folders = <AppFavoriteFolder>[];
      final items = <String, List<AppFavoriteItem>>{};
      for (final entry in root['folders'] as List) {
        if (entry is! Map) throw const FormatException();
        final id = _string(entry, 'id', nonEmpty: true);
        if (items.containsKey(id)) throw const FormatException();
        final name = _string(entry, 'name', nonEmpty: true);
        final createdAt = _date(entry, 'createdAt');
        final updatedAt = _date(entry, 'updatedAt');
        if (entry['items'] is! List) throw const FormatException();
        final entries = <AppFavoriteItem>[];
        for (final raw in entry['items'] as List) {
          if (raw is! Map || _string(raw, 'folderId') != id) {
            throw const FormatException();
          }
          final bvid = _string(raw, 'bvid');
          if (!RegExp(r'^BV[0-9A-Za-z]{10}$').hasMatch(bvid)) {
            throw const FormatException();
          }
          final partCount = raw['partCount'];
          if (partCount != null && (partCount is! int || partCount <= 0)) {
            throw const FormatException();
          }
          entries.add(
            AppFavoriteItem(
              folderId: id,
              bvid: bvid,
              title: _string(raw, 'title'),
              coverUrl: _optionalString(raw, 'coverUrl'),
              ownerName: _optionalString(raw, 'ownerName'),
              durationText: _optionalString(raw, 'durationText'),
              addedAt: _date(raw, 'addedAt'),
              partCount: partCount as int?,
            ),
          );
        }
        folders.add(
          AppFavoriteFolder(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
        );
        items[id] = entries;
      }
      return AppFavoritesBackup(
        folders: folders,
        items: items,
        exportedAt: exportedAt,
      );
    } on FormatException catch (error) {
      if (error.message.startsWith('请选择') || error.message.startsWith('不支持')) {
        rethrow;
      }
      throw const FormatException('收藏夹文件损坏或字段不完整，未导入任何内容。');
    } catch (_) {
      throw const FormatException('收藏夹文件损坏或字段不完整，未导入任何内容。');
    }
  }

  /// 读取必须存在的字符串，名称和标识不可为空。
  static String _string(Map json, String key, {bool nonEmpty = false}) {
    final value = json[key];
    if (value is! String || (nonEmpty && value.trim().isEmpty)) {
      throw const FormatException();
    }
    return value;
  }

  /// 兼容未记录可选展示字段的备份，同时拒绝错误的字段类型。
  static String _optionalString(Map json, String key) =>
      json[key] == null ? '' : _string(json, key);

  /// 拒绝无效时间，避免用默认时间悄悄替换损坏数据。
  static DateTime _date(Map json, String key) {
    final date = DateTime.tryParse(_string(json, key));
    if (date == null) throw const FormatException();
    return date;
  }
}

/// 仅报告已经成功保存的文件夹和视频数量。
class AppFavoritesBackupImportResult {
  /// 创建合并导入结果。
  const AppFavoritesBackupImportResult({
    required this.createdFolders,
    required this.importedItems,
    required this.duplicates,
  });

  final int createdFolders;
  final int importedItems;
  final int duplicates;
}
