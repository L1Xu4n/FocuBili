import '../platform/platform_services.dart';
import 'native_playback_service.dart';

/// 通过统一平台装配器创建播放服务，未知平台不会回退到 Android。
PlaybackService createDefaultPlaybackService({
  PlatformServices? platformServices,
}) {
  return (platformServices ?? PlatformServices.current).createPlaybackService();
}
