import '../platform/platform_services.dart';
import 'player_overlay_service.dart';

/// 通过统一平台装配器创建字幕与弹幕服务，未知平台不会调用 Android 通道。
PlayerOverlayService createDefaultPlayerOverlayService({
  PlatformServices? platformServices,
}) {
  return (platformServices ?? PlatformServices.current)
      .createPlayerOverlayService();
}
