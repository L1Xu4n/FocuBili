import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/apple_playback_session.dart';
import 'media_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Apple native playback and app-owned storage smoke', (
    tester,
  ) async {
    expect(Platform.isIOS || Platform.isMacOS, isTrue);
    MediaKit.ensureInitialized();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/focubili-apple-smoke.mp4');
    await file.writeAsBytes(base64Decode(appleSmokeVideoBase64));
    final player = Player();
    final controller = VideoController(player);
    final session = ApplePlaybackSession();
    try {
      await session.initialize(
        play: player.play,
        pause: player.pause,
        seek: player.seek,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Video(controller: controller, controls: NoVideoControls),
          ),
        ),
      );
      final ready = player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 30));
      await player.open(Media(file.path));
      expect((await ready).inSeconds, greaterThanOrEqualTo(3));
      await tester.pump(const Duration(seconds: 1));
      if ((player.state.width ?? 0) == 0) {
        await player.stream.width
            .firstWhere((w) => w != null && w > 0)
            .timeout(const Duration(seconds: 15));
      }
      expect(player.state.width, 160);
      await player.pause();
      await player.seek(const Duration(seconds: 2));
      await player.setRate(1.5);
      session.update(
        title: 'FocuBili test',
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 4),
        playing: false,
        speed: 1.5,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('apple_smoke', 'persisted');
      await prefs.reload();
      expect(prefs.getString('apple_smoke'), 'persisted');
      await prefs.remove('apple_smoke');
      final cookies = await const MethodChannel(
        'com.focubili.app/auth',
      ).invokeMethod<String>('readCookies');
      expect(cookies, isA<String>());
      final webview = await const MethodChannel(
        'com.focubili.app/device_status',
      ).invokeMapMethod<String, dynamic>('getWebViewInfo');
      expect(webview?['providerAvailable'], isTrue);
      final permission = await const MethodChannel(
        'com.focubili.app/focus_notifications',
      ).invokeMethod<bool>('hasPermission');
      expect(permission, isA<bool>());
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await session.dispose();
      await player.dispose();
      if (await file.exists()) await file.delete();
    }
  });
}
