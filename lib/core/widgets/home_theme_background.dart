import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 在国庆红首页的空白处点缀五颗小五角星，适配手机和桌面背景。
class HomeThemeBackground extends StatelessWidget {
  /// 接收首页内容，装饰层不占用布局或点击区域。
  const HomeThemeBackground({super.key, required this.child});

  final Widget child;

  /// 仅为国庆红绘制淡金色星星，其他主题继续展示原有首页。
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool decorated =
        theme.extension<AppThemeAccent>()?.isNationalDay ?? false;
    final bool dark = theme.brightness == Brightness.dark;
    final Color starColor =
        (dark ? const Color(0xFFE2BD72) : const Color(0xFFB98727)).withValues(
          alpha: dark ? 0.48 : 0.42,
        );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (decorated)
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: Stack(
                  children: <Widget>[
                    _buildStar(0.10, 0.18, 16, starColor),
                    _buildStar(0.86, 0.27, 22, starColor),
                    _buildStar(0.15, 0.68, 12, starColor),
                    _buildStar(0.91, 0.77, 16, starColor),
                    _buildStar(0.63, 0.91, 13, starColor),
                  ],
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }

  /// 按背景宽高的相对位置放置五角星，避免屏幕尺寸变化时挤到中心文字。
  Widget _buildStar(double x, double y, double size, Color color) {
    return Align(
      alignment: FractionalOffset(x, y),
      child: Icon(Icons.star_rounded, size: size, color: color),
    );
  }
}
