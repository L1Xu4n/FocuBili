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

  /// 读取活动计时和历史记录；损坏数据会被跳过，不阻止应用启动。
  Future<FocusStoredState> loadState() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return FocusStoredState(
        activeSession: _decodeActive(preferences.getString(_activeStorageKey)),
        history: _decodeHistory(preferences.getString(_historyStorageKey)),
      );
    } catch (_) {
      return const FocusStoredState(
        activeSession: null,
        history: <FocusSession>[],
      );
    }
  }

  /// 原子意图地覆盖当前活动记录和历史快照；单项写入失败不会让计时页面崩溃。
  Future<void> saveState({
    required FocusSession? activeSession,
    required List<FocusSession> history,
  }) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      if (activeSession == null) {
        await preferences.remove(_activeStorageKey);
      } else {
        await preferences.setString(
          _activeStorageKey,
          jsonEncode(activeSession.toJson()),
        );
      }
      final List<FocusSession> limitedHistory = history
          .where((FocusSession item) => !item.isActive)
          .take(maximumHistoryEntries)
          .toList(growable: false);
      await preferences.setString(
        _historyStorageKey,
        jsonEncode(
          limitedHistory
              .map((FocusSession item) => item.toJson())
              .toList(growable: false),
        ),
      );
    } catch (_) {
      // 存储暂时不可用时保留控制器内存状态，用户仍可继续当前操作。
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
