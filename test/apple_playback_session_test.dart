import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/apple_playback_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.focubili.app/apple_media');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<void> activate(ApplePlaybackSession session) => session.initialize(
    play: () async {},
    pause: () async {},
    seek: (_) async {},
  );
  void update(
    ApplePlaybackSession session, {
    String title = 'A',
    double speed = 1,
    int duration = 60,
  }) {
    session.update(
      title: title,
      position: const Duration(seconds: 2),
      duration: Duration(seconds: duration),
      playing: true,
      speed: speed,
    );
  }

  test(
    'same-second title, duration and speed changes reach lock screen',
    () async {
      final session = ApplePlaybackSession(platform: AppPlatform.ios);
      await activate(session);
      update(session);
      update(session);
      update(session, title: 'B');
      update(session, title: 'B', speed: 1.5);
      update(session, title: 'B', speed: 1.5, duration: 120);
      await Future<void>.delayed(Duration.zero);
      final updates = calls.where((c) => c.method == 'update').toList();
      expect(updates, hasLength(4));
      expect(updates.last.arguments, containsPair('duration', 120.0));
      expect(updates.last.arguments, containsPair('rate', 1.5));
      await session.dispose();
    },
  );
  test(
    'old player disposal cannot clear the new player media session',
    () async {
      final old = ApplePlaybackSession(platform: AppPlatform.macos);
      final current = ApplePlaybackSession(platform: AppPlatform.macos);
      await activate(old);
      await activate(current);
      await old.dispose();
      update(old);
      update(current);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'deactivate'), isEmpty);
      expect(calls.where((c) => c.method == 'update'), hasLength(1));
      await current.dispose();
      expect(calls.where((c) => c.method == 'deactivate'), hasLength(1));
    },
  );
  test('disposed session cannot reactivate and non-Apple is inert', () async {
    final session = ApplePlaybackSession(platform: AppPlatform.ios);
    await session.dispose();
    await activate(session);
    final windows = ApplePlaybackSession(platform: AppPlatform.windows);
    await activate(windows);
    update(windows);
    await windows.dispose();
    expect(calls, isEmpty);
  });
}
