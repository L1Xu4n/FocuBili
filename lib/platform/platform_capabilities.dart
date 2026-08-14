import 'app_platform.dart';

/// 指定播放服务应使用的底层实现。
enum PlaybackBackendKind { androidMedia3, mediaKit, unavailable }

/// 指定字幕与弹幕服务应使用的平台数据来源。
enum PlayerOverlayBackendKind { androidChannel, dartHttp, unavailable }

/// 指定缓存页应管理 Android 持久缓存还是桌面播放缓冲。
enum MediaCacheBackendKind { androidMedia3, windowsMediaKit, unavailable }

/// 指定登录 Cookie 应保存到哪个安全容器。
enum CookieStoreBackendKind {
  androidWebView,
  windowsSecureStorage,
  unavailable,
}

/// 指定专注提醒应使用 Android 原生通道还是 Windows Toast。
enum FocusNotificationBackendKind { androidChannel, windowsToast, unavailable }

/// 指定登录页应提供官方 WebView、二维码还是不可用说明。
enum LoginExperience { officialWebView, officialQrCode, unavailable }

/// 指定系统能力入口应展示哪一套平台说明。
enum SystemCapabilitiesExperience {
  androidPermissions,
  windowsDesktop,
  unavailable,
}

/// 指定更新检查应挑选的安装包平台，其他平台只打开 Release 页面。
enum AppUpdateTargetPlatform { android, windows, other }

/// 汇总页面和服务装配需要的平台能力，避免按系统名称散落条件判断。
class PlatformCapabilities {
  /// 创建一份不可变的平台能力说明。
  const PlatformCapabilities({
    required this.platform,
    required this.playbackBackend,
    required this.playerOverlayBackend,
    required this.mediaCacheBackend,
    required this.cookieStoreBackend,
    required this.focusNotificationBackend,
    required this.loginExperience,
    required this.systemCapabilitiesExperience,
    required this.updateTargetPlatform,
    required this.supportsPictureInPicture,
    required this.supportsDoNotDisturb,
    required this.supportsDesktopWindow,
  });

  final AppPlatform platform;
  final PlaybackBackendKind playbackBackend;
  final PlayerOverlayBackendKind playerOverlayBackend;
  final MediaCacheBackendKind mediaCacheBackend;
  final CookieStoreBackendKind cookieStoreBackend;
  final FocusNotificationBackendKind focusNotificationBackend;
  final LoginExperience loginExperience;
  final SystemCapabilitiesExperience systemCapabilitiesExperience;
  final AppUpdateTargetPlatform updateTargetPlatform;
  final bool supportsPictureInPicture;
  final bool supportsDoNotDisturb;
  final bool supportsDesktopWindow;

  /// 根据明确平台建立当前已兑现的能力表，未来平台在实现前保持不可用。
  factory PlatformCapabilities.forPlatform(AppPlatform platform) {
    return switch (platform) {
      AppPlatform.android => const PlatformCapabilities(
        platform: AppPlatform.android,
        playbackBackend: PlaybackBackendKind.androidMedia3,
        playerOverlayBackend: PlayerOverlayBackendKind.androidChannel,
        mediaCacheBackend: MediaCacheBackendKind.androidMedia3,
        cookieStoreBackend: CookieStoreBackendKind.androidWebView,
        focusNotificationBackend: FocusNotificationBackendKind.androidChannel,
        loginExperience: LoginExperience.officialWebView,
        systemCapabilitiesExperience:
            SystemCapabilitiesExperience.androidPermissions,
        updateTargetPlatform: AppUpdateTargetPlatform.android,
        supportsPictureInPicture: true,
        supportsDoNotDisturb: true,
        supportsDesktopWindow: false,
      ),
      AppPlatform.windows => const PlatformCapabilities(
        platform: AppPlatform.windows,
        playbackBackend: PlaybackBackendKind.mediaKit,
        playerOverlayBackend: PlayerOverlayBackendKind.dartHttp,
        mediaCacheBackend: MediaCacheBackendKind.windowsMediaKit,
        cookieStoreBackend: CookieStoreBackendKind.windowsSecureStorage,
        focusNotificationBackend: FocusNotificationBackendKind.windowsToast,
        loginExperience: LoginExperience.officialQrCode,
        systemCapabilitiesExperience:
            SystemCapabilitiesExperience.windowsDesktop,
        updateTargetPlatform: AppUpdateTargetPlatform.windows,
        supportsPictureInPicture: false,
        supportsDoNotDisturb: false,
        supportsDesktopWindow: true,
      ),
      AppPlatform.ios ||
      AppPlatform.macos ||
      AppPlatform.linux ||
      AppPlatform.unsupported => PlatformCapabilities(
        platform: platform,
        playbackBackend: PlaybackBackendKind.unavailable,
        playerOverlayBackend: PlayerOverlayBackendKind.unavailable,
        mediaCacheBackend: MediaCacheBackendKind.unavailable,
        cookieStoreBackend: CookieStoreBackendKind.unavailable,
        focusNotificationBackend: FocusNotificationBackendKind.unavailable,
        loginExperience: LoginExperience.unavailable,
        systemCapabilitiesExperience: SystemCapabilitiesExperience.unavailable,
        updateTargetPlatform: AppUpdateTargetPlatform.other,
        supportsPictureInPicture: false,
        supportsDoNotDisturb: false,
        supportsDesktopWindow: false,
      ),
    };
  }
}
