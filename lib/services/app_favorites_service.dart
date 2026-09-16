import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_favorite.dart';

/// 定义软件收藏夹使用的可替换存储读取器，便于单元测试使用内存配置。
typedef AppFavoritesPreferencesLoader = Future<SharedPreferences> Function();

/// 在当前设备保存软件内独立的收藏夹数据，不写入 B 站账号。
///
/// 支持自建收藏夹、在看视频时收藏、从 B 站账号收藏夹导入，以及把本机
/// 收藏数据导出为 JSON 文件或从 JSON 文件恢复。
class AppFavoritesService {
  /// 创建软件收藏夹服务；未传入读取器时使用设备上的 SharedPreferences。
  AppFavoritesService({AppFavoritesPreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _storageKey = 'focubili_app_favorites_v1';

  /// 限制本机最多保存的收藏条目数，避免长期使用后偏好设置无限增长。
  static const int maximumItems = 2000;

  /// 限制本机最多保存的收藏夹数量。
  static const int maximumFolders = 100;

  final AppFavoritesPreferencesLoader _preferencesLoader;

  /// 读取全部软件收藏夹，按创建时间从早到晚排序。
  Future<List<AppFavoriteFolder>> loadFolders() async {
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    return List<AppFavoriteFolder>.unmodifiable(snapshot.folders);
  }

  /// 读取指定收藏夹内的全部条目，按收藏时间从新到旧排序。
  Future<List<AppFavoriteItem>> loadItems(String folderId) async {
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    final List<AppFavoriteItem> items =
        snapshot.items
            .where((AppFavoriteItem item) => item.folderId == folderId)
            .toList(growable: false)
          ..sort((AppFavoriteItem left, AppFavoriteItem right) {
            final int addedComparison = right.addedAt.compareTo(left.addedAt);
            return addedComparison != 0
                ? addedComparison
                : left.bvid.compareTo(right.bvid);
          });
    return List<AppFavoriteItem>.unmodifiable(items);
  }

  /// 判断指定 BV 是否已出现在任一软件收藏夹中。
  Future<bool> isFavorited(String bvid) async {
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return false;
    }
    return snapshot.items.any(
      (AppFavoriteItem item) => item.bvid == normalizedBvid,
    );
  }

  /// 新建一个软件收藏夹；名称去除首尾空白后为空时返回 null。
  Future<AppFavoriteFolder?> createFolder(String name) async {
    final String normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      return null;
    }
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    if (snapshot.folders.length >= maximumFolders) {
      return null;
    }
    final AppFavoriteFolder folder = AppFavoriteFolder.create(normalizedName);
    await _saveSnapshot(
      snapshot.copyWith(
        folders: <AppFavoriteFolder>[...snapshot.folders, folder],
      ),
    );
    return folder;
  }

  /// 重命名指定收藏夹，并返回是否成功。
  Future<bool> renameFolder(String folderId, String name) async {
    final String normalizedName = name.trim();
    if (folderId.isEmpty || normalizedName.isEmpty) {
      return false;
    }
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    final int index = snapshot.folders.indexWhere(
      (AppFavoriteFolder folder) => folder.id == folderId,
    );
    if (index < 0) {
      return false;
    }
    final List<AppFavoriteFolder> folders = List<AppFavoriteFolder>.of(
      snapshot.folders,
    );
    folders[index] = folders[index].copyWith(
      name: normalizedName,
      updatedAt: DateTime.now(),
    );
    await _saveSnapshot(snapshot.copyWith(folders: folders));
    return true;
  }

  /// 删除指定收藏夹及其全部条目，并返回是否成功。
  Future<bool> deleteFolder(String folderId) async {
    if (folderId.isEmpty) {
      return false;
    }
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    if (!snapshot.folders.any(
      (AppFavoriteFolder folder) => folder.id == folderId,
    )) {
      return false;
    }
    await _saveSnapshot(
      snapshot.copyWith(
        folders: snapshot.folders
            .where((AppFavoriteFolder folder) => folder.id != folderId)
            .toList(growable: false),
        items: snapshot.items
            .where((AppFavoriteItem item) => item.folderId != folderId)
            .toList(growable: false),
      ),
    );
    return true;
  }

