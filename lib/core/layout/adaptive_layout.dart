import 'dart:ui' show Size;

/// 保存应用在手机、平板和宽窗口中共用的响应式布局尺寸。
abstract final class AdaptiveLayout {
  /// 从 600 逻辑像素起按平板或分屏宽窗口增加页面留白。
  static const double tabletBreakpoint = 600;

  /// 从 840 逻辑像素起使用更宽松的横屏平板留白。
  static const double expandedBreakpoint = 840;

  /// 从 900 逻辑像素起，在横向窗口中启用带侧边导航的工作台布局。
  static const double workspaceBreakpoint = 900;

  /// 从 1200 逻辑像素起展开侧边导航，并为辅助信息栏预留空间。
  static const double desktopBreakpoint = 1200;

  /// 紧凑工作台侧边导航的固定宽度。
  static const double compactNavigationWidth = 88;

  /// 宽屏工作台展开侧边导航的固定宽度。
  static const double expandedNavigationWidth = 216;

  /// 搜索工作台左侧条件区的舒适宽度。
  static const double searchSidebarWidth = 320;

  /// 播放器工作台右侧详情区允许使用的最小宽度，保留触控和正文可读性。
  static const double playerSidebarMinWidth = 300;

  /// 播放器工作台右侧详情区允许使用的最大宽度，把更多横向空间交给视频。
  static const double playerSidebarMaxWidth = 360;

  /// 首页专注卡片保持舒适阅读宽度，不随平板横屏无限拉长。
  static const double homeContentMaxWidth = 840;

  /// 搜索结果需要容纳封面和信息，因此允许比首页卡片稍宽。
  static const double searchContentMaxWidth = 960;

  /// “我的”页面的账号卡和功能入口保持紧凑的阅读行长。
  static const double profileContentMaxWidth = 720;

  /// 判断当前窗口是否适合横向工作台；只看窗口尺寸，方便未来复用到 Windows。
  static bool usesWorkspace(Size size) {
    return size.width >= workspaceBreakpoint && size.width > size.height;
  }

  /// 判断当前窗口是否足够宽，可以展开导航文字和更多辅助内容。
  static bool usesExpandedWorkspace(Size size) {
    return usesWorkspace(size) && size.width >= desktopBreakpoint;
  }

  /// 根据窗口宽度返回工作台左侧导航应占用的宽度。
  static double workspaceNavigationWidth(Size size) {
    return usesExpandedWorkspace(size)
        ? expandedNavigationWidth
        : compactNavigationWidth;
  }

  /// 根据可用宽度返回手机、平板和宽屏三档基础页边距。
  static double pageHorizontalPadding(
    double width, {
    double compact = 12,
    double medium = 24,
    double expanded = 32,
  }) {
    if (width >= expandedBreakpoint) {
      return expanded;
    }
    if (width >= tabletBreakpoint) {
      return medium;
    }
    return compact;
  }

  /// 计算居中限宽所需的左右边距，同时保证各宽度档位的最小留白。
  static double centeredHorizontalPadding({
    required double width,
    required double maxContentWidth,
    double compact = 12,
    double medium = 24,
    double expanded = 32,
  }) {
    final double minimumPadding = pageHorizontalPadding(
      width,
      compact: compact,
      medium: medium,
      expanded: expanded,
    );
    final double centeredPadding = (width - maxContentWidth) / 2;
    return centeredPadding > minimumPadding ? centeredPadding : minimumPadding;
  }
}
