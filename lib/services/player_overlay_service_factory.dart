import 'dart:io';

import 'desktop_player_overlay_service.dart';
import 'player_overlay_service.dart';

/// 按当前操作系统创建字幕与弹幕服务，页面无需了解平台通道或桌面网络实现。
PlayerOverlayService createDefaultPlayerOverlayService() {
  if (Platform.isWindows) {
    return DesktopPlayerOverlayService();
  }
  return NativePlayerOverlayService();
}
