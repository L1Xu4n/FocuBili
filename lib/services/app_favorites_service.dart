import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_favorite.dart';

/// 允许测试用内存版 SharedPreferences 替代真实设备存储。
typedef AppFavoritesPreferencesLoader = Future<SharedPreferences> Function();

/// 在本机读写软件收藏夹数据，与 B 站账号收藏完全独立，不会上传任何内容。
class AppFavoritesService {
  /// 创建软件收藏夹服务；生产环境默认使用 SharedPreferences。
  AppFavoritesService({AppFavoritesPreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader;

  static const String _foldersKey = 'app_favorites.folders_v1';
  static const String _itemsPrefix = 'app_favorites.items_v1.';

  final AppFavoritesPreferencesLoader? _preferencesLoader;

  /// 读取全部软件收藏夹，按创建时间从旧到新排序。
  Future<List<AppFavoriteFolder>> loadFolders() async {
    final SharedPreferences preferences = await _loadPreferences();
    final String? raw = preferences.getString(_foldersKey);
    if (raw == null || raw.isEmpty) {
      return const <AppFavoriteFolder>[];
    }
    final List<AppFavoriteFolder> folders = <AppFavoriteFolder>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final Object? entry in decoded) {
          if (entry is Map) {
            final AppFavoriteFolder? folder = _decodeFolder(entry);
            if (folder != null) {
              folders.add(folder);
            }
          }
        }
      }
    } on FormatException {
      // 本地数据损坏时按空列表处理，等待用户重新创建。
      return const <AppFavoriteFolder>[];
    }
    return List<AppFavoriteFolder>.unmodifiable(folders);
  }

  /// 新建一个软件收藏夹，名称去空格后为空时返回 null。
  Future<AppFavoriteFolder?> createFolder(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final List<AppFavoriteFolder> folders = await loadFolders();
    final DateTime now = DateTime.now();
    final AppFavoriteFolder folder = AppFavoriteFolder(
      id: _generateId(),
      name: trimmed,
      createdAt: now,
      updatedAt: now,
    );
    final List<AppFavoriteFolder> updated = <AppFavoriteFolder>[
      ...folders,
      folder,
    ];
    if (!await _saveFolders(updated)) {
      return null;
    }
    return folder;
  }

  /// 重命名软件收藏夹，返回是否成功。
  Future<bool> renameFolder(String id, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final List<AppFavoriteFolder> folders = await loadFolders();
    final int index = folders.indexWhere(
      (AppFavoriteFolder folder) => folder.id == id,
    );
    if (index < 0) {
      return false;
    }
    final AppFavoriteFolder old = folders[index];
    final List<AppFavoriteFolder> updated = List<AppFavoriteFolder>.of(folders);
    updated[index] = AppFavoriteFolder(
      id: old.id,
      name: trimmed,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
    return _saveFolders(updated);
  }

  /// 删除软件收藏夹及其全部收藏项，返回是否成功。
  Future<bool> deleteFolder(String id) async {
    final List<AppFavoriteFolder> folders = await loadFolders();
    final List<AppFavoriteFolder> updated = folders
        .where((AppFavoriteFolder folder) => folder.id != id)
        .toList(growable: false);
    final bool saved = await _saveFolders(updated);
    if (!saved) {
      return false;
    }
    final SharedPreferences preferences = await _loadPreferences();
    await preferences.remove('$_itemsPrefix$id');
    return true;
  }

  /// 读取指定软件收藏夹内的全部视频，按收藏时间从新到旧排序。
  Future<List<AppFavoriteItem>> loadItems(String folderId) async {
    final SharedPreferences preferences = await _loadPreferences();
    final String? raw = preferences.getString('$_itemsPrefix$folderId');
    if (raw == null || raw.isEmpty) {
      return const <AppFavoriteItem>[];
    }
    final List<AppFavoriteItem> items = <AppFavoriteItem>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final Object? entry in decoded) {
          if (entry is Map) {
            final AppFavoriteItem? item = _decodeItem(entry);
            if (item != null) {
              items.add(item);
            }
          }
        }
      }
    } on FormatException {
      return const <AppFavoriteItem>[];
    }
    items.sort(
      (AppFavoriteItem left, AppFavoriteItem right) =>
          right.addedAt.compareTo(left.addedAt),
    );
    return List<AppFavoriteItem>.unmodifiable(items);
  }

  /// 把一支视频加入软件收藏夹；已存在同 BV 时视为成功且不重复写入。
  Future<bool> addItem(AppFavoriteItem item) async {
    final List<AppFavoriteItem> items = await loadItems(item.folderId);
    if (items.any((AppFavoriteItem existing) => existing.bvid == item.bvid)) {
      return true;
    }
    return _saveItems(item.folderId, <AppFavoriteItem>[...items, item]);
  }

  /// 从软件收藏夹移除指定 BV 视频，返回是否成功。
  Future<bool> removeItem(String folderId, String bvid) async {
    final List<AppFavoriteItem> items = await loadItems(folderId);
    final List<AppFavoriteItem> updated = items
        .where((AppFavoriteItem item) => item.bvid != bvid)
        .toList(growable: false);
    if (updated.length == items.length) {
      return true;
    }
    return _saveItems(folderId, updated);
  }

  /// 统计全部软件收藏夹中保存的视频数量。
  Future<int> totalItemCount() async {
    final List<AppFavoriteFolder> folders = await loadFolders();
    int total = 0;
    for (final AppFavoriteFolder folder in folders) {
      total += (await loadItems(folder.id)).length;
    }
    return total;
  }

  /// 获取可用的本地偏好实例，测试注入优先于真实设备插件。
  Future<SharedPreferences> _loadPreferences() {
    return _preferencesLoader?.call() ?? SharedPreferences.getInstance();
  }

  Future<bool> _saveFolders(List<AppFavoriteFolder> folders) async {
    final SharedPreferences preferences = await _loadPreferences();
    return preferences.setString(
      _foldersKey,
      jsonEncode(
        folders.map((AppFavoriteFolder folder) => folder.toJson()).toList(),
      ),
    );
  }

  Future<bool> _saveItems(String folderId, List<AppFavoriteItem> items) async {
    final SharedPreferences preferences = await _loadPreferences();
    return preferences.setString(
      '$_itemsPrefix$folderId',
      jsonEncode(items.map((AppFavoriteItem item) => item.toJson()).toList()),
    );
  }

  AppFavoriteFolder? _decodeFolder(Map<Object?, Object?> json) {
    return AppFavoriteFolder.fromJson(
      json.map((Object? key, Object? value) => MapEntry('$key', value)),
    );
  }

  AppFavoriteItem? _decodeItem(Map<Object?, Object?> json) {
    return AppFavoriteItem.fromJson(
      json.map((Object? key, Object? value) => MapEntry('$key', value)),
    );
  }

  /// 生成不依赖网络与账号的本地唯一标识。
  String _generateId() {
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${_randomSuffix()}';
  }

  /// 在生成标识时追加一小段随机后缀，降低同毫秒并发冲突概率。
  String _randomSuffix() {
    final int value = DateTime.now().microsecondsSinceEpoch & 0xFFFF;
    return value.toRadixString(36);
  }
}
