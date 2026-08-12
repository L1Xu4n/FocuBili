import '../platform/platform_services.dart';
import 'bilibili_cookie_store.dart';

/// 通过统一平台装配器创建安全 Cookie 容器，未知平台不会回退到 Android。
BilibiliCookieStore createDefaultBilibiliCookieStore({
  PlatformServices? platformServices,
}) {
  return (platformServices ?? PlatformServices.current)
      .createBilibiliCookieStore();
}