  /// 收藏一条视频到指定收藏夹；同夹内同 BV 不会重复添加，并返回是否新增。
  Future<bool> addItem(AppFavoriteItem item) async {
    final String normalizedBvid = item.bvid.trim();
    if (normalizedBvid.isEmpty || item.folderId.isEmpty) {
      return false;
    }
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    if (!snapshot.folders.any(
      (AppFavoriteFolder folder) => folder.id == item.folderId,
    )) {
      return false;
    }
    if (snapshot.items.any(
      (AppFavoriteItem existing) =>
          existing.folderId == item.folderId && existing.bvid == normalizedBvid,
    )) {
      return false;
    }
    if (snapshot.items.length >= maximumItems) {
      return false;
    }
    final List<AppFavoriteItem> items = List<AppFavoriteItem>.of(snapshot.items)
      ..add(
        AppFavoriteItem(
          folderId: item.folderId,
          bvid: normalizedBvid,
          title: item.title.trim(),
          coverUrl: item.coverUrl.trim(),
          ownerName: item.ownerName.trim(),
          durationText: item.durationText.trim(),
          addedAt: DateTime.now(),
          sourceLabel: item.sourceLabel,
        ),
      );
    await _saveSnapshot(snapshot.copyWith(items: items));
    return true;
  }

  /// 从指定收藏夹移除一条视频，并返回是否已存在被移除。
  Future<bool> removeItem(String folderId, String bvid) async {
    final String normalizedBvid = bvid.trim();
    if (folderId.isEmpty || normalizedBvid.isEmpty) {
      return false;
    }
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    final List<AppFavoriteItem> items = snapshot.items
        .where(
          (AppFavoriteItem item) =>
              item.folderId != folderId || item.bvid != normalizedBvid,
        )
        .toList(growable: false);
    if (items.length == snapshot.items.length) {
      return false;
    }
    await _saveSnapshot(snapshot.copyWith(items: items));
    return true;
  }

  /// 批量导入条目到指定收藏夹，并返回本次实际新增的条目数。
  Future<int> importItems(String folderId, List<AppFavoriteItem> items) async {
    if (folderId.isEmpty) {
      return 0;
    }
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    if (!snapshot.folders.any(
      (AppFavoriteFolder folder) => folder.id == folderId,
    )) {
      return 0;
    }
    final Set<String> existingKeys = snapshot.items
        .where((AppFavoriteItem item) => item.folderId == folderId)
        .map((AppFavoriteItem item) => item.bvid)
        .toSet();
    final List<AppFavoriteItem> additions = <AppFavoriteItem>[];
    for (final AppFavoriteItem item in items) {
      final String normalizedBvid = item.bvid.trim();
      if (normalizedBvid.isEmpty ||
          existingKeys.contains(normalizedBvid) ||
          snapshot.items.length + additions.length >= maximumItems) {
        continue;
      }
      existingKeys.add(normalizedBvid);
      additions.add(
        AppFavoriteItem(
          folderId: folderId,
          bvid: normalizedBvid,
          title: item.title.trim(),
          coverUrl: item.coverUrl.trim(),
          ownerName: item.ownerName.trim(),
          durationText: item.durationText.trim(),
          addedAt: DateTime.now(),
          sourceLabel: item.sourceLabel,
        ),
      );
    }
    if (additions.isEmpty) {
      return 0;
    }
    await _saveSnapshot(
      snapshot.copyWith(
        items: <AppFavoriteItem>[...snapshot.items, ...additions],
      ),
    );
    return additions.length;
  }

  /// 把全部收藏夹和条目导出为可分享的 JSON 文本。
  Future<String> exportJson() async {
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    return jsonEncode(snapshot.toJson());
  }

