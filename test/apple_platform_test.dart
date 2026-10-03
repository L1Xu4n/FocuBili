import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/platform/platform_capabilities.dart';
import 'package:focubili/platform/platform_services.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/focus_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [AppPlatform.ios, AppPlatform.macos]) {
    test('${platform.name} selects implemented Apple services', () {
      final services = PlatformServices.forPlatform(platform);
      final capabilities = services.capabilities;
      expect(platform.isApple, isTrue);
      expect(platform.isMobile, platform == AppPlatform.ios);
      expect(platform.isDesktop, platform == AppPlatform.macos);
      expect(capabilities.playbackBackend, PlaybackBackendKind.mediaKit);
      expect(
        capabilities.playerOverlayBackend,
        PlayerOverlayBackendKind.dartHttp,
      );
      expect(
        capabilities.mediaCacheBackend,
        MediaCacheBackendKind.windowsMediaKit,
      );
      expect(capabilities.loginExperience, LoginExperience.officialWebView);
      expect(
        services.createBilibiliCookieStore(),
        isA<PlatformBilibiliCookieStore>(),
      );
      expect(
        capabilities.focusNotificationBackend,
        FocusNotificationBackendKind.appleNotifications,
      );
      expect(capabilities.supportsDesktopWindow, platform == AppPlatform.macos);
      expect(capabilities.supportsDoNotDisturb, isFalse);
      expect(capabilities.supportsPictureInPicture, isTrue);
      expect(
        services.createFocusNotificationService().usesUnavailableBackend,
        isFalse,
      );
    });
    test(
      '${platform.name} reminder uses native Apple channel protocol',
      () async {
        const channel = MethodChannel('test/apple/notifications');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return call.method == 'scheduleReminder' ||
                  call.method == 'hasPermission';
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final notifications = FocusNotificationService(
          channel: channel,
          platform: platform,
        );
        expect(notifications.supportsDoNotDisturb, isFalse);
        expect(await notifications.hasPermission(), isTrue);
        expect(
          await notifications.scheduleReminder(
            sessionId: 'apple',
            goal: '学习',
            reason: 'break',
            reminderAt: DateTime(2030),
          ),
          isTrue,
        );
        await notifications.cancelReminder('apple');
        expect(calls.map((e) => e.method), [
          'hasPermission',
          'scheduleReminder',
          'cancelReminder',
        ]);
      },
    );
  }
}
