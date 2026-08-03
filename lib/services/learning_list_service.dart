import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/learning_list_entry.dart';
import '../models/video_preview.dart';
import '../models/watch_history_entry.dart';
import 'watch_history_service.dart';

/// 定义读取学习清单偏好设置的可替换入口，方便单元测试使用内存存储。
typedef LearningListPreferencesLoader = Future<SharedPreferences> Function();

/// 在当前设备保存以“视频 + 分 P”为单位的学习任务，并与观看记录自动衔接。
class LearningListService {
  /// 创建学习清单服务；未注入时使用真实偏好设置和观看记录服务。
  LearningListService({
    LearningListPreferencesLoader? preferencesLoader,
    WatchHistoryService? watchHistoryService,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _watchHistoryService = watchHistoryService ?? WatchHistoryService();

  static const String _storageKey = 'focubili_learning_list_v2';
  static const String _legacyStorageKey = 'focubili_learning_list_v1';

  /// 限制本机最多保存的任务数，避免长期使用后偏好设置无限增长。
  static const int maximumEntries = 100;

  final LearningListPreferencesLoader _preferencesLoader;
  final WatchHistoryService _watchHistoryService;

  /// 读取全部合法任务：未完成任务保持手动顺序，已完成任务自动置底。
  Future<List<LearningListEntry>> loadEntries() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final String? currentJson = preferences.getString(_storageKey);
      final String? legacyJson = currentJson == null
          ? preferences.getString(_legacyStorageKey)
          : null;
      final List<LearningListEntry> entries = _decodeEntries(
        currentJson ?? legacyJson,
      );
      _sortEntries(entries);
      if (currentJson == null && legacyJson != null) {
        final List<LearningListEntry> migrated = _rebuildLegacySortOrders(
          entries,
        );
        await _writeEntries(migrated, preferences: preferences);
        await preferences.remove(_legacyStorageKey);
        return List<LearningListEntry>.unmodifiable(migrated);
      }
      return List<LearningListEntry>.unmodifiable(entries);
    } catch (_) {
      // 本地存储暂时不可用时不阻止搜索和播放功能，页面以空清单继续工作。
      return const <LearningListEntry>[];
    }
  }

  /// 读取首页应突出的一条未完成任务，严格遵循用户当前的手动学习顺序。
  Future<LearningListEntry?> loadCurrentTask() async {
    return currentTask(await loadEntries());
  }

  /// 从已经读取的任务中挑选第一条未完成任务，避免首页重复读取本机存储。
  LearningListEntry? currentTask(List<LearningListEntry> entries) {
    for (final LearningListEntry entry in entries) {
      if (entry.status != LearningListStatus.completed) {
        return entry;
      }
    }
    return null;
  }

  /// 在已读取列表中查找指定视频与 CID 的独立学习任务。
  LearningListEntry? findEntryForPart(
    List<LearningListEntry> entries,
    String bvid,
    int partCid,
  ) {
    for (final LearningListEntry entry in entries) {
      if (entry.matchesPart(bvid, partCid)) {
        return entry;
      }
    }
    return null;
  }

  /// 按保存的手动顺序返回当前任务之后的下一条未完成任务，不循环播放。
  LearningListEntry? nextIncompleteAfter(
    List<LearningListEntry> entries,
    LearningListEntry current,
  ) {
    final List<LearningListEntry> manualOrder = List<LearningListEntry>.of(
      entries,
    )..sort(_compareManualOrder);
    final int currentIndex = manualOrder.indexWhere(
      (LearningListEntry entry) => entry.stableId == current.stableId,
    );
    if (currentIndex < 0) {
      return null;
    }
    for (int index = currentIndex + 1; index < manualOrder.length; index += 1) {
      final LearningListEntry candidate = manualOrder[index];
      if (candidate.status != LearningListStatus.completed) {
        return candidate;
      }
    }
    return null;
  }

