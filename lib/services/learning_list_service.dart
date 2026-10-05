import 'dart:async';
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

  /// 同一偏好设置实例上的所有清单服务共用写入队列。
  static final Expando<Future<void>> _writeQueues = Expando('learning writes');
  bool readFailed = false;

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final preferences = await _preferencesLoader();
    final previous = _writeQueues[preferences];
    final release = Completer<void>();
    _writeQueues[preferences] = release.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_writeQueues[preferences], release.future)) {
        _writeQueues[preferences] = null;
      }
    }
  }

  /// 读取合法任务，失败时标记 readFailed 并保留磁盘原数据。
  Future<List<LearningListEntry>> loadEntries() =>
      _serialized(() async {
        try {
          final entries = await _loadStrict();
          readFailed = false;
          return entries;
        } catch (_) {
          readFailed = true;
          return const <LearningListEntry>[];
        }
      }).catchError((Object _) {
        readFailed = true;
        return const <LearningListEntry>[];
      });

  Future<List<LearningListEntry>> _loadStrict() async {
    final preferences = await _preferencesLoader();
    final current = preferences.getString(_storageKey);
    final legacy = current == null
        ? preferences.getString(_legacyStorageKey)
        : null;
    final entries = _decodeEntries(current ?? legacy);
    _sortEntries(entries);
    if (legacy != null) {
      final migrated = _rebuildLegacySortOrders(entries);
      if (!await preferences.setString('${_legacyStorageKey}_backup', legacy)) {
        throw const LearningListStorageException();
      }
      await _writeEntries(migrated, preferences: preferences);
      // Only remove the original after a verified v2 write. The backup remains.
      await preferences.remove(_legacyStorageKey);
      return List.unmodifiable(migrated);
    }
    return List.unmodifiable(entries);
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
    final history = part == null ? await _findWatchHistory(video.bvid) : null;
    final resolved =
        part ?? _findPart(video, pageNumber: history?.lastPartPageNumber);
    final result = await addBatch([
      LearningPartSelection(
        video,
        resolved,
        position: position ?? history?.lastPosition ?? Duration.zero,
        status: status,
      ),
    ]);
    if (!result.persisted) throw const LearningListStorageException();
    if (result.capacityExceeded) throw const LearningListCapacityException();
    return result.entries;
  }

  Future<LearningBatchResult> addParts(
    VideoPreview video,
    List<VideoPart> parts,
  ) => addBatch([for (final part in parts) LearningPartSelection(video, part)]);

  /// Atomic capacity check; duplicates never replace progress, status or order.
  Future<LearningBatchResult> addBatch(
    List<LearningPartSelection> selections,
  ) => _serialized(() async {
    List<LearningListEntry> entries;
    try {
      entries = List.of(await _loadStrict());
    } catch (_) {
      return const LearningBatchResult(persisted: false);
    }
    final existing = entries.map((e) => e.stableId).toSet();
    final added = <String>[];
    final duplicates = <String>[];
    final failed = <String>[];
    final now = DateTime.now();
    var order = _nextSortOrder(entries);
    final pending = <LearningListEntry>[];
    for (final selection in selections) {
      final video = selection.video;
      final part = selection.part;
      final entry = LearningListEntry(
        bvid: video.bvid.trim(),
        title: video.title,
        ownerName: video.ownerName,
        thumbnailUrl: video.thumbnailUrl,
        partCid: part.cid,
        partPageNumber: part.pageNumber,
        partTitle: part.title,
        position: _clampPosition(selection.position, part.duration),
        duration: part.duration,
        status:
            selection.status ??
            (selection.position > Duration.zero
                ? LearningListStatus.learning
                : LearningListStatus.notStarted),
        addedAt: now,
        updatedAt: now,
        sortOrder: order,
      );
      if (LearningListEntry.tryParse(entry.toJson()) == null ||
          !video.parts.any((p) => p.cid == part.cid)) {
        failed.add('${video.bvid}:${part.cid}');
      } else if (!existing.add(entry.stableId)) {
        duplicates.add(entry.stableId);
      } else {
        pending.add(entry);
        added.add(entry.stableId);
        order++;
      }
    }
    if (entries.length + pending.length > maximumEntries) {
      return LearningBatchResult(
        entries: entries,
        existingIds: duplicates,
        failedItems: failed,
        capacityExceeded: true,
        persisted: true,
      );
    }
    try {
      if (pending.isNotEmpty) {
        entries = List.of(await _saveEntries([...entries, ...pending]));
      }
      return LearningBatchResult(
        entries: entries,
        addedIds: added,
        existingIds: duplicates,
        failedItems: failed,
        persisted: true,
      );
    } catch (_) {
      return LearningBatchResult(
        entries: await loadEntriesAfterFailure(),
        existingIds: duplicates,
        failedItems: failed,
        persisted: false,
      );
    }
  }).catchError((Object _) => const LearningBatchResult(persisted: false));

  Future<List<LearningListEntry>> loadEntriesAfterFailure() async {
    try {
      return await _loadStrict();
    } catch (_) {
      return const [];
    }
  }

  Future<List<LearningListEntry>> updateStatuses(
    Set<String> ids,
    LearningListStatus status,
  ) => _serialized(() async {
    final entries = await _loadStrict();
    return _saveEntries([
      for (final entry in entries)
        ids.contains(entry.stableId)
            ? entry.copyWith(status: status, updatedAt: DateTime.now())
            : entry,
    ]);
  });

  Future<List<LearningListEntry>> removeBatch(Set<String> ids) =>
      _serialized(() async {
        final entries = await _loadStrict();
        return _saveEntries(
          entries.where((e) => !ids.contains(e.stableId)).toList(),
        );
      });

  /// 更新指定分 P 的进度；未加入的其他分 P 不会被播放器悄悄创建或覆盖。
  Future<List<LearningListEntry>> updateProgress(
    String bvid, {
    required VideoPart part,
    required Duration position,
    LearningListStatus? status,
  }) => _serialized(() async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty || part.cid <= 0 || part.pageNumber <= 0) {
      return _loadStrict();
    }
    final List<LearningListEntry> entries = List<LearningListEntry>.of(
      await _loadStrict(),
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
  });

  /// 修改一个视频或指定分 P 的状态；省略 CID 时保留旧版“同 BV 全部修改”行为。
  Future<List<LearningListEntry>> updateStatus(
    String bvid,
    LearningListStatus status, {
    int? partCid,
  }) => _serialized(() async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return _loadStrict();
    }
    final List<LearningListEntry> entries = List<LearningListEntry>.of(
      await _loadStrict(),
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
  });

  /// 按拖拽得到的稳定标识重新排列未完成任务，已完成任务始终保持在末尾分区。
  Future<List<LearningListEntry>> reorderIncomplete(
    List<String> orderedStableIds,
  ) => _serialized(() async {
    final List<LearningListEntry> entries = List<LearningListEntry>.of(
      await _loadStrict(),
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
  });

  /// 移除指定 BV 的全部任务，或在传入 CID 时只移除当前视频分 P。
  Future<List<LearningListEntry>> remove(String bvid, {int? partCid}) =>
      _serialized(() async {
        final String normalizedBvid = bvid.trim();
        if (normalizedBvid.isEmpty) {
          return _loadStrict();
        }
        final List<LearningListEntry> entries = await _loadStrict();
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
      });

  /// 清空设备中的全部学习任务；观看记录和笔记不会受到影响。
  Future<List<LearningListEntry>> clear() => _serialized(() async {
    await _loadStrict();
    return _saveEntries([]);
  });

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

  /// 写入任务前校验并排序，超出容量时拒绝整次写入，再返回不可变列表。
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
    if (normalized.length > maximumEntries) {
      throw const LearningListCapacityException();
    }
    final List<LearningListEntry> limited = normalized;
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

  /// 把任务序列化写入本机，重读验证后才返回；失败时向调用方报告。
  Future<void> _writeEntries(
    List<LearningListEntry> entries, {
    SharedPreferences? preferences,
  }) async {
    final target = preferences ?? await _preferencesLoader();
    final previous = target.getString(_storageKey);
    if (previous != null &&
        !await target.setString('${_storageKey}_backup', previous)) {
      throw const LearningListStorageException();
    }
    final encoded = jsonEncode(entries.map((e) => e.toJson()).toList());
    try {
      if (!await target.setString(_storageKey, encoded)) {
        throw const LearningListStorageException();
      }
      await target.reload();
      if (target.getString(_storageKey) != encoded) {
        throw const LearningListStorageException();
      }
    } catch (_) {
      await target.reload();
      throw const LearningListStorageException();
    }
  }

  /// 解析本机 JSON 并按“BV + CID”去重，读取时保留所有已有合法任务。
  List<LearningListEntry> _decodeEntries(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return <LearningListEntry>[];
    }
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List<Object?>) throw const LearningListStorageException();
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
      }
      if (decoded.isNotEmpty && entries.isEmpty) {
        throw const LearningListStorageException();
      }
      return entries;
    } catch (_) {
      throw const LearningListStorageException();
    }
  }
}

class LearningPartSelection {
  const LearningPartSelection(
    this.video,
    this.part, {
    this.position = Duration.zero,
    this.status,
  });
  final VideoPreview video;
  final VideoPart part;
  final Duration position;
  final LearningListStatus? status;
}

class LearningBatchResult {
  const LearningBatchResult({
    this.entries = const [],
    this.addedIds = const [],
    this.existingIds = const [],
    this.failedItems = const [],
    this.capacityExceeded = false,
    required this.persisted,
  });
  final List<LearningListEntry> entries;
  final List<String> addedIds;
  final List<String> existingIds;
  final List<String> failedItems;
  final bool capacityExceeded;
  final bool persisted;
}

class LearningListStorageException implements Exception {
  const LearningListStorageException();
  @override
  String toString() => '学习清单未保存，请检查设备存储后重试';
}

class LearningListCapacityException implements Exception {
  const LearningListCapacityException();
  @override
  String toString() => '学习清单最多100条，请先移除不需要的任务';
}
