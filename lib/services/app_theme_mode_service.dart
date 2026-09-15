import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 允许测试用内存版 SharedPreferences 替代真实设备存储。
typedef ThemeModePreferencesLoader = Future<SharedPreferences> Function();

/// 应用默认的主题强调色，与旧版本主题保持一致。
const int defaultThemeSeedColorValue = 0xFF1677FF;

/// 当前设备读取和保存全应用外观模式与主题强调色，不会上传用户选择。
class AppThemeModeService {
  /// 创建主题偏好服务；生产环境默认使用 SharedPreferences。
  const AppThemeModeService({ThemeModePreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader;

  static const String _themeModeKey = 'appearance.theme_mode';
  static const String _themeColorKey = 'appearance.theme_color';
  final ThemeModePreferencesLoader? _preferencesLoader;

  /// 读取上次选择；首次安装、旧版本或异常值统一回到“跟随系统”。
  Future<ThemeMode> load() async {
    final SharedPreferences preferences = await _loadPreferences();
    return _decode(preferences.getString(_themeModeKey));
  }

  /// 保存浅色、深色或跟随系统；底层拒绝写入时抛错供界面恢复旧值。
  Future<void> save(ThemeMode mode) async {
    final SharedPreferences preferences = await _loadPreferences();
    final bool saved = await preferences.setString(
      _themeModeKey,
      _encode(mode),
    );
    if (!saved) {
      throw StateError('无法保存主题模式');
    }
  }

  /// 读取上次选择的主题强调色；未设置或异常值使用默认品牌蓝。
  Future<Color> loadColor() async {
    final SharedPreferences preferences = await _loadPreferences();
    final int? value = preferences.getInt(_themeColorKey);
    if (value == null || value <= 0 || value > 0xFFFFFFFF) {
      return const Color(defaultThemeSeedColorValue);
    }
    return Color(value);
  }

  /// 保存新的主题强调色；底层拒绝写入时抛错供界面恢复旧值。
  Future<void> saveColor(Color color) async {
    final SharedPreferences preferences = await _loadPreferences();
    final bool saved = await preferences.setInt(
      _themeColorKey,
      color.toARGB32(),
    );
    if (!saved) {
      throw StateError('无法保存主题颜色');
    }
  }

  /// 清除自定义主题颜色，恢复应用默认品牌蓝。
  Future<void> resetColor() async {
    final SharedPreferences preferences = await _loadPreferences();
    await preferences.remove(_themeColorKey);
  }

  /// 获取可用的本地偏好实例，测试注入优先于真实设备插件。
  Future<SharedPreferences> _loadPreferences() {
    return _preferencesLoader?.call() ?? SharedPreferences.getInstance();
  }

  /// 把 Flutter 枚举转换成跨版本稳定的本地字符串。
  String _encode(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
  }

  /// 把本地字符串还原为 Flutter 枚举，无法识别时使用安全默认值。
  ThemeMode _decode(String? value) {
    return switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }
}
