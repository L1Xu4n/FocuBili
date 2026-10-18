import 'dart:ui' show FlutterView, Size;

import 'package:flutter/services.dart';
import '../../services/app_layout_preferences_service.dart';

/// 统一计算手机、平板以及未来桌面端应该允许的屏幕方向。
abstract final class DeviceOrientationPolicy {
  /// 将 FlutterView 的物理像素换算成不受屏幕密度影响的逻辑像素。
  static Size logicalSizeForView(FlutterView view) {
    return view.physicalSize / view.devicePixelRatio;
  }

  /// 返回 Android/iOS 退出播放器或预览后应恢复的布局方向。
  ///
  /// 桌面平台返回空列表，让窗口大小决定布局。
  static List<DeviceOrientation> startupOrientations({
    required Size logicalSize,
    required bool isMobile,
  }) {
    if (!isMobile) {
      return const <DeviceOrientation>[];
    }
    if (AppLayoutPreferencesService.activeMode == AppLayoutMode.landscape ||
        (AppLayoutPreferencesService.activeMode == AppLayoutMode.adaptive &&
            logicalSize.shortestSide >=
                AdaptiveDeviceSize.tabletShortestSide)) {
      return const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const <DeviceOrientation>[DeviceOrientation.portraitUp];
  }

  /// 返回播放器期间的方向：平板维持横屏，手机可以旋转进入横屏全屏。
  ///
  /// 桌面平台返回空列表，播放器跟随窗口而不是强制旋转。
  static List<DeviceOrientation> playerOrientations({
    required Size logicalSize,
    required bool isMobile,
  }) {
    if (!isMobile) {
      return const <DeviceOrientation>[];
    }
    if (AppLayoutPreferencesService.activeMode == AppLayoutMode.landscape ||
        (AppLayoutPreferencesService.activeMode == AppLayoutMode.adaptive &&
            logicalSize.shortestSide >=
                AdaptiveDeviceSize.tabletShortestSide)) {
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
  /// 应用将最短边达到 600 逻辑像素的移动设备视作平板或大屏设备。
  static const double tabletShortestSide = 600;
}
