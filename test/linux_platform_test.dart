import 'dart:io';
import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/system_capabilities_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/platform/platform_capabilities.dart';
import 'package:focubili/platform/platform_services.dart';
import 'package:focubili/services/linux_media_session.dart';
import 'package:focubili/services/focus_share_service.dart';
import 'package:focubili/services/video_note_share_service.dart';

void main() {
  test(
    'Linux capabilities use desktop implementations without Android channels',
    () {
      final caps = PlatformCapabilities.forPlatform(AppPlatform.linux);
      expect(AppPlatform.linux.isDesktop, isTrue);
      expect(caps.playbackBackend, PlaybackBackendKind.mediaKit);
      expect(caps.playerOverlayBackend, PlayerOverlayBackendKind.dartHttp);
      expect(
        caps.cookieStoreBackend,
        CookieStoreBackendKind.windowsSecureStorage,
      );
      expect(
        caps.focusNotificationBackend,
        FocusNotificationBackendKind.linuxNotifications,
      );
      expect(caps.updateTargetPlatform, AppUpdateTargetPlatform.linux);
      expect(caps.supportsPictureInPicture, isTrue);
      expect(caps.supportsDoNotDisturb, isFalse);
    },
  );
  testWidgets(
    'Linux capabilities explain keyring, reminder lifecycle and manual DND',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SystemCapabilitiesPage(
            platformServices: PlatformServices.forPlatform(AppPlatform.linux),
          ),
        ),
      );
      expect(find.text('Linux 系统能力'), findsOneWidget);
      expect(find.text('登录与密钥环'), findsOneWidget);
      expect(find.textContaining('关闭后不能自动唤醒'), findsOneWidget);
    },
  );
  test(
    'Linux image actions use native clipboard rather than unsupported file share',
    () {
      expect(
        const FocusShareService(platform: AppPlatform.linux).copiesToClipboard,
        isTrue,
      );
      expect(
        const VideoNoteShareService(
          platform: AppPlatform.linux,
        ).copiesToClipboard,
        isTrue,
      );
    },
  );
  test(
    'Linux MPRIS exposes metadata and updates the same-second title/rate',
    () async {
      final session = LinuxMediaSession();
      addTearDown(session.dispose);
      session.update(
        title: '第一段',
        trackId: 'BV123_1',
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 9),
        playing: true,
        speed: 1,
      );
      var result = await session.getProperty(
        LinuxMediaSession.playerInterface,
        'PlaybackStatus',
      );
      expect(result.returnValues.single.toNative(), 'Playing');
      session.update(
        title: '第二段',
        trackId: 'BV123_2',
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 12),
        playing: false,
        speed: 1.5,
      );
      result = await session.getProperty(
        LinuxMediaSession.playerInterface,
        'Rate',
      );
      expect(result.returnValues.single.toNative(), 1.5);
      result = await session.getProperty(
        LinuxMediaSession.playerInterface,
        'Metadata',
      );
      expect(result.returnValues.single.toString(), contains('第二段'));
      final response = await session.setProperty(
        LinuxMediaSession.playerInterface,
        'Rate',
        const DBusDouble(10),
      );
      expect(response, isA<DBusMethodErrorResponse>());
    },
  );
  test(
    'Linux native login stays ephemeral and does not bypass TLS failures',
    () {
      final source = File(
        'third_party/desktop_webview_window/linux/webview_window.cc',
      ).readAsStringSync();
      expect(source, contains('webkit_web_context_new_ephemeral'));
      expect(source, contains('g_date_time_to_unix'));
      expect(source, contains('g_list_free_full'));
      expect(
        source,
        isNot(contains('webkit_web_context_allow_tls_certificate_for_host')),
      );
      expect(source, isNot(contains('g_main_loop_run')));
    },
  );
  test(
    'Linux volume uses player gain before the optional native ALSA controller',
    () {
      final source = File(
        'lib/services/windows_playback_service.dart',
      ).readAsStringSync();
      final getter = source.substring(
        source.indexOf('Future<SystemPlaybackLevels> getSystemPlaybackLevels'),
      );
      expect(
        getter.indexOf('if (Platform.isLinux)'),
        lessThan(getter.indexOf('VolumeController.instance.getVolume')),
      );
      expect(source, contains('_player.setVolume'));
    },
  );
}
