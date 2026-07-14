import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/watch_history_entry.dart';

/// 定义读取本机偏好设置的可替换入口，方便单元测试使用内存存储。
typedef WatchHistoryPreferencesLoader = Future<SharedPreferences> Function();

/// 在设备本地保存最近观看过的视频，不上传或保存任何会话敏感数据。
class WatchHistoryService {
  /// 创建观看记录服务；未传入读取器时使用真实的 SharedPreferences。
  WatchHistoryService({WatchHistoryPreferencesLoader? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _storageKey = 'focubili_watch_history';

  /// 限制本机最多保存的记录数量，避免观看记录无限占用存储空间。
  static const int maximumEntries = 50;

  final WatchHistoryPreferencesLoader _preferencesLoader;

  /// 读取观看记录，跳过损坏条目、重复 BV 号和超过上限的旧数据。
  Future<List<WatchHistoryEntry>> loadHistory() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return _decodeEntries(preferences.getString(_storageKey));
    } catch (_) {
      // 本地存储暂时不可用或旧数据类型不匹配时，不阻止应用其他功能。
      return const <WatchHistoryEntry>[];
    }
  }

  /// 保存一次观看状态，并将同一 BV 号的旧记录替换为最新的一条。
  Future<List<WatchHistoryEntry>> record(WatchHistoryEntry entry) async {
    final WatchHistoryEntry? normalizedEntry = _normalizeEntry(entry);
    if (normalizedEntry == null) {
      return loadHistory();
    }

    final List<WatchHistoryEntry> existing = await loadHistory();
    final List<WatchHistoryEntry> updated = <WatchHistoryEntry>[
      normalizedEntry,
      ...existing.where(
        (WatchHistoryEntry item) => item.bvid != normalizedEntry.bvid,
      ),
    ].take(maximumEntries).toList(growable: false);
    await _writeEntries(updated);
    return List<WatchHistoryEntry>.unmodifiable(updated);
  }

  /// 移除指定 BV 号的本机观看记录，并返回移除后的记录列表。
  Future<List<WatchHistoryEntry>> remove(String bvid) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return loadHistory();
    }

    final List<WatchHistoryEntry> existing = await loadHistory();
    final List<WatchHistoryEntry> updated = existing
        .where((WatchHistoryEntry item) => item.bvid != normalizedBvid)
        .toList(growable: false);
    if (updated.length != existing.length) {
      await _writeEntries(updated);
    }
    return List<WatchHistoryEntry>.unmodifiable(updated);
  }

  /// 清空设备上的所有观看记录，并返回空的页面状态列表。
  Future<List<WatchHistoryEntry>> clear() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.remove(_storageKey);
    } catch (_) {
      // 读取器不可用时保持幂等，页面仍可立即切换为空状态。
    }
    return const <WatchHistoryEntry>[];
  }

  /// 将内存中的记录序列化后写入本机；失败时仍保留调用方的内存结果。
  Future<void> _writeEntries(List<WatchHistoryEntry> entries) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
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
