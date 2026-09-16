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
  static const String _playCountFilterEnabledKey =
      'app_behavior.play_count_filter_enabled';
  static const String _playCountFilterThresholdKey =
      'app_behavior.play_count_filter_threshold';

  /// 播放量过滤可选的档位（播放量下限），与设置页滑块一一对应。
  static const List<int> playCountFilterOptions = <int>[
    10000,
    50000,
    100000,
    200000,
    500000,
    1000000,
  ];

  /// 播放量过滤默认档位，首次使用或没有旧配置时采用一万。
  static const int defaultPlayCountFilterThreshold = 10000;

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

  /// 读取播放量过滤开关；没有旧配置时默认关闭以保留全部搜索结果。
  Future<bool> loadPlayCountFilterEnabled() async {
    return _loadBool(_playCountFilterEnabledKey, defaultValue: false);
  }

  /// 保存播放量过滤开关，并返回底层存储是否写入成功。
  Future<bool> savePlayCountFilterEnabled(bool enabled) async {
    return _saveBool(_playCountFilterEnabledKey, enabled);
  }

  /// 读取播放量过滤阈值；只接受设置页滑块档位，非法值回退到默认档位。
  Future<int> loadPlayCountFilterThreshold() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final int? value = preferences.getInt(_playCountFilterThresholdKey);
      if (value == null) {
        return defaultPlayCountFilterThreshold;
      }
      return playCountFilterOptions.contains(value)
          ? value
          : defaultPlayCountFilterThreshold;
    } catch (_) {
      return defaultPlayCountFilterThreshold;
    }
  }

  /// 保存播放量过滤阈值；只允许写入滑块档位，非法值按保存失败处理。
  Future<bool> savePlayCountFilterThreshold(int value) async {
    if (!playCountFilterOptions.contains(value)) {
      return false;
    }
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.setInt(_playCountFilterThresholdKey, value);
    } catch (_) {
      return false;
    }
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
