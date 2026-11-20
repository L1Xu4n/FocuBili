import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/watch_history_entry.dart';
import 'app_behavior_preferences_service.dart';

/// 定义读取本机偏好设置的可替换入口，方便单元测试使用内存存储。
typedef WatchHistoryPreferencesLoader = Future<SharedPreferences> Function();

/// 在设备本地保存最近观看过的视频，不上传或保存任何会话敏感数据。
class WatchHistoryService {
  /// 创建观看记录服务；未传入读取器时使用真实的 SharedPreferences。
  WatchHistoryService({
    WatchHistoryPreferencesLoader? preferencesLoader,
    AppBehaviorPreferencesService? behaviorPreferencesService,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _behaviorPreferencesService =
           behaviorPreferencesService ??
           AppBehaviorPreferencesService(preferencesLoader: preferencesLoader);

  static const String _storageKey = 'focubili_watch_history';
  static final _pendingWrites = Expando<Future<void>>();

  // All users of a preferences cache share its lock. Do not retain a
  // completed Future or let a replaced cache block writes to another one.
  Future<T> _mutate<T>(
    SharedPreferences preferences,
    Future<T> Function() operation,
  ) async {
    final previous = _pendingWrites[preferences];
    final done = Completer<void>();
    final tail = done.future;
    _pendingWrites[preferences] = tail;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      if (identical(_pendingWrites[preferences], tail)) {
        _pendingWrites[preferences] = null;
      }
      done.complete();
    }
  }

  /// 限制本机最多保存的记录数量，避免观看记录无限占用存储空间。
  static const int maximumEntries = 50;

  final WatchHistoryPreferencesLoader _preferencesLoader;
  final AppBehaviorPreferencesService _behaviorPreferencesService;

  /// 读取观看记录，跳过损坏条目、重复 BV 号和超过上限的旧数据。
  Future<List<WatchHistoryEntry>> loadHistory() async {
    final preferences = await _loadAvailablePreferences();
    return preferences == null ? const [] : _readEntries(preferences);
  }

  Future<SharedPreferences?> _loadAvailablePreferences() async {
    try {
      return await _preferencesLoader();
    } catch (_) {
      // 本地存储暂时不可用时，不阻止应用其他功能。
      return null;
    }
  }

  List<WatchHistoryEntry> _readEntries(SharedPreferences preferences) {
    try {
      return _decodeEntries(preferences.getString(_storageKey));
    } catch (_) {
      // 旧数据类型不匹配时按空记录处理。
      return const [];
    }
  }

  /// 保存一次观看状态，并将同一 BV 号的旧记录替换为最新的一条。
  Future<List<WatchHistoryEntry>> record(WatchHistoryEntry entry) async {
    final normalizedEntry = _normalizeEntry(entry);
    if (normalizedEntry == null) return loadHistory();

    final preferences = await _loadAvailablePreferences();
    if (preferences == null) {
      // Preserve the caller's in-memory result when storage is unavailable.
      return await _behaviorPreferencesService.loadWatchHistoryEnabled()
          ? List.unmodifiable([normalizedEntry])
          : const [];
    }
    return _mutate(preferences, () async {
      if (!await _behaviorPreferencesService.loadWatchHistoryEnabled()) {
        return _readEntries(preferences);
      }
      final existing = _readEntries(preferences);
      final updated = <WatchHistoryEntry>[
        normalizedEntry,
        ...existing.where((item) => item.bvid != normalizedEntry.bvid),
      ].take(maximumEntries).toList(growable: false);
      await _writeEntries(preferences, updated);
      return List<WatchHistoryEntry>.unmodifiable(updated);
    });
  }

  /// 为旧版遗留的空封面记录批量补写安全缩略图，同时保持原顺序、观看时间和进度不变。
  Future<List<WatchHistoryEntry>> backfillThumbnails(
    Map<String, String> thumbnailUrls,
  ) async {
    final Map<String, String> normalizedUrls = <String, String>{};
    thumbnailUrls.forEach((String bvid, String url) {
      final String normalizedBvid = bvid.trim();
      final String normalizedUrl = url.trim();
      if (normalizedBvid.isNotEmpty && normalizedUrl.isNotEmpty) {
        normalizedUrls[normalizedBvid] = normalizedUrl;
      }
    });
    if (normalizedUrls.isEmpty) {
      return loadHistory();
    }
    final preferences = await _loadAvailablePreferences();
    if (preferences == null) return const [];
    return _mutate(preferences, () async {
      final existing = _readEntries(preferences);
      bool changed = false;
      final updated = existing
          .map((entry) {
            final thumbnailUrl = normalizedUrls[entry.bvid];
            if (entry.thumbnailUrl.isNotEmpty || thumbnailUrl == null) {
              return entry;
            }
            changed = true;
            return entry.copyWith(thumbnailUrl: thumbnailUrl);
          })
          .toList(growable: false);
      if (changed) await _writeEntries(preferences, updated);
      return List<WatchHistoryEntry>.unmodifiable(updated);
    });
  }

  /// 移除指定 BV 号的本机观看记录，并返回移除后的记录列表。
  Future<List<WatchHistoryEntry>> remove(String bvid) => removeMany([bvid]);

  /// Removes the selected local history IDs in one write; no native resume,
  /// learning progress, or online account storage is touched.
  Future<List<WatchHistoryEntry>> removeMany(Iterable<String> bvids) async {
    final ids = bvids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return loadHistory();
    final preferences = await _preferencesLoader();
    return _mutate(preferences, () async {
      final raw = preferences.getString(_storageKey);
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List<Object?>) throw const FormatException();
      // Keep unrelated rows verbatim in structure, including legacy
      // fields/metadata and records skipped by the tolerant history reader.
      final remaining = decoded.where((item) {
        final bvid = item is Map<String, dynamic> ? item['bvid'] : null;
        return bvid is! String || !ids.contains(bvid.trim());
      }).toList();
      if (remaining.length == decoded.length) return _decodeEntries(raw);
      final encoded = jsonEncode(remaining);
      try {
        if (!await preferences.setString(_storageKey, encoded)) {
          throw StateError('Watch history removal was not saved');
        }
      } catch (_) {
        // SharedPreferences updates its cache even if the write is rejected.
        try {
          await preferences.reload();
        } catch (_) {
          // Report the original write failure to the page.
        }
        rethrow;
      }
      return _decodeEntries(encoded);
    });
  }

