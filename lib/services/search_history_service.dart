import 'package:shared_preferences/shared_preferences.dart';

/// 在设备本地保存用户主动输入过的 BV 号或视频链接。
class SearchHistoryService {
  static const String _storageKey = 'focubili_search_history';
  static const int _maximumEntries = 12;

  /// 读取最近搜索记录，并过滤空白或重复内容。
  Future<List<String>> loadHistory() async {
    try {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      final List<String> saved =
          preferences.getStringList(_storageKey) ?? const <String>[];
      final List<String> normalized = <String>[];
      for (final String item in saved) {
        final String value = item.trim();
        if (value.isNotEmpty && !normalized.contains(value)) {
          normalized.add(value);
        }
      }
      return List<String>.unmodifiable(normalized.take(_maximumEntries));
    } catch (_) {
      // 桌面测试没有注册本地存储插件时回退为空记录，不影响页面启动。
      return const <String>[];
    }
  }

  /// 将一次搜索放到记录最前面，相同内容只保留最新的一条。
  Future<List<String>> addHistory(String input) async {
    final String value = input.trim();
    if (value.isEmpty) {
      return loadHistory();
    }
    final List<String> updated = <String>[
      value,
      ...(await loadHistory()).where((String item) => item != value),
    ].take(_maximumEntries).toList(growable: false);
    try {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      await preferences.setStringList(_storageKey, updated);
      return List<String>.unmodifiable(updated);
    } catch (_) {
      // 插件暂时不可用时仍返回本次内存记录，让搜索本身继续工作。
      return List<String>.unmodifiable(updated);
    }
  }

  /// 清除全部搜索记录，并返回可直接写入页面状态的空列表。
  Future<List<String>> clearHistory() async {
    try {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      await preferences.remove(_storageKey);
    } catch (_) {
      // 测试环境无本地存储插件时无需额外处理。
    }
    return const <String>[];
  }
}
