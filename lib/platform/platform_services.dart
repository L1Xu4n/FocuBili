import 'dart:async';

import '../models/player_overlay_data.dart';
import '../models/video_preview.dart';
import '../services/bilibili_cookie_store.dart';
import '../services/desktop_player_overlay_service.dart';
import '../services/focus_notification_service.dart';
import '../services/media_cache_service.dart';
import '../services/native_playback_service.dart';
import '../services/player_overlay_service.dart';
import '../services/windows_playback_service.dart';
import 'app_platform.dart';
import 'platform_capabilities.dart';

/// 作为唯一平台装配入口，根据能力表创建当前平台的具体服务实现。
class PlatformServices {
  /// 创建绑定到指定平台的装配器，测试可以覆盖所有平台而不依赖宿主系统。
  PlatformServices.forPlatform(AppPlatform platform)
    : capabilities = PlatformCapabilities.forPlatform(platform);

  /// 创建绑定当前真实操作系统的生产装配器。
  PlatformServices.currentPlatform()
    : capabilities = PlatformCapabilities.forPlatform(
        AppPlatformDetector.current,
      );

  /// 保存进程内共享的默认装配器；它只保存能力，不提前创建播放器等资源。
  static final PlatformServices current = PlatformServices.currentPlatform();

  final PlatformCapabilities capabilities;

  /// 返回当前装配器绑定的明确平台枚举。
  AppPlatform get platform => capabilities.platform;

  /// 创建 Android Media3、Windows media_kit 或明确不可用的播放服务。
  PlaybackService createPlaybackService() {
    return switch (capabilities.playbackBackend) {
      PlaybackBackendKind.androidMedia3 => NativePlaybackService(),
      PlaybackBackendKind.mediaKit => WindowsPlaybackService(),
      PlaybackBackendKind.unavailable => const _UnavailablePlaybackService(),
    };
  }

  /// 创建 Android 方法通道、桌面 Dart 网络或明确不可用的字幕弹幕服务。
  PlayerOverlayService createPlayerOverlayService() {
    return switch (capabilities.playerOverlayBackend) {
      PlayerOverlayBackendKind.androidChannel => NativePlayerOverlayService(),
      PlayerOverlayBackendKind.dartHttp => DesktopPlayerOverlayService(),
      PlayerOverlayBackendKind.unavailable =>
        const _UnavailablePlayerOverlayService(),
    };
  }

  /// 创建 Android 持久缓存、Windows 播放缓冲或明确不可用的缓存服务。
  MediaCacheService createMediaCacheService() {
    return switch (capabilities.mediaCacheBackend) {
      MediaCacheBackendKind.androidMedia3 => NativeMediaCacheService(),
      MediaCacheBackendKind.windowsMediaKit => WindowsMediaCacheService(),
      MediaCacheBackendKind.unavailable =>
        const _UnavailableMediaCacheService(),
    };
  }

  /// 创建 Android WebView、Windows 加密存储或不会落盘的不可用 Cookie 容器。
  BilibiliCookieStore createBilibiliCookieStore() {
    return switch (capabilities.cookieStoreBackend) {
      CookieStoreBackendKind.androidWebView =>
        const PlatformBilibiliCookieStore(),
      CookieStoreBackendKind.windowsSecureStorage =>
        WindowsSecureBilibiliCookieStore(),
      CookieStoreBackendKind.unavailable =>
        const UnavailableBilibiliCookieStore(),
    };
  }

  /// 创建显式绑定 Android、Windows 或 unavailable 的专注通知服务。
  FocusNotificationService createFocusNotificationService() {
    return FocusNotificationService(platform: platform);
  }
}

/// 在尚未实现播放器的平台返回稳定错误状态，绝不调用 Android 方法通道。
class _UnavailablePlaybackService implements PlaybackService {
  /// 创建不申请纹理、解码器或系统资源的不可用播放服务。
  const _UnavailablePlaybackService();

