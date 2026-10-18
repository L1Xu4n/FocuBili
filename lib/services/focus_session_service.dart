import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/focus_session.dart';

/// 定义可替换的本机偏好设置读取入口，单元测试可使用内存存储。
typedef FocusPreferencesLoader = Future<SharedPreferences> Function();

/// 保存专注模块的活动记录和历史记录快照。
class FocusStoredState {
  /// 创建一份不可变的本机专注状态。
  const FocusStoredState({required this.activeSession, required this.history});

  /// 当前仍在计时或暂停的记录；没有活动计时时为空。
  final FocusSession? activeSession;

  /// 已正常完成或提前结束的历史记录，最新一条排在最前。
  final List<FocusSession> history;
}

/// 使用 SharedPreferences 保存轻量专注记录，所有数据只留在当前设备。
class FocusSessionService {
  /// 创建专注存储服务；生产环境读取真实偏好设置，测试可以注入内存实例。
  FocusSessionService({FocusPreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _activeStorageKey = 'focubili_focus_active_session';
  static const String _historyStorageKey = 'focubili_focus_history';

  /// 最多保留 200 次历史，防止 JSON 随使用时间无限增长。
  static const int maximumHistoryEntries = 200;

  final FocusPreferencesLoader _preferencesLoader;
  static final Expando<Future<void>> _writeQueues = Expando('focus writes');

  /// 读取活动计时和历史记录，同 ID 终态历史优先；损坏项不会阻止应用启动。
  Future<FocusStoredState> loadState() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final pending = _writeQueues[preferences];
      if (pending != null) await pending;
      await preferences.reload();
      final active = _decodeActive(preferences.getString(_activeStorageKey));
      final history = _decodeHistory(preferences.getString(_historyStorageKey));
      return FocusStoredState(
        // 归档已成功而活动键清理失败时，终态是已提交的事实，不能复活旧活动快照。
        activeSession: history.any((item) => item.id == active?.id)
            ? null
            : active,
        history: history,
      );
    } catch (_) {
      return const FocusStoredState(
        activeSession: null,
        history: <FocusSession>[],
      );
    }
  }

  /// 按可恢复顺序保存双键快照；返回 false 表示未完整保存，已有持久记录仍保留。
  Future<bool> saveState({
    required FocusSession? activeSession,
    required List<FocusSession> history,
  }) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final previous = _writeQueues[preferences];
      final release = Completer<void>();
      _writeQueues[preferences] = release.future;
      if (previous != null) await previous;
      try {
        await preferences.reload();
        final List<FocusSession> limitedHistory = history
            .where((FocusSession item) => !item.isActive)
            .take(maximumHistoryEntries)
            .toList(growable: false);
        final encodedHistory = jsonEncode(
          limitedHistory
              .map((FocusSession item) => item.toJson())
              .toList(growable: false),
        );
        if (activeSession != null) {
          final storedActive = _decodeActive(
            preferences.getString(_activeStorageKey),
          );
          final storedHistory = _decodeHistory(
            preferences.getString(_historyStorageKey),
          );
          final archivingPreviousActive =
              storedActive != null &&
              storedActive.id != activeSession.id &&
              !storedHistory.any((item) => item.id == storedActive.id) &&
              limitedHistory.any((item) => item.id == storedActive.id);
          if (archivingPreviousActive) {
            // 上轮结束未落盘时，先补存它的终态；不能让新一轮覆盖唯一的旧活动记录。
            await _writeVerified(
              preferences,
              _historyStorageKey,
              encodedHistory,
            );
          }
          await _writeVerified(
            preferences,
            _activeStorageKey,
            jsonEncode(activeSession.toJson()),
          );
          if (!archivingPreviousActive) {
            // 检查点/重新打开先确认活动快照，再更新历史；失败时不删除旧终态。
            await _writeVerified(
              preferences,
              _historyStorageKey,
              encodedHistory,
            );
          }
        } else {
          final storedActive = _decodeActive(
            preferences.getString(_activeStorageKey),
          );
          final storedHistory = _decodeHistory(
            preferences.getString(_historyStorageKey),
          );
          final pruningTerminalGuard =
              storedActive != null &&
              storedHistory.any((item) => item.id == storedActive.id) &&
              !limitedHistory.any((item) => item.id == storedActive.id);
          if (pruningTerminalGuard) {
            // 删除历史前必须先清理同 ID 的旧活动键，否则会撤掉防止复活的终态记录。
            await _removeActiveVerified(preferences);
            await _writeVerified(
              preferences,
              _historyStorageKey,
              encodedHistory,
            );
          } else {
            // 结束先确认归档，再清理活动键；清理失败仍可由终态历史安全恢复。
            await _writeVerified(
              preferences,
              _historyStorageKey,
              encodedHistory,
            );
            await _removeActiveVerified(preferences);
          }
        }
        return true;
      } catch (_) {
        // 仍在写入队列内恢复缓存，避免失败后的 reload 与后续保存交错。
        try {
          await preferences.reload();
        } catch (_) {}
        rethrow;
      } finally {
        release.complete();
        if (identical(_writeQueues[preferences], release.future)) {
          _writeQueues[preferences] = null;
        }
      }
    } catch (_) {
      // 保留此前持久快照；存储不可用不会让计时页面崩溃。
      return false;
    }
  }

  Future<void> _writeVerified(
    SharedPreferences preferences,
    String key,
    String value,
  ) async {
    final saved = await preferences.setString(key, value);
    await preferences.reload();
    if (!saved || preferences.getString(key) != value) {
      throw StateError('专注记录未保存');
    }
  }

  Future<void> _removeActiveVerified(SharedPreferences preferences) async {
    if (preferences.getString(_activeStorageKey) == null) return;
    final removed = await preferences.remove(_activeStorageKey);
    await preferences.reload();
    if (!removed || preferences.getString(_activeStorageKey) != null) {
      throw StateError('旧专注活动记录未清理');
    }
  }

  /// 解析单条活动记录，并拒绝已经结束或格式损坏的数据。
  FocusSession? _decodeActive(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final FocusSession? session = FocusSession.tryParse(decoded);
      return session?.isActive == true ? session : null;
    } catch (_) {
      return null;
    }
  }

  /// 解析历史 JSON，跳过活动项、损坏项和重复编号，并限制最大数量。
  List<FocusSession> _decodeHistory(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return const <FocusSession>[];
    }
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List<Object?>) {
        return const <FocusSession>[];
      }
      final Set<String> seenIds = <String>{};
      final List<FocusSession> history = <FocusSession>[];
      for (final Object? item in decoded) {
        if (item is! Map<String, dynamic>) {
          continue;
        }
        final FocusSession? session = FocusSession.tryParse(item);
        if (session == null || session.isActive || !seenIds.add(session.id)) {
          continue;
        }
        history.add(session);
        if (history.length == maximumHistoryEntries) {
          break;
        }
      }
      return List<FocusSession>.unmodifiable(history);
    } catch (_) {
      return const <FocusSession>[];
    }
  }
}
