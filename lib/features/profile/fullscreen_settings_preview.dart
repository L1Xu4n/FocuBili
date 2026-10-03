import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/layout/device_orientation_policy.dart';
import '../../platform/app_platform.dart';

/// 让设置预览使用真实全屏视口，离开时恢复原来的方向和桌面窗口状态。
Future<T?> showFullscreenSettingsPreview<T>({
  required BuildContext context,
  required AppPlatform platform,
  required WidgetBuilder builder,
}) async {
  bool? wasFullscreen;
  bool? wasMaximized;
  final mobile = platform == AppPlatform.android || platform == AppPlatform.ios;
  try {
    if (mobile) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (platform.isDesktop) {
      try {
        wasFullscreen = await windowManager.isFullScreen();
        wasMaximized = await windowManager.isMaximized();
        if (wasMaximized && !wasFullscreen) await windowManager.unmaximize();
        await windowManager.setFullScreen(true);
      } catch (_) {
        // 无原生窗口的组件检查仍可预览完整页面。
      }
    }
    if (!context.mounted) return null;
    return await Navigator.of(
      context,
    ).push<T>(MaterialPageRoute<T>(fullscreenDialog: true, builder: builder));
  } finally {
    if (mobile) {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      await SystemChrome.setPreferredOrientations(
        DeviceOrientationPolicy.startupOrientations(
          logicalSize: DeviceOrientationPolicy.logicalSizeForView(view),
          isAndroid: platform == AppPlatform.android,
        ),
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else if (platform.isDesktop && wasFullscreen != null) {
      try {
        await windowManager.setFullScreen(wasFullscreen);
        if (wasMaximized == true && !wasFullscreen) {
          await windowManager.maximize();
        }
      } catch (_) {
        // 窗口已退出时不再操作原生窗口。
      }
    }
  }
}