  /// 从 JSON 文本恢复收藏夹与条目，返回新增数量；格式不合法时返回空结果。
  ///
  /// 导入采用合并策略：已存在的收藏夹会继续追加内容，不会覆盖用户现有数据。
  Future<AppFavoriteImportResult> importJson(String jsonText) async {
    final String trimmed = jsonText.trim();
    if (trimmed.isEmpty) {
      return const AppFavoriteImportResult(folderCount: 0, itemCount: 0);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on Object {
      return const AppFavoriteImportResult(folderCount: 0, itemCount: 0);
    }
    if (decoded is! Map) {
      return const AppFavoriteImportResult(folderCount: 0, itemCount: 0);
    }
    final Map<String, dynamic> source = Map<String, dynamic>.from(decoded);
    final List<AppFavoriteFolder> importedFolders = <AppFavoriteFolder>[];
    final Object? rawFolders = source['folders'];
    if (rawFolders is List) {
      for (final Object? entry in rawFolders) {
        if (entry is! Map) {
          continue;
        }
        final AppFavoriteFolder? folder = AppFavoriteFolder.tryParse(
          Map<String, dynamic>.from(entry),
        );
        if (folder != null && importedFolders.length < maximumFolders) {
          importedFolders.add(folder);
        }
      }
    }
    final List<AppFavoriteItem> importedItems = <AppFavoriteItem>[];
    final Object? rawItems = source['items'];
    if (rawItems is List) {
      for (final Object? entry in rawItems) {
        if (entry is! Map) {
          continue;
        }
        final AppFavoriteItem? item = AppFavoriteItem.tryParse(
          Map<String, dynamic>.from(entry),
        );
        if (item != null && importedItems.length < maximumItems) {
          importedItems.add(item);
        }
      }
    }
    if (importedFolders.isEmpty && importedItems.isEmpty) {
      return const AppFavoriteImportResult(folderCount: 0, itemCount: 0);
    }
    final _AppFavoriteSnapshot snapshot = await _loadSnapshot();
    final Map<String, String> folderIdMap = <String, String>{};
    final List<AppFavoriteFolder> mergedFolders = List<AppFavoriteFolder>.of(
      snapshot.folders,
    );
    int folderCount = 0;
    for (final AppFavoriteFolder folder in importedFolders) {
      final AppFavoriteFolder? existing = _findFolderByIdOrName(
        mergedFolders,
        folder,
      );
      if (existing != null) {
        folderIdMap[folder.id] = existing.id;
        continue;
      }
      if (mergedFolders.length >= maximumFolders) {
        break;
      }
      final AppFavoriteFolder fresh = AppFavoriteFolder.create(folder.name);
      mergedFolders.add(fresh);
      folderIdMap[folder.id] = fresh.id;
      folderCount += 1;
    }
    final Set<String> existingKeys = snapshot.items
        .map((AppFavoriteItem item) => '${item.folderId}:${item.bvid}')
        .toSet();
    final List<AppFavoriteItem> mergedItems = List<AppFavoriteItem>.of(
      snapshot.items,
    );
    int itemCount = 0;
    for (final AppFavoriteItem item in importedItems) {
      final String? targetFolderId = folderIdMap[item.folderId];
      if (targetFolderId == null) {
        continue;
      }
      final String key = '$targetFolderId:${item.bvid}';
      if (existingKeys.contains(key) || mergedItems.length >= maximumItems) {
        continue;
      }
      existingKeys.add(key);
      mergedItems.add(
        AppFavoriteItem(
          folderId: targetFolderId,
          bvid: item.bvid,
          title: item.title.trim(),
          coverUrl: item.coverUrl.trim(),
          ownerName: item.ownerName.trim(),
          durationText: item.durationText.trim(),
          addedAt: item.addedAt,
          sourceLabel: item.sourceLabel,
        ),
      );
      itemCount += 1;
    }
    if (folderCount == 0 && itemCount == 0) {
      return const AppFavoriteImportResult(folderCount: 0, itemCount: 0);
    }
    await _saveSnapshot(
      snapshot.copyWith(folders: mergedFolders, items: mergedItems),
    );
    return AppFavoriteImportResult(
      folderCount: folderCount,
      itemCount: itemCount,
    );
  }

  /// 在已合并收藏夹中按 ID 或同名查找已有收藏夹，避免重复导入同名目录。
  AppFavoriteFolder? _findFolderByIdOrName(
    List<AppFavoriteFolder> folders,
    AppFavoriteFolder candidate,
  ) {
    for (final AppFavoriteFolder folder in folders) {
      if (folder.id == candidate.id || folder.name == candidate.name) {
        return folder;
      }
    }
    return null;
  }

  /// 读取本机快照；存储不可用或 JSON 损坏时返回空快照。
  Future<_AppFavoriteSnapshot> _loadSnapshot() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final String? rawJson = preferences.getString(_storageKey);
      if (rawJson == null || rawJson.trim().isEmpty) {
        return const _AppFavoriteSnapshot();
      }
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        return const _AppFavoriteSnapshot();
      }
      return _AppFavoriteSnapshot.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      // 本地数据暂时不可读时按空收藏夹处理，不阻止用户重新开始收藏。
      return const _AppFavoriteSnapshot();
    }
  }

  /// 写入快照；写入失败时静默返回，下次操作会再次尝试保存。
  Future<void> _saveSnapshot(_AppFavoriteSnapshot snapshot) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.setString(_storageKey, jsonEncode(snapshot.toJson()));
    } on Object {
      // 本机写入失败时用户仍可继续使用当前页面，后续操作会再次尝试保存。
    }
  }
}

