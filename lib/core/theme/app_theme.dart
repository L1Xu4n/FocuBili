import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 集中保存应用主题，避免每个页面重复定义颜色和控件样式。
abstract final class AppTheme {
  static const Color _brandColor = Color(0xFF1677FF);

  /// 根据页面明暗背景返回可读的 Android 状态栏与导航栏图标颜色。
  static SystemUiOverlayStyle systemOverlayStyle(Brightness brightness) {
    final bool isLight = brightness == Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
      statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          isLight ? Brightness.dark : Brightness.light,
    );
  }

  /// 创建跟随品牌蓝色的浅色 Material 3 主题。
  static ThemeData light() {
    return _buildTheme(Brightness.light);
  }

  /// 创建适合夜间观看的深色 Material 3 主题。
  static ThemeData dark() {
    return _buildTheme(Brightness.dark);
  }

  /// 根据明暗模式生成共享的圆角、颜色和导航栏样式。
  static ThemeData _buildTheme(Brightness brightness) {
    final ColorScheme colors = ColorScheme.fromSeed(
      seedColor: _brandColor,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      cardTheme: CardTheme(
        elevation: 0,
        color: colors.surfaceVariant.withOpacity(0.45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceVariant.withOpacity(0.45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
      appBarTheme: AppBarTheme(
        systemOverlayStyle: systemOverlayStyle(brightness),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}
