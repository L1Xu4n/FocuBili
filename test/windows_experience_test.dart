import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/windows_experience_service.dart';
import 'package:focubili/services/focus_share_service.dart';
import 'package:focubili/services/player_route_session.dart';

/// Verifies typed bridge payloads and playback navigation ownership without real OS mutation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Windows share chooses image clipboard while Android retains native sharing',
    () {
      expect(
        const FocusShareService(
          platform: AppPlatform.windows,
        ).copiesToClipboard,
        isTrue,
      );
      expect(
        const FocusShareService(
          platform: AppPlatform.android,
        ).copiesToClipboard,
        isFalse,
      );
    },
  );

  test(
    'clipboard sends image bytes rather than a local filename, fullscreen guard releases',
    () async {
      const channel = MethodChannel('test/windows-experience');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'copyImage' ? null : true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const service = WindowsExperienceService(channel: channel);
      await service.copyImage(
        png: Uint8List.fromList([137, 80, 78, 71]),
        rgba: Uint8List.fromList([255, 0, 0, 255]),
        width: 1,
        height: 1,
      );
      await service.setFullscreenProtection(true);
      await service.setFullscreenProtection(false);
      expect(calls.map((call) => call.method), [
        'copyImage',
        'setFullscreenProtection',
        'setFullscreenProtection',
      ]);
      expect((calls.first.arguments as Map)['rgba'], [255, 0, 0, 255]);
      expect((calls.first.arguments as Map).containsKey('filePath'), isFalse);
      expect((calls.last.arguments as Map)['enabled'], isFalse);
    },
  );

  test(
    'external navigation waits for pause and never restores a disposed player',
    () async {
      final paused = Completer<void>();
      var restores = 0;
      var pauseCalls = 0;
      final session = PlayerRouteSession(
        pause: () {
          pauseCalls++;
          return paused.future;
        },
        restore: () async {
          restores++;
        },
      )..attach();
      var ready = false;
      final lease = PlayerRouteSession.suspendCurrent().then((value) {
        ready = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(pauseCalls, 1);
      expect(ready, isFalse);
      paused.complete();
      final previous = await lease;
      await previous!.restoreIfAttached();
      expect(restores, 1);
      session.detach();
      await previous.restoreIfAttached();
      expect(restores, 1);
      expect(await PlayerRouteSession.suspendCurrent(), isNull);
    },
  );

  test(
    'Bilibili pink and rose remain visibly different after Material color generation',
    () {
      for (final dark in [false, true]) {
        final pink = dark
            ? AppTheme.dark(seedColor: const Color(0xFFFB7299))
            : AppTheme.light(seedColor: const Color(0xFFFB7299));
        final rose = dark
            ? AppTheme.dark(seedColor: const Color(0xFFC2188B))
            : AppTheme.light(seedColor: const Color(0xFFC2188B));
        final a = pink.colorScheme.primary;
        final b = rose.colorScheme.primary;
        final distance =
            (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
        expect(distance, greaterThan(0.12));
      }
    },
  );
}
