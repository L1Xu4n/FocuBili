import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/profile/login_page.dart';
import 'package:focubili/features/profile/system_capabilities_page.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/platform/platform_capabilities.dart';
import 'package:focubili/platform/platform_services.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/media_cache_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/player_overlay_service.dart';

/// 验证统一平台检测、能力表和服务装配不会把未来平台误当成 Android。
void main() {
  /// 覆盖所有已知系统名和未知环境，保证检测结果可以被穷尽处理。
  test('平台检测器区分五个目标系统和未知平台', () {
    expect(
      AppPlatformDetector.resolve(
        isAndroid: true,
        isWindows: false,
        isIOS: false,
        isMacOS: false,
        isLinux: false,
      ),
      AppPlatform.android,
    );
    expect(
      AppPlatformDetector.resolve(
        isAndroid: false,
        isWindows: true,
        isIOS: false,
        isMacOS: false,
        isLinux: false,
      ),
      AppPlatform.windows,
    );
    expect(
      AppPlatformDetector.resolve(
        isAndroid: false,
        isWindows: false,
        isIOS: true,
        isMacOS: false,
        isLinux: false,
      ),
      AppPlatform.ios,
    );
    expect(
      AppPlatformDetector.resolve(
        isAndroid: false,
        isWindows: false,
        isIOS: false,
        isMacOS: true,
        isLinux: false,
      ),
      AppPlatform.macos,
    );
    expect(
      AppPlatformDetector.resolve(
        isAndroid: false,
        isWindows: false,
        isIOS: false,
        isMacOS: false,
        isLinux: true,
      ),
      AppPlatform.linux,
    );
    expect(
      AppPlatformDetector.resolve(
        isAndroid: false,
        isWindows: false,
        isIOS: false,
        isMacOS: false,
        isLinux: false,
      ),
      AppPlatform.unsupported,
    );
  });

  /// 验证第一优先级平台继续使用已经过实际验证的现有后端。
  test('Android 和 Windows 能力表保留现有播放与系统集成', () {
    final PlatformCapabilities android = PlatformCapabilities.forPlatform(
      AppPlatform.android,
    );
    final PlatformCapabilities windows = PlatformCapabilities.forPlatform(
      AppPlatform.windows,
    );

    expect(android.playbackBackend, PlaybackBackendKind.androidMedia3);
    expect(
      android.playerOverlayBackend,
      PlayerOverlayBackendKind.androidChannel,
    );
    expect(android.mediaCacheBackend, MediaCacheBackendKind.androidMedia3);
    expect(android.cookieStoreBackend, CookieStoreBackendKind.androidWebView);
    expect(
      android.focusNotificationBackend,
      FocusNotificationBackendKind.androidChannel,
    );
    expect(android.loginExperience, LoginExperience.officialWebView);
    expect(android.supportsPictureInPicture, isTrue);
    expect(android.supportsDoNotDisturb, isTrue);

    expect(windows.playbackBackend, PlaybackBackendKind.mediaKit);
    expect(windows.playerOverlayBackend, PlayerOverlayBackendKind.dartHttp);
    expect(windows.mediaCacheBackend, MediaCacheBackendKind.windowsMediaKit);
    expect(
      windows.cookieStoreBackend,
      CookieStoreBackendKind.windowsSecureStorage,
    );
    expect(
      windows.focusNotificationBackend,
      FocusNotificationBackendKind.windowsToast,
    );
    expect(windows.loginExperience, LoginExperience.officialQrCode);
    expect(windows.supportsDesktopWindow, isTrue);
  });

  /// 验证尚未开发的三个目标平台和未知环境都保持明确不可用。
  test('未来平台在实现前不会回退到 Android 后端', () {
    for (final AppPlatform platform in <AppPlatform>[
      AppPlatform.ios,
      AppPlatform.macos,
      AppPlatform.linux,
      AppPlatform.unsupported,
    ]) {
      final PlatformCapabilities capabilities =
          PlatformCapabilities.forPlatform(platform);
      expect(capabilities.playbackBackend, PlaybackBackendKind.unavailable);
      expect(
        capabilities.playerOverlayBackend,
        PlayerOverlayBackendKind.unavailable,
      );
      expect(capabilities.mediaCacheBackend, MediaCacheBackendKind.unavailable);
      expect(
        capabilities.cookieStoreBackend,
        CookieStoreBackendKind.unavailable,
      );
      expect(
        capabilities.focusNotificationBackend,
        FocusNotificationBackendKind.unavailable,
      );
      expect(capabilities.loginExperience, LoginExperience.unavailable);
      expect(capabilities.updateTargetPlatform, AppUpdateTargetPlatform.other);
    }
  });

  /// 验证 Android 装配器仍创建原有 Media3、方法通道和 WebView 存储实现。
  test('Android 装配器创建既有服务实现', () async {
    final PlatformServices services = PlatformServices.forPlatform(
      AppPlatform.android,
    );
    final PlaybackService playback = services.createPlaybackService();
    addTearDown(playback.dispose);

    expect(playback, isA<NativePlaybackService>());
    expect(
      services.createPlayerOverlayService(),
      isA<NativePlayerOverlayService>(),
    );
    expect(services.createMediaCacheService(), isA<NativeMediaCacheService>());
    expect(
      services.createBilibiliCookieStore(),
      isA<PlatformBilibiliCookieStore>(),
    );
    expect(
      services.createFocusNotificationService().supportsDoNotDisturb,
      isTrue,
    );
  });

  /// 验证不可用服务以稳定状态拒绝操作，并且不会调用 Android 方法通道。
  test('未知平台服务返回安全的不可用结果', () async {
    final PlatformServices services = PlatformServices.forPlatform(
      AppPlatform.unsupported,
    );
    final PlaybackService playback = services.createPlaybackService();
    final PlaybackSnapshot snapshot = await playback.states.first;
    final PlayerOverlayService overlays = services.createPlayerOverlayService();
    final SubtitleTrackLoadResult tracks = await overlays.loadSubtitleTracks(
      bvid: 'BV1GJ411x7h7',
      cid: 1,
    );
    final MediaCacheService cache = services.createMediaCacheService();
    final BilibiliCookieStore cookies = services.createBilibiliCookieStore();

    expect(await playback.initialize(), isNull);
    expect(snapshot.phase, PlaybackPhase.error);
    expect(await playback.enterPictureInPicture(16 / 9), isFalse);
    expect(tracks.status, SubtitleLoadStatus.unavailable);
    await expectLater(
      cache.loadStatus(),
      throwsA(
        isA<MediaCacheException>().having(
          (MediaCacheException error) => error.code,
          'code',
          'cache_unavailable',
        ),
      ),
    );
    expect(await cookies.readCookies(), isEmpty);
    await expectLater(
      cookies.replaceCookies('SESSDATA=must-not-be-saved'),
      throwsUnsupportedError,
    );

    final notification = services.createFocusNotificationService();
    expect(notification.usesUnavailableBackend, isTrue);
    expect(notification.supportsDoNotDisturb, isFalse);
    expect(await notification.hasPermission(), isFalse);
    expect(
      await notification.scheduleReminder(
        sessionId: 'test',
        goal: 'test',
        reason: 'test',
        reminderAt: DateTime(2030),
      ),
      isFalse,
    );
  });

  /// 验证未支持平台的页面展示说明，而不是构建 Android 权限或登录控件。
  testWidgets('未支持平台显示安全说明页', (WidgetTester tester) async {
    final PlatformServices services = PlatformServices.forPlatform(
      AppPlatform.ios,
    );

    await tester.pumpWidget(
      MaterialApp(home: SystemCapabilitiesPage(platformServices: services)),
    );
    expect(find.text('iOS 的系统能力尚未接入'), findsOneWidget);
    expect(find.textContaining('精确闹钟'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(home: LoginPage(platformServices: services)),
    );
    expect(find.text('iOS 暂不支持账号登录'), findsOneWidget);
    expect(find.text('使用 Cookie 登录'), findsNothing);
    expect(find.byType(SegmentedButton), findsNothing);
  });
}
