import 'package:flutter/widgets.dart';

import 'focus_timer_controller.dart';

/// 把全应用唯一的专注计时控制器提供给首页、路由页面和播放器。
class FocusTimerScope extends InheritedWidget {
  /// 创建专注控制器作用域；页面再用 ListenableBuilder 选择需要刷新的小区域。
  const FocusTimerScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final FocusTimerController controller;

  /// 读取最近的专注控制器；缺少作用域时抛出便于开发定位的错误。
  static FocusTimerController of(BuildContext context) {
    final FocusTimerController? controller = maybeOf(context);
    assert(controller != null, '当前页面缺少 FocusTimerScope。');
    return controller!;
  }

  /// 尝试读取最近的专注控制器，独立播放器测试没有作用域时返回空值。
  static FocusTimerController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<FocusTimerScope>()
        ?.controller;
  }

  /// 只有根部更换为另一控制器实例时才通知依赖页面，普通每秒计时由局部监听负责。
  @override
  bool updateShouldNotify(FocusTimerScope oldWidget) {
    return controller != oldWidget.controller;
  }
}
