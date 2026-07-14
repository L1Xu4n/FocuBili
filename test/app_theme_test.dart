import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/core/theme/app_theme.dart';

/// 验证浅色与深色页面会为透明系统栏提供可读的相反图标颜色。
void main() {
  /// 浅色背景必须使用深色状态栏图标，避免白底上出现不可见的白色时间和电量。
  test('浅色主题使用深色系统栏图标', () {
    final SystemUiOverlayStyle style = AppTheme.systemOverlayStyle(
      Brightness.light,
    );

    expect(style.statusBarColor, Colors.transparent);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.systemNavigationBarIconBrightness, Brightness.dark);
  });

  /// 深色背景必须使用浅色系统栏图标，保证夜间界面同样清晰可见。
  test('深色主题使用浅色系统栏图标', () {
    final SystemUiOverlayStyle style = AppTheme.systemOverlayStyle(
      Brightness.dark,
    );

    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.systemNavigationBarIconBrightness, Brightness.light);
  });
}