/// 保存一次读取到的全部收藏夹与条目，并保证列表不可变。
class _AppFavoriteSnapshot {
  const _AppFavoriteSnapshot({
    this.folders = const <AppFavoriteFolder>[],
    this.items = const <AppFavoriteItem>[],
  });

  final List<AppFavoriteFolder> folders;
  final List<AppFavoriteItem> items;

  /// 从本机 JSON 恢复快照，并丢弃所有无法安全解析的条目。
  factory _AppFavoriteSnapshot.fromJson(Map<String, dynamic> json) {
    final List<AppFavoriteFolder> folders = <AppFavoriteFolder>[];
    final Object? rawFolders = json['folders'];
    if (rawFolders is List) {
      for (final Object? entry in rawFolders) {
        if (entry is! Map) {
          continue;
        }
        final AppFavoriteFolder? folder = AppFavoriteFolder.tryParse(
          Map<String, dynamic>.from(entry),
        );
        if (folder != null) {
          folders.add(folder);
        }
      }
    }
    final List<AppFavoriteItem> items = <AppFavoriteItem>[];
    final Object? rawItems = json['items'];
    if (rawItems is List) {
      for (final Object? entry in rawItems) {
        if (entry is! Map) {
          continue;
        }
        final AppFavoriteItem? item = AppFavoriteItem.tryParse(
          Map<String, dynamic>.from(entry),
        );
        if (item != null) {
          items.add(item);
        }
      }
    }
    return _AppFavoriteSnapshot(folders: folders, items: items);
  }

  /// 返回一份替换了收藏夹或条目列表的新快照。
  _AppFavoriteSnapshot copyWith({
    List<AppFavoriteFolder>? folders,
    List<AppFavoriteItem>? items,
  }) {
    return _AppFavoriteSnapshot(
      folders: folders ?? this.folders,
      items: items ?? this.items,
    );
  }

  /// 序列化为导出或持久化使用的 JSON 对象。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'version': 1,
      'folders': folders
          .map((AppFavoriteFolder folder) => folder.toJson())
          .toList(growable: false),
      'items': items
          .map((AppFavoriteItem item) => item.toJson())
          .toList(growable: false),
    };
  }
}
