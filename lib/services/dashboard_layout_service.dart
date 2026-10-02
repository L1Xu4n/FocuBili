import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/dashboard_layout.dart';

/// 允许测试注入存储实例。
typedef DashboardPreferencesLoader = Future<SharedPreferences> Function();

/// 按页面编号隔离布局，串行提交保证连续操作不会反序覆盖。
class DashboardLayoutService {
  /// 使用设备偏好或调用方提供的内存存储。
  DashboardLayoutService({DashboardPreferencesLoader? preferencesLoader})
    : _loader = preferencesLoader ?? SharedPreferences.getInstance;
  final DashboardPreferencesLoader _loader;
  Future<void> _pending = Future.value();
  final Map<String, String?> _failedWriteFallbacks = {};

  /// 返回稳定存储键，首页与个人中心互不覆盖。
  static String storageKey(String storageId) => 'dashboard.layout.$storageId';

  /// 等待已提交写入后读取，损坏格式回退默认并保留合法未知编号。
  Future<DashboardLayout> load(
    String storageId,
    List<DashboardCardDefinition> cards,
  ) async {
    await _pending;
    final preferences = await _loader();
    DashboardLayout layout = DashboardLayout(order: const []);
    try {
      final raw = _failedWriteFallbacks.containsKey(storageId)
          ? _failedWriteFallbacks[storageId]
          : preferences.getString(storageKey(storageId));
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final order = decoded['order'];
          final hidden = decoded['hidden'];
          layout = DashboardLayout(
            order: order is List ? order.whereType<String>() : const [],
            hidden: hidden is List ? hidden.whereType<String>() : const [],
          );
        }
      }
    } catch (_) {
      /* 损坏的本地配置安全恢复默认布局。 */
    }
    return layout.reconcile(cards);
  }

  /// 串行保存并报告底层拒绝或异常；调用方仅在成功后采用新布局。
  Future<void> save(String storageId, DashboardLayout layout) {
    final result = _pending.then((_) async {
      final preferences = await _loader();
      final key = storageKey(storageId);
      final previous = _failedWriteFallbacks.containsKey(storageId)
          ? _failedWriteFallbacks[storageId]
          : preferences.getString(key);
      try {
        final saved = await preferences.setString(
          key,
          jsonEncode({
            'version': 1,
            'order': layout.order,
            'hidden': layout.hidden.toList(),
          }),
        );
        if (!saved) throw StateError('无法保存卡片布局');
        _failedWriteFallbacks.remove(storageId);
      } catch (_) {
        // SharedPreferences 会先改内存缓存；失败时重新同步并保留最后成功值。
        _failedWriteFallbacks[storageId] = previous;
        try {
          await preferences.reload();
        } catch (_) {
          /* 下次读取仍使用旧快照。 */
        }
        rethrow;
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
