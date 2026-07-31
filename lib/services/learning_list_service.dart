import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/learning_list_entry.dart';
import '../models/video_preview.dart';
import '../models/watch_history_entry.dart';
import 'watch_history_service.dart';

/// 定义读取学习清单偏好设置的可替换入口，方便单元测试使用内存存储。
typedef LearningListPreferencesLoader = Future<SharedPreferences> Function();

/// 在当前设备保存学习任务，并与现有观看记录自动衔接分P和进度。
class LearningListService {
  /// 创建学习清单服务；未注入时使用真实偏好设置和观看记录服务。
  LearningListService({
    LearningListPreferencesLoader? preferencesLoader,
    WatchHistoryService? watchHistoryService,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _watchHistoryService = watchHistoryService ?? WatchHistoryService();

  static const String _storageKey = 'focubili_learning_list_v1';

  /// 限制本机最多保存的任务数，避免长期使用后偏好设置无限增长。
  static const int maximumEntries = 100;

  final LearningListPreferencesLoader _preferencesLoader;
  final WatchHistoryService _watchHistoryService;

  /// 读取全部合法任务，并按最近更新从新到旧排列。
  Future<List<LearningListEntry>> loadEntries() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final List<LearningListEntry> entries = _decodeEntries(
        preferences.getString(_storageKey),
      );
      _sortEntries(entries);
      return List<LearningListEntry>.unmodifiable(entries);
    } catch (_) {
      // 本地存储暂时不可用时不阻止搜索和播放功能，页面以空清单继续工作。
      return const <LearningListEntry>[];
    }
  }

  /// 读取当前需要在首页突出展示的一条任务，优先学习中，其次未开始。
  Future<LearningListEntry?> loadCurrentTask() async {
    return currentTask(await loadEntries());
  }

  /// 从已经读取的任务中挑选当前任务，避免首页重复读取本机存储。
  LearningListEntry? currentTask(List<LearningListEntry> entries) {
    final List<LearningListEntry> learning = entries
        .where(
          (LearningListEntry entry) =>
              entry.status == LearningListStatus.learning,
        )
        .toList(growable: false);
    if (learning.isNotEmpty) {
      return learning.first;
    }
    final List<LearningListEntry> notStarted = entries
        .where(
          (LearningListEntry entry) =>
              entry.status == LearningListStatus.notStarted,
        )
        .toList(growable: false);
    return notStarted.isEmpty ? null : notStarted.first;
  }

  /// 加入视频并自动继承已有观看记录的分P和时间点；同一 BV 会更新而不重复添加。
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
    final int existingIndex = existing.indexWhere(
      (LearningListEntry entry) => entry.bvid == normalizedBvid,
    );
    final LearningListEntry? previous = existingIndex >= 0
        ? existing[existingIndex]
        : null;
    final WatchHistoryEntry? history = previous == null
        ? await _findWatchHistory(normalizedBvid)
        : null;
    final VideoPart resolvedPart =
        part ??
        _findPart(
          video,
          cid: previous?.partCid,
          pageNumber: previous?.partPageNumber ?? history?.lastPartPageNumber,
        );
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
    );
    if (existingIndex >= 0) {
      existing[existingIndex] = entry;
    } else {
      existing.add(entry);
    }
    return _saveEntries(existing);
  }

  /// 更新清单中已有任务的分P和播放位置；不存在的任务不会被播放器悄悄加入。
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
      (LearningListEntry entry) => entry.bvid == normalizedBvid,
    );
    if (index < 0) {
      return List<LearningListEntry>.unmodifiable(entries);
    }
    entries[index] = entries[index].copyWith(
      partCid: part.cid,
      partPageNumber: part.pageNumber,
      partTitle: part.title.trim(),
      position: _clampPosition(position, part.duration),
      duration: part.duration,
      status: status,
      updatedAt: DateTime.now(),
    );
    return _saveEntries(entries);
  }

  /// 只修改任务状态，保留已经继承或播放得到的分P和进度。
  Future<List<LearningListEntry>> updateStatus(
    String bvid,
    LearningListStatus status,
  ) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return loadEntries();
    }
    final List<LearningListEntry> entries = List<LearningListEntry>.of(
      await loadEntries(),
    );
    final int index = entries.indexWhere(
      (LearningListEntry entry) => entry.bvid == normalizedBvid,
    );
    if (index < 0) {
      return List<LearningListEntry>.unmodifiable(entries);
    }
    entries[index] = entries[index].copyWith(
      status: status,
      updatedAt: DateTime.now(),
    );
    return _saveEntries(entries);
  }

  /// 移除指定 BV 的学习任务，并返回移除后的本机任务列表。
  Future<List<LearningListEntry>> remove(String bvid) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return loadEntries();
    }
    final List<LearningListEntry> entries = await loadEntries();
    final List<LearningListEntry> updated = entries
        .where((LearningListEntry entry) => entry.bvid != normalizedBvid)
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
      // 观看记录不可用时仍可正常从视频默认分P创建学习任务。
    }
    return null;
  }

  /// 按 CID 或页码在最新视频详情中找回保存分P，旧数据失效时回退默认分P。
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

  /// 把进度限制在当前分P时长内；接口缺失时只限制为一天以内的安全值。
  Duration _clampPosition(Duration position, Duration duration) {
    final int maximum = duration > Duration.zero
        ? duration.inMilliseconds
        : 24 * 60 * 60 * 1000;
    return Duration(
      milliseconds: position.inMilliseconds.clamp(0, maximum).toInt(),
    );
  }

  /// 写入任务前按更新时间排序并裁剪上限，再返回页面可直接使用的不可变列表。
  Future<List<LearningListEntry>> _saveEntries(
    List<LearningListEntry> entries,
  ) async {
    final List<LearningListEntry> normalized = <LearningListEntry>[];
    final Set<String> seenBvids = <String>{};
    for (final LearningListEntry entry in entries) {
      final LearningListEntry? safeEntry = LearningListEntry.tryParse(
        entry.toJson(),
      );
      if (safeEntry != null && seenBvids.add(safeEntry.bvid)) {
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

  /// 按最近更新时间把任务从新到旧排列，首页和管理页使用同一稳定顺序。
  void _sortEntries(List<LearningListEntry> entries) {
    entries.sort(
      (LearningListEntry left, LearningListEntry right) =>
          right.updatedAt.compareTo(left.updatedAt),
    );
  }

  /// 把内存任务序列化写入本机；写入失败不会中断调用方的界面更新。
  Future<void> _writeEntries(List<LearningListEntry> entries) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.setString(
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

  /// 解析本机 JSON，只保留合法、去重且数量受控的学习任务。
  List<LearningListEntry> _decodeEntries(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return <LearningListEntry>[];
    }
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List<Object?>) {
        return <LearningListEntry>[];
      }
      final Set<String> seenBvids = <String>{};
      final List<LearningListEntry> entries = <LearningListEntry>[];
      for (final Object? item in decoded) {
        if (item is! Map) {
          continue;
        }
        final LearningListEntry? entry = LearningListEntry.tryParse(
          Map<String, dynamic>.from(item),
        );
        if (entry != null && seenBvids.add(entry.bvid)) {
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