  /// 加入一个指定分 P，并自动继承该视频最近观看记录的分 P 和时间点。
  Future<List<LearningListEntry>> addVideo(
    VideoPreview video, {
    VideoPart? part,
    Duration? position,
    LearningListStatus? status,
  }) async {
    final String normalizedBvid = video.bvid.trim();
    if (normalizedBvid.isEmpty) {
      return loadEntries();
    }
    final List<LearningListEntry> existing = List<LearningListEntry>.of(
      await loadEntries(),
    );
    final WatchHistoryEntry? history = part == null
        ? await _findWatchHistory(normalizedBvid)
        : null;
    final VideoPart resolvedPart =
        part ?? _findPart(video, pageNumber: history?.lastPartPageNumber);
    final int existingIndex = existing.indexWhere(
      (LearningListEntry entry) =>
          entry.matchesPart(normalizedBvid, resolvedPart.cid),
    );
    final LearningListEntry? previous = existingIndex >= 0
        ? existing[existingIndex]
        : null;
    final Duration resolvedPosition = _clampPosition(
      position ?? previous?.position ?? history?.lastPosition ?? Duration.zero,
      resolvedPart.duration,
    );
    final LearningListStatus resolvedStatus =
        status ??
        previous?.status ??
        (resolvedPosition > Duration.zero
            ? LearningListStatus.learning
            : LearningListStatus.notStarted);
    final DateTime now = DateTime.now();
    final LearningListEntry entry = LearningListEntry(
      bvid: normalizedBvid,
      title: video.title.trim().isEmpty ? '未命名视频' : video.title.trim(),
      ownerName: video.ownerName.trim(),
      thumbnailUrl: video.thumbnailUrl.trim(),
      partCid: resolvedPart.cid,
      partPageNumber: resolvedPart.pageNumber,
      partTitle: resolvedPart.title.trim(),
      position: resolvedPosition,
      duration: resolvedPart.duration,
      status: resolvedStatus,
      addedAt: previous?.addedAt ?? now,
      updatedAt: now,
      sortOrder: previous?.sortOrder ?? _nextSortOrder(existing),
    );
    if (existingIndex >= 0) {
      existing[existingIndex] = entry;
    } else {
      existing.add(entry);
    }
    return _saveEntries(existing);
  }

