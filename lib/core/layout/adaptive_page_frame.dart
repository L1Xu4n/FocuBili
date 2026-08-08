import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'adaptive_layout.dart';

/// 为二级页面提供统一的平板和桌面阅读宽度，同时保留手机全宽布局。
class AdaptivePageFrame extends StatelessWidget {
  /// 创建响应式内容框；子页面继续负责自己的滚动、状态和内边距。
  const AdaptivePageFrame({
    super.key,
    required this.child,
    this.maxWidth = 1120,
  });

  final Widget child;
  final double maxWidth;

  /// 根据可用宽度把平板内容居中限宽，手机上则完整使用现有页面宽度。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double contentWidth =
            constraints.maxWidth >= AdaptiveLayout.tabletBreakpoint
            ? math.min(constraints.maxWidth, maxWidth)
            : constraints.maxWidth;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            key: const Key('adaptive-page-frame'),
            width: contentWidth,
            height: constraints.maxHeight,
            child: child,
          ),
        );
      },
    );
  }
}
