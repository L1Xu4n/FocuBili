import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 集中保存应用主题，避免每个页面重复定义颜色和控件样式。
abstract final class AppTheme {
  static const Color _brandColor = Color(0xFF1677FF);

  /// 国庆红的持久化色值，与设置页色块使用同一个常量。
  static const int nationalDayRedValue = 0xFFCE2D35;

  /// 国庆红的原始主题色，同时用于识别首页的节日装饰。
  static const Color nationalDayRed = Color(nationalDayRedValue);

  /// 根据页面明暗背景返回可读的 Android 状态栏与导航栏图标颜色。
  static SystemUiOverlayStyle systemOverlayStyle(Brightness brightness) {
    final bool isLight = brightness == Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
      statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: isLight
          ? Brightness.dark
          : Brightness.light,
    );
  }

  /// 创建跟随品牌蓝色的浅色 Material 3 主题。
  static ThemeData light({Color seedColor = _brandColor}) {
    return _buildTheme(Brightness.light, seedColor);
  }

  /// 创建适合夜间观看的深色 Material 3 主题。
  static ThemeData dark({Color seedColor = _brandColor}) {
    return _buildTheme(Brightness.dark, seedColor);
  }

  /// Preserves a chosen accent's chroma while meeting text contrast on its surface.
  static Color _accessibleAccent(
    Color seed,
    Color surface,
    Brightness brightness,
  ) {
    final target = brightness == Brightness.dark ? Colors.white : Colors.black;
    final background = surface.computeLuminance();
    for (var step = 0; step <= 20; step++) {
      final candidate = Color.lerp(seed, target, step / 20)!;
      final luminance = candidate.computeLuminance();
      final contrast = luminance > background
          ? (luminance + 0.05) / (background + 0.05)
          : (background + 0.05) / (luminance + 0.05);
      if (contrast >= 4.5) return candidate;
    }
    return target;
  }

  /// 根据明暗模式生成共享的圆角、颜色和导航栏样式。
  static ThemeData _buildTheme(Brightness brightness, Color seedColor) {
    ColorScheme colors = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
      dynamicSchemeVariant: seedColor == _brandColor
          ? DynamicSchemeVariant.tonalSpot
          : DynamicSchemeVariant.fidelity,
    );
    if (seedColor != _brandColor) {
      final accent = _accessibleAccent(seedColor, colors.surface, brightness);
      colors = colors.copyWith(
        primary: accent,
        onPrimary: accent.computeLuminance() > 0.179
            ? Colors.black
            : Colors.white,
      );
    }
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      extensions: <ThemeExtension<dynamic>>[
        AppThemeAccent(seedColor: seedColor),
      ],
      scaffoldBackgroundColor: colors.surface,
      switchTheme: SwitchThemeData(
        // 开关滑块独立配色，深色粉色主题也使用柔白圆圈而非黑色前景。
        thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.onSurface.withValues(alpha: 0.38);
          }
          return states.contains(WidgetState.selected)
              ? const Color(0xFFFFF8F2)
              : colors.onSurfaceVariant;
        }),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.45),
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

/// 保留未经明暗模式调整的主题色，让背景装饰准确跟随用户选择。
class AppThemeAccent extends ThemeExtension<AppThemeAccent> {
  /// 保存本次主题的原始强调色。
  const AppThemeAccent({required this.seedColor});

  final Color seedColor;

  /// 判断用户是否选中了国庆红，避免深色主题调亮后的颜色影响识别。
  bool get isNationalDay => seedColor == AppTheme.nationalDayRed;

  /// 创建更新强调色的主题扩展副本。
  @override
  AppThemeAccent copyWith({Color? seedColor}) =>
      AppThemeAccent(seedColor: seedColor ?? this.seedColor);

  /// 在主题切换动画中平滑过渡原始强调色。
  @override
  AppThemeAccent lerp(covariant AppThemeAccent? other, double t) {
    if (other == null) return this;
    return AppThemeAccent(
      seedColor: Color.lerp(seedColor, other.seedColor, t)!,
    );
  }
}
