import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_favorite.dart';
import '../models/video_preview.dart';

/// Allows isolated in-memory storage in tests.
typedef AppFavoritesPreferencesLoader = Future<SharedPreferences> Function();

/// Stores local folders independently of the online account.
class AppFavoritesService {
  /// Accepts an optional preference provider without reading account data.
  AppFavoritesService({AppFavoritesPreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader;
  static const _foldersKey = 'app_favorites.folders_v1';
  static const _itemsPrefix = 'app_favorites.items_v1.';
  static Future<void> _queue = Future<void>.value();
  static int _idSequence = 0;
  final AppFavoritesPreferencesLoader? _preferencesLoader;
  final Map<String, Future<int?>> _partCounts = {};

  /// Hydrates missing legacy P counts once per service, without blocking folder rendering.
  Future<int?> resolvePartCount(
    AppFavoriteItem item,
    Future<VideoPreview> Function(String) lookup,
  ) {
    if (item.partCount != null && item.partCount! > 0) {
      return Future.value(item.partCount);
    }
    return _partCounts.putIfAbsent(item.bvid, () async {
      try {
        final video = await lookup(item.bvid);
        if (video.fromOfflineCache || video.parts.isEmpty) return null;
        final count = video.parts.length;
        await _mutate(() async {
          for (final folder in await loadFolders()) {
            final items = await loadItems(folder.id);
            if (!items.any((entry) => entry.bvid == item.bvid)) continue;
            if (!await _saveItems(
              folder.id,
              items
                  .map(
                    (entry) => entry.bvid == item.bvid
                        ? entry.withPartCount(count)
                        : entry,
                  )
                  .toList(),
            )) {
              throw StateError('P count was not saved');
            }
          }
        });
        return count;
      } catch (_) {
        return null;
      }
    });
  }

  /// Serializes complete mutations across all service instances, including failures.
  Future<T> _mutate<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  /// Uses only the injected or local preferences backend.
  Future<SharedPreferences> _loadPreferences() =>
      _preferencesLoader?.call() ?? SharedPreferences.getInstance();

  /// Decodes strictly so damaged records cannot be silently overwritten.
  List<T> _decode<T>(String? raw, T? Function(Map<String, Object?>) parser) {
    if (raw == null || raw.isEmpty) return <T>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException();
      return decoded.map<T>((entry) {
        if (entry is! Map) throw const FormatException();
        final item = parser(Map<String, Object?>.from(entry));
        if (item == null) throw const FormatException();
        return item;
      }).toList();
    } catch (_) {
      throw const FormatException('本机收藏数据损坏，原始数据已保留。');
    }
  }

  /// Restores folders without changing the original stored content.
  Future<List<AppFavoriteFolder>> loadFolders() async {
    final prefs = await _loadPreferences();
    return List.unmodifiable(
      _decode(prefs.getString(_foldersKey), AppFavoriteFolder.fromJson),
    );
  }

  /// Creates a folder in the shared write queue, returning null on persistence failure.
  Future<AppFavoriteFolder?> createFolder(String name) => _mutate(() async {
    if (name.trim().isEmpty) return null;
    final folders = await loadFolders();
    final now = DateTime.now();
    final folder = AppFavoriteFolder(
      id: '${now.microsecondsSinceEpoch}-${_idSequence++}',
      name: name.trim(),
      createdAt: now,
      updatedAt: now,
    );
    return await _saveFolders([...folders, folder]) ? folder : null;
  });

  /// Renames a folder without overwriting a concurrent folder creation.
  Future<bool> renameFolder(String id, String name) => _mutate(() async {
    if (name.trim().isEmpty) return false;
    final folders = (await loadFolders()).toList();
    final index = folders.indexWhere((folder) => folder.id == id);
    if (index < 0) return false;
    final old = folders[index];
    folders[index] = AppFavoriteFolder(
      id: old.id,
      name: name.trim(),
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
    return _saveFolders(folders);
  });

  /// Removes metadata before item cleanup; failed cleanup restores the folder list.
  Future<bool> deleteFolder(String id) => _mutate(() async {
    final folders = await loadFolders();
    if (!await _saveFolders(
      folders.where((folder) => folder.id != id).toList(),
    )) {
      return false;
    }
    try {
      final prefs = await _loadPreferences();
      if (!await prefs.remove('$_itemsPrefix$id')) {
        throw StateError('remove failed');
      }
      return true;
    } catch (_) {
      await _saveFolders(folders);
      return false;
    }
  });

  /// Restores the newest items first and refuses to discard damaged entries.
  Future<List<AppFavoriteItem>> loadItems(String folderId) async {
    final prefs = await _loadPreferences();
    final items = _decode(
      prefs.getString('$_itemsPrefix$folderId'),
      AppFavoriteItem.fromJson,
    );
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return List.unmodifiable(items);
  }

  /// Adds a unique BV only while its folder still exists.
  Future<bool> addItem(AppFavoriteItem item) => _mutate(() async {
    if (!(await loadFolders()).any((folder) => folder.id == item.folderId)) {
      return false;
    }
    final items = await loadItems(item.folderId);
    if (items.any((existing) => existing.bvid == item.bvid)) return true;
    return _saveItems(item.folderId, [...items, item]);
  });

  /// 一次保存一页导入视频，按 BV 去重；写入失败返回空值，成功返回新增数。
  Future<int?> addItems(String folderId, List<AppFavoriteItem> incoming) =>
      _mutate(() async {
        if (incoming.any((item) => item.folderId != folderId) ||
            !(await loadFolders()).any((folder) => folder.id == folderId)) {
          return null;
        }
        final items = await loadItems(folderId);
        final ids = items.map((item) => item.bvid).toSet();
        final additions = incoming.where((item) => ids.add(item.bvid)).toList();
        if (additions.isEmpty) return 0;
        return await _saveItems(folderId, [...items, ...additions])
            ? additions.length
            : null;
      });

  /// Removes a BV within the same queue as additions and folder deletions.
  Future<bool> removeItem(String folderId, String bvid) => _mutate(() async {
    final items = await loadItems(folderId);
    return _saveItems(
      folderId,
      items.where((item) => item.bvid != bvid).toList(),
    );
  });

  /// Counts saved items across all current folders.
  Future<int> totalItemCount() async {
    int total = 0;
    for (final folder in await loadFolders()) {
      total += (await loadItems(folder.id)).length;
    }
    return total;
  }

  /// Saves metadata and reports a rejected or failed write to the caller.
  Future<bool> _saveFolders(List<AppFavoriteFolder> folders) async {
    try {
      final prefs = await _loadPreferences();
      return await prefs.setString(
        _foldersKey,
        jsonEncode(folders.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      return false;
    }
  }

  /// Saves items without ever treating a failed write as successful.
  Future<bool> _saveItems(String id, List<AppFavoriteItem> items) async {
    try {
      final prefs = await _loadPreferences();
      return await prefs.setString(
        '$_itemsPrefix$id',
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      return false;
    }
  }
}