  /// 向每个订阅者发送一次明确的播放器不可用状态。
  @override
  Stream<PlaybackSnapshot> get states => Stream<PlaybackSnapshot>.value(
    const PlaybackSnapshot(
      phase: PlaybackPhase.error,
      message: '当前平台暂不支持视频播放。',
    ),
  );

  /// 不创建视频纹理，并以空编号表示当前平台没有播放后端。
  @override
  Future<int?> initialize() async => null;

  /// 未支持平台不会打开视频，错误状态已经通过状态流提供给页面。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {}

  /// 未支持平台没有可继续的播放会话。
  @override
  Future<void> play() async {}

  /// 未支持平台没有可暂停的播放会话。
  @override
  Future<void> pause() async {}

  /// 未支持平台忽略相对进度跳转。
  @override
  Future<void> seekBy(Duration offset) async {}

  /// 未支持平台忽略绝对进度跳转。
  @override
  Future<void> seekTo(Duration position) async {}

  /// 未支持平台忽略倍速设置。
  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  /// 未支持平台忽略清晰度切换。
  @override
  Future<void> selectQuality(int quality) async {}

  /// 未支持平台没有可恢复的本地播放记录。
  @override
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid) async => null;

  /// 返回中性亮度和音量，避免手势层读取到非法数值。
  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async {
    return const SystemPlaybackLevels(brightness: 0.5, volume: 0.5);
  }

  /// 未支持平台忽略应用内亮度调整。
  @override
  Future<void> setScreenBrightness(double brightness) async {}

  /// 未支持平台忽略媒体音量调整。
  @override
  Future<void> setMediaVolume(double volume) async {}

  /// 未支持平台明确拒绝画中画请求。
  @override
  Future<bool> enterPictureInPicture(double aspectRatio) async => false;

  /// 未支持平台没有可截取的视频画面。
  @override
  Future<String?> captureCurrentFrame() async => null;

  /// 不可用服务没有已申请资源，释放操作安全返回。
  @override
  Future<void> dispose() async {}
}

/// 为尚未实现字幕和弹幕的平台返回可展示的不可用结果。
class _UnavailablePlayerOverlayService implements PlayerOverlayService {
  /// 创建不发起网络请求或平台通道调用的叠加服务。
  const _UnavailablePlayerOverlayService();

  /// 返回当前平台暂不支持字幕轨道的明确状态。
  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async {
    return const SubtitleTrackLoadResult.unavailable(message: '当前平台暂不支持读取字幕。');
  }

  /// 返回当前平台暂不支持字幕内容的明确状态。
  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async {
    return const SubtitleCueLoadResult.unavailable(message: '当前平台暂不支持读取字幕。');
  }

  /// 返回当前平台暂不支持弹幕分段的明确状态。
  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    return DanmakuSegmentLoadResult.unavailable(
      segmentIndex: segmentIndex,
      message: '当前平台暂不支持读取弹幕。',
    );
  }
}

/// 在没有安全缓存实现的平台拒绝读写，防止误调用 Android 通道。
class _UnavailableMediaCacheService implements MediaCacheService {
  /// 创建不接触任何文件或平台通道的缓存服务。
  const _UnavailableMediaCacheService();

  /// 明确报告当前平台没有可管理的视频缓存。
  @override
  Future<MediaCacheStatus> loadStatus() async {
    throw const MediaCacheException('cache_unavailable', '当前平台暂不支持视频缓存管理。');
  }

  /// 拒绝在当前平台保存没有实现的缓存容量。
  @override
  Future<MediaCacheStatus> setCapacityBytes(int capacityBytes) async {
    throw const MediaCacheException('cache_unavailable', '当前平台暂不支持视频缓存管理。');
  }

  /// 拒绝清理未知平台文件，避免越过应用缓存边界。
  @override
  Future<MediaCacheStatus> clearCache() async {
    throw const MediaCacheException('cache_unavailable', '当前平台暂不支持视频缓存管理。');
  }
}
