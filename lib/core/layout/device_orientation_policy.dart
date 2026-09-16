import 'dart:ui' show FlutterView, Size;

import 'package:flutter/services.dart';

/// 统一计算手机、平板以及未来桌面端应该允许的屏幕方向。
abstract final class DeviceOrientationPolicy {
  /// 将 FlutterView 的物理像素换算成不受屏幕密度影响的逻辑像素。
  static Size logicalSizeForView(FlutterView view) {
    return view.physicalSize / view.devicePixelRatio;
  }

  /// 返回播放器退出后应恢复的方向：Android 平板横屏，Android 手机竖屏。
  ///
  /// 非 Android 平台返回空列表，让 Windows 等桌面系统自由调整窗口大小。
  static List<DeviceOrientation> startupOrientations({
    required Size logicalSize,
    required bool isAndroid,
  }) {
    if (!isAndroid) {
      return const <DeviceOrientation>[];
    }
    if (logicalSize.shortestSide >= AdaptiveDeviceSize.tabletShortestSide) {
      return const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const <DeviceOrientation>[DeviceOrientation.portraitUp];
  }

  /// 返回播放器期间的方向：平板维持横屏，手机可以旋转进入横屏全屏。
  ///
  /// 非 Android 平台返回空列表，播放器跟随桌面窗口而不是强制旋转。
  static List<DeviceOrientation> playerOrientations({
    required Size logicalSize,
    required bool isAndroid,
  }) {
    if (!isAndroid) {
      return const <DeviceOrientation>[];
    }
    if (logicalSize.shortestSide >= AdaptiveDeviceSize.tabletShortestSide) {
      return const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ];
  }
}

/// 保存设备类别判断使用的逻辑像素阈值，避免与具体操作系统绑定。
abstract final class AdaptiveDeviceSize {
  /// Android 将最短边达到 600dp 的设备视作平板或大屏设备。
  static const double tabletShortestSide = 600;
}