  /// 清空设备上的所有观看记录，并返回空的页面状态列表。
  Future<List<WatchHistoryEntry>> clear() async {
    final preferences = await _loadAvailablePreferences();
    if (preferences != null) {
      await _mutate(preferences, () async {
        try {
          await preferences.remove(_storageKey);
        } catch (_) {
          // 读取器不可用时保持幂等，页面仍可立即切换为空状态。
        }
      });
    }
    return const <WatchHistoryEntry>[];
  }

  /// 将内存中的记录序列化后写入本机；失败时仍保留调用方的内存结果。
  Future<void> _writeEntries(
    SharedPreferences preferences,
    List<WatchHistoryEntry> entries,
  ) async {
    try {
      final String encoded = jsonEncode(
        entries.map((WatchHistoryEntry entry) => entry.toJson()).toList(),
      );
      await preferences.setString(_storageKey, encoded);
    } catch (_) {
      // SharedPreferences 不可用不应让播放器因记录失败而中断。
    }
  }

  /// 解析本机 JSON，并只保留合法、去重且不超过上限的记录。
  List<WatchHistoryEntry> _decodeEntries(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return const <WatchHistoryEntry>[];
    }

    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List<Object?>) {
        return const <WatchHistoryEntry>[];
      }

      final Set<String> seenBvids = <String>{};
      final List<WatchHistoryEntry> entries = <WatchHistoryEntry>[];
      for (final Object? item in decoded) {
        if (item is! Map<String, dynamic>) {
          continue;
        }
        final WatchHistoryEntry? entry = WatchHistoryEntry.tryParse(item);
        if (entry == null || !seenBvids.add(entry.bvid)) {
          continue;
        }
        entries.add(entry);
        if (entries.length == maximumEntries) {
          break;
        }
      }
      return List<WatchHistoryEntry>.unmodifiable(entries);
    } catch (_) {
      // JSON 格式被截断或手动修改时按空记录处理，避免启动崩溃。
      return const <WatchHistoryEntry>[];
    }
  }

  /// 清理调用方传入的文本字段，并拒绝不完整的观看记录。
  WatchHistoryEntry? _normalizeEntry(WatchHistoryEntry entry) {
    return WatchHistoryEntry.tryParse(entry.toJson());
  }
}
