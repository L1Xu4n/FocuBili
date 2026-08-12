import '../platform/platform_services.dart';
import 'media_cache_service.dart';

/// 通过统一平台装配器创建缓存服务，未知平台不会调用 Android Media3 通道。
MediaCacheService createMediaCacheService({
  PlatformServices? platformServices,
}) {
  return (platformServices ?? PlatformServices.current)
      .createMediaCacheService();
}
