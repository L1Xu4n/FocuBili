import 'package:shared_preferences/shared_preferences.dart';

/// 定义读取专注设置的可替换入口，组件测试可使用内存偏好设置。
typedef FocusSettingsPreferencesLoader = Future<SharedPreferences> Function();

/// 保存不会上传服务器的专注行为开关。
class FocusPreferences {
  /// 创建不可变专注设置；勿扰模式默认关闭，必须由用户主动开启。
  const FocusPreferences({
    this.enableDoNotDisturb = false,
    this.hasSeenPlayerDoNotDisturbGuide = false,
    this.hasSeenBackgroundReminderGuide = false,
  });

  final bool enableDoNotDisturb;
  final bool hasSeenPlayerDoNotDisturbGuide;
  final bool hasSeenBackgroundReminderGuide;

  /// 返回只替换指定开关的新对象，设置页面不直接修改旧状态。
  FocusPreferences copyWith({
    bool? enableDoNotDisturb,
    bool? hasSeenPlayerDoNotDisturbGuide,
    bool? hasSeenBackgroundReminderGuide,
  }) {
    return FocusPreferences(
      enableDoNotDisturb: enableDoNotDisturb ?? this.enableDoNotDisturb,
      hasSeenPlayerDoNotDisturbGuide:
          hasSeenPlayerDoNotDisturbGuide ?? this.hasSeenPlayerDoNotDisturbGuide,
      hasSeenBackgroundReminderGuide:
          hasSeenBackgroundReminderGuide ?? this.hasSeenBackgroundReminderGuide,
    );
  }
}

/// 在当前设备读取和保存专注设置，不收集权限状态或专注内容。
class FocusPreferencesService {
  /// 创建专注设置服务；未注入时使用真实 SharedPreferences。
  FocusPreferencesService({FocusSettingsPreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _doNotDisturbKey =
      'focus_preferences.enable_do_not_disturb';
  static const String _playerDoNotDisturbGuideKey =
      'focus_preferences.has_seen_player_do_not_disturb_guide';
  static const String _backgroundReminderGuideKey =
      'focus_preferences.has_seen_background_reminder_guide';

  final FocusSettingsPreferencesLoader _preferencesLoader;

  /// 读取专注开关；旧版本没有字段时保持安全的默认关闭状态。
  Future<FocusPreferences> load() async {
    final SharedPreferences preferences = await _preferencesLoader();
    return FocusPreferences(
      enableDoNotDisturb: preferences.getBool(_doNotDisturbKey) ?? false,
      hasSeenPlayerDoNotDisturbGuide:
          preferences.getBool(_playerDoNotDisturbGuideKey) ?? false,
      hasSeenBackgroundReminderGuide:
          preferences.getBool(_backgroundReminderGuideKey) ?? false,
    );
  }

  /// 保存“专注时进入勿扰模式”开关，并返回底层存储是否成功。
  Future<bool> saveDoNotDisturbEnabled(bool enabled) async {
    final SharedPreferences preferences = await _preferencesLoader();
    return preferences.setBool(_doNotDisturbKey, enabled);
  }

  /// 记录播放器专注已经展示过勿扰引导，后续使用不再重复打断用户。
  Future<bool> markPlayerDoNotDisturbGuideSeen() async {
    final SharedPreferences preferences = await _preferencesLoader();
    return preferences.setBool(_playerDoNotDisturbGuideKey, true);
  }

  /// 记录设备已经展示过后台提醒保护说明，避免每次设置闹钟都重复打断用户。
  Future<bool> markBackgroundReminderGuideSeen() async {
    final SharedPreferences preferences = await _preferencesLoader();
    return preferences.setBool(_backgroundReminderGuideKey, true);
  }
}
