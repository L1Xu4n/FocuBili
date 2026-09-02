import 'package:shared_preferences/shared_preferences.dart';

/// 定义应用行为偏好使用的可替换存储读取器，便于单元测试使用内存配置。
typedef AppBehaviorPreferencesLoader = Future<SharedPreferences> Function();

/// 统一管理账号写入、搜索记录和观看记录等全局行为开关。
class AppBehaviorPreferencesService {
  /// 创建行为偏好服务；未传入读取器时使用设备上的 SharedPreferences。
  AppBehaviorPreferencesService({
    AppBehaviorPreferencesLoader? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _accountReadOnlyKey = 'app_behavior.account_read_only';
  static const String _searchHistoryEnabledKey =
      'app_behavior.search_history_enabled';
  static const String _watchHistoryEnabledKey =
      'app_behavior.watch_history_enabled';

  final AppBehaviorPreferencesLoader _preferencesLoader;

  /// 读取账号只读开关；没有旧配置或读取失败时默认开启以保护账号。
  Future<bool> loadAccountReadOnly() async {
    return _loadBool(_accountReadOnlyKey, defaultValue: true);
  }

  /// 保存账号只读开关，并返回底层存储是否写入成功。
  Future<bool> saveAccountReadOnly(bool enabled) async {
    return _saveBool(_accountReadOnlyKey, enabled);
  }

  /// 读取搜索记录开关；旧版本没有配置时默认继续记录。
  Future<bool> loadSearchHistoryEnabled() async {
    return _loadBool(_searchHistoryEnabledKey, defaultValue: true);
  }

  /// 保存是否允许新增本机搜索记录。
  Future<bool> saveSearchHistoryEnabled(bool enabled) async {
    return _saveBool(_searchHistoryEnabledKey, enabled);
  }

  /// 读取观看记录开关；旧版本没有配置时默认继续记录。
  Future<bool> loadWatchHistoryEnabled() async {
    return _loadBool(_watchHistoryEnabledKey, defaultValue: true);
  }

  /// 保存是否允许新增本机观看记录。
  Future<bool> saveWatchHistoryEnabled(bool enabled) async {
    return _saveBool(_watchHistoryEnabledKey, enabled);
  }

  /// 从本机读取布尔偏好；存储不可用时使用调用方指定的安全默认值。
  Future<bool> _loadBool(String key, {required bool defaultValue}) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.getBool(key) ?? defaultValue;
    } catch (_) {
      return defaultValue;
    }
  }

  /// 向本机写入布尔偏好；存储异常时返回失败而不让设置页崩溃。
  Future<bool> _saveBool(String key, bool value) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.setBool(key, value);
    } catch (_) {
      return false;
    }
  }
}