  /// 更新指定分 P 的进度；未加入的其他分 P 不会被播放器悄悄创建或覆盖。
  Future<List<LearningListEntry>> updateProgress(
    String bvid, {
    required VideoPart part,
    required Duration position,
    LearningListStatus? status,
  }) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty || part.cid <= 0 || part.pageNumber <= 0) {
      return loadEntries();
    }
    final List<LearningListEntry> entries = List<LearningListEntry>.of(
      await loadEntries(),
    );
    final int index = entries.indexWhere(
      (LearningListEntry entry) => entry.matchesPart(normalizedBvid, part.cid),
    );
    if (index < 0) {
      return List<LearningListEntry>.unmodifiable(entries);
    }
    entries[index] = entries[index].copyWith(
      partPageNumber: part.pageNumber,
      partTitle: part.title.trim(),
      position: _clampPosition(position, part.duration),
      duration: part.duration,
      status: status,
      updatedAt: DateTime.now(),
    );
    return _saveEntries(entries);
  }

  /// 修改一个视频或指定分 P 的状态；省略 CID 时保留旧版“同 BV 全部修改”行为。
  Future<List<LearningListEntry>> updateStatus(
    String bvid,
    LearningListStatus status, {
    int? partCid,
  }) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return loadEntries();
    }
    final List<LearningListEntry> entries = List<LearningListEntry>.of(
      await loadEntries(),
    );
    bool changed = false;
    final DateTime now = DateTime.now();
    for (int index = 0; index < entries.length; index += 1) {
      final LearningListEntry entry = entries[index];
      if (entry.bvid != normalizedBvid ||
          (partCid != null && entry.partCid != partCid)) {
        continue;
      }
      entries[index] = entry.copyWith(status: status, updatedAt: now);
      changed = true;
    }
    return changed
        ? _saveEntries(entries)
        : List<LearningListEntry>.unmodifiable(entries);
  }

  /// 按拖拽得到的稳定标识重新排列未完成任务，已完成任务始终保持在末尾分区。
  Future<List<LearningListEntry>> reorderIncomplete(
    List<String> orderedStableIds,
  ) async {
    final List<LearningListEntry> entries = List<LearningListEntry>.of(
      await loadEntries(),
    );
    final List<LearningListEntry> activeEntries = entries
        .where(
          (LearningListEntry entry) =>
              entry.status != LearningListStatus.completed,
        )
        .toList(growable: false);
    final Map<String, LearningListEntry> activeById =
        <String, LearningListEntry>{
          for (final LearningListEntry entry in activeEntries)
            entry.stableId: entry,
        };
    final Set<String> usedIds = <String>{};
    final List<LearningListEntry> reordered = <LearningListEntry>[];
    for (final String stableId in orderedStableIds) {
      final LearningListEntry? entry = activeById[stableId];
      if (entry != null && usedIds.add(stableId)) {
        reordered.add(entry);
      }
    }
    for (final LearningListEntry entry in activeEntries) {
      if (usedIds.add(entry.stableId)) {
        reordered.add(entry);
      }
    }
    final DateTime now = DateTime.now();
    final List<LearningListEntry> ranked = <LearningListEntry>[
      for (int index = 0; index < reordered.length; index += 1)
        reordered[index].copyWith(sortOrder: index, updatedAt: now),
      ...entries.where(
        (LearningListEntry entry) =>
            entry.status == LearningListStatus.completed,
      ),
    ];
    return _saveEntries(ranked);
  }

  /// 移除指定 BV 的全部任务，或在传入 CID 时只移除当前视频分 P。
  Future<List<LearningListEntry>> remove(String bvid, {int? partCid}) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return loadEntries();
    }
    final List<LearningListEntry> entries = await loadEntries();
    final List<LearningListEntry> updated = entries
        .where(
          (LearningListEntry entry) =>
              entry.bvid != normalizedBvid ||
              (partCid != null && entry.partCid != partCid),
        )
        .toList(growable: false);
    if (updated.length == entries.length) {
      return List<LearningListEntry>.unmodifiable(entries);
    }
    return _saveEntries(updated);
  }

  /// 清空设备中的全部学习任务；观看记录和笔记不会受到影响。
  Future<List<LearningListEntry>> clear() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.remove(_storageKey);
      await preferences.remove(_legacyStorageKey);
    } catch (_) {
      // 偏好设置暂时不可用时仍返回空状态，让页面能够立即恢复可操作状态。
    }
    return const <LearningListEntry>[];
  }

  /// 从观看记录中查找同一 BV 的最近进度，读取失败时安全回退为空。
  Future<WatchHistoryEntry?> _findWatchHistory(String bvid) async {
    try {
      final List<WatchHistoryEntry> history = await _watchHistoryService
          .loadHistory();
      for (final WatchHistoryEntry entry in history) {
        if (entry.bvid == bvid) {
          return entry;
        }
      }
    } catch (_) {
      // 观看记录不可用时仍可正常从视频默认分 P 创建学习任务。
    }
    return null;
  }

  /// 按页码在最新视频详情中找回保存分 P，旧数据失效时回退默认分 P。
  VideoPart _findPart(VideoPreview video, {int? cid, int? pageNumber}) {
    if (cid != null && cid > 0) {
      for (final VideoPart part in video.parts) {
        if (part.cid == cid) {
          return part;
        }
      }
    }
    if (pageNumber != null && pageNumber > 0) {
      for (final VideoPart part in video.parts) {
        if (part.pageNumber == pageNumber) {
          return part;
        }
      }
    }
    return video.initialPart;
  }

  /// 把进度限制在当前分 P 时长内；接口缺失时只限制为一天以内的安全值。
  Duration _clampPosition(Duration position, Duration duration) {
    final int maximum = duration > Duration.zero
        ? duration.inMilliseconds
        : 24 * 60 * 60 * 1000;
    return Duration(
      milliseconds: position.inMilliseconds.clamp(0, maximum).toInt(),
    );
  }

  /// 为新任务分配现有手动顺序之后的编号，保证它默认出现在未完成列表底部。
  int _nextSortOrder(List<LearningListEntry> entries) {
    int maximumOrder = -1;
    for (final LearningListEntry entry in entries) {
      if (entry.sortOrder > maximumOrder) {
        maximumOrder = entry.sortOrder;
      }
    }
    return maximumOrder + 1;
  }

  /// 写入任务前校验、按“未完成在前”排序并裁剪上限，再返回不可变列表。
  Future<List<LearningListEntry>> _saveEntries(
    List<LearningListEntry> entries,
  ) async {
    final List<LearningListEntry> normalized = <LearningListEntry>[];
    final Set<String> seenStableIds = <String>{};
    for (final LearningListEntry entry in entries) {
      final LearningListEntry? safeEntry = LearningListEntry.tryParse(
        entry.toJson(),
      );
      if (safeEntry != null && seenStableIds.add(safeEntry.stableId)) {
        normalized.add(safeEntry);
      }
    }
    _sortEntries(normalized);
    final List<LearningListEntry> limited = normalized
        .take(maximumEntries)
        .toList(growable: false);
    await _writeEntries(limited);
    return List<LearningListEntry>.unmodifiable(limited);
  }

  /// 为 v1 数据生成连续排序编号，保留旧任务的显示顺序并迁移到 v2 存储键。
  List<LearningListEntry> _rebuildLegacySortOrders(
    List<LearningListEntry> entries,
  ) {
    final List<LearningListEntry> migrated = <LearningListEntry>[];
    for (int index = 0; index < entries.length; index += 1) {
      migrated.add(entries[index].copyWith(sortOrder: index));
    }
    _sortEntries(migrated);
    return migrated;
  }

  /// 按未完成分区、用户手动顺序和稳定兜底字段排序，确保页面与继续学习使用同一顺序。
  void _sortEntries(List<LearningListEntry> entries) {
    entries.sort((LearningListEntry left, LearningListEntry right) {
      final int leftGroup = left.status == LearningListStatus.completed ? 1 : 0;
      final int rightGroup = right.status == LearningListStatus.completed
          ? 1
          : 0;
      final int groupComparison = leftGroup.compareTo(rightGroup);
      return groupComparison != 0
          ? groupComparison
          : _compareManualOrder(left, right);
    });
  }

  /// 比较两个任务的手动学习顺序；排序号相同时使用加入时间和稳定标识避免列表跳动。
  int _compareManualOrder(LearningListEntry left, LearningListEntry right) {
    final int orderComparison = left.sortOrder.compareTo(right.sortOrder);
    if (orderComparison != 0) {
      return orderComparison;
    }
    final int addedComparison = left.addedAt.compareTo(right.addedAt);
    return addedComparison != 0
        ? addedComparison
        : left.stableId.compareTo(right.stableId);
  }

  /// 把内存任务序列化写入本机；写入失败不会中断调用方的界面更新。
  Future<void> _writeEntries(
    List<LearningListEntry> entries, {
    SharedPreferences? preferences,
  }) async {
    try {
      final SharedPreferences target =
          preferences ?? await _preferencesLoader();
      await target.setString(
        _storageKey,
        jsonEncode(
          entries
              .map((LearningListEntry entry) => entry.toJson())
              .toList(growable: false),
        ),
      );
    } catch (_) {
      // 本机写入失败时用户仍可继续播放，后续操作会再次尝试保存。
    }
  }

  /// 解析本机 JSON，只保留合法、以“BV + CID”去重且数量受控的学习任务。
  List<LearningListEntry> _decodeEntries(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return <LearningListEntry>[];
    }
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List<Object?>) {
        return <LearningListEntry>[];
      }
      final Set<String> seenStableIds = <String>{};
      final List<LearningListEntry> entries = <LearningListEntry>[];
      for (final Object? item in decoded) {
        if (item is! Map) {
          continue;
        }
        final LearningListEntry? entry = LearningListEntry.tryParse(
          Map<String, dynamic>.from(item),
        );
        if (entry != null && seenStableIds.add(entry.stableId)) {
          entries.add(entry);
        }
        if (entries.length == maximumEntries) {
          break;
        }
      }
      return entries;
    } catch (_) {
      // JSON 被截断或被手动修改时按空任务处理，避免应用启动崩溃。
      return <LearningListEntry>[];
    }
  }
}
