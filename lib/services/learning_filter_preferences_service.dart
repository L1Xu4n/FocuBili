import 'package:shared_preferences/shared_preferences.dart';

/// 定义学习过滤偏好使用的可替换存储读取器，便于单元测试使用内存配置。
typedef LearningFilterPreferencesLoader = Future<SharedPreferences> Function();

/// 管理学习搜索过滤的 UP 主名单：用户自定义白/黑名单。
///
/// 搜索页结合用户自定义名单做结果过滤：命中黑名单的内容一定隐藏，
/// 命中白名单的内容一定保留，其余内容继续按学习分区判断。
class LearningFilterPreferencesService {
  /// 创建学习过滤偏好服务；未传入读取器时使用设备上的 SharedPreferences。
  LearningFilterPreferencesService({
    LearningFilterPreferencesLoader? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _customWhitelistKey =
      'learning_filter.custom_creator_whitelist';
  static const String _customBlacklistKey =
      'learning_filter.custom_creator_blacklist';

  final LearningFilterPreferencesLoader _preferencesLoader;

  /// 读取用户自定义白名单；没有配置或读取失败时返回空列表。
  Future<List<String>> loadCustomWhitelist() async {
    return _loadStringList(_customWhitelistKey);
  }

  /// 保存用户自定义白名单，并返回底层存储是否写入成功。
  Future<bool> saveCustomWhitelist(List<String> names) async {
    return _saveStringList(_customWhitelistKey, names);
  }

  /// 读取用户自定义黑名单；没有配置或读取失败时返回空列表。
  Future<List<String>> loadCustomBlacklist() async {
    return _loadStringList(_customBlacklistKey);
  }

  /// 保存用户自定义黑名单，并返回底层存储是否写入成功。
  Future<bool> saveCustomBlacklist(List<String> names) async {
    return _saveStringList(_customBlacklistKey, names);
  }

  /// 从本机读取字符串列表偏好；存储不可用时返回空列表。
  Future<List<String>> _loadStringList(String key) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.getStringList(key) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// 向本机写入字符串列表偏好；存储异常时返回失败而不让设置页崩溃。
  Future<bool> _saveStringList(String key, List<String> names) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final List<String> deduplicated = <String>[];
      final Set<String> seen = <String>{};
      for (final String name in names) {
        final String trimmed = name.trim();
        if (trimmed.isEmpty || seen.contains(trimmed)) {
          continue;
        }
        seen.add(trimmed);
        deduplicated.add(trimmed);
      }
      return preferences.setStringList(key, deduplicated);
    } catch (_) {
      return false;
    }
  }
}
