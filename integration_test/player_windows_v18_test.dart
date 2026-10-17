import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_action_feedback.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'package:focubili/services/bilibili_player_enhancement_service.dart';
import 'package:focubili/services/player_overlay_service.dart';
import 'package:focubili/models/video_preview.dart';
import 'media_fixture.dart';

/// Real decoder/texture and real PlayerPage; only the media source is synthetic.
class _FixturePlayback extends WindowsPlaybackService {
  _FixturePlayback(this.path);
  final String path;

  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) => openLocalFile(
    filePath: path,
    video: video,
    part: part,
    initialPosition: initialPosition,
  );

  // Verify the gesture UI without changing the sleeping user's system volume.
  @override
  Future<void> setMediaVolume(double volume) async {}
}

class _EmptyOverlayChannel implements PlayerOverlayPlatformChannel {
  @override
  Future<Object?> invokeMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => null;
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue);
}

Future<void> _doubleTap(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 65));
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows decoded video: repeated seek, controls, speed and notices',
    (tester) async {
      if (!Platform.isWindows) return;
      SharedPreferences.setMockInitialValues({});
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'focubili_v18_player_',
      );
      final file = File('${root.path}/fixture.mp4');
      await file.writeAsBytes(base64Decode(appleSmokeVideoBase64));
      final playback = _FixturePlayback(file.path);
      var snapshot = const PlaybackSnapshot();
      final subscription = playback.states.listen((value) => snapshot = value);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              video: VideoPreview.placeholder(),
              playbackService: playback,
              playerOverlayService: NativePlayerOverlayService(
                platformChannel: _EmptyOverlayChannel(),
              ),
              playerEnhancementService: BilibiliPublicPlayerEnhancementService(
                requestJson: (_) async => '{"code":0,"data":{}}',
              ),
            ),
          ),
        );
        await _until(
          tester,
          () =>
              snapshot.phase == PlaybackPhase.ready &&
              snapshot.position > Duration.zero,
        );
        await playback.pause();
        await tester.pump(const Duration(milliseconds: 200));
        final surface = tester.getRect(find.byKey(const Key('player-surface')));
        await tester.tapAt(surface.center);
        await tester.pump(const Duration(milliseconds: 550));
        await _doubleTap(tester, surface.center);
        await _until(tester, () => snapshot.isPlaying);
        expect(
          tester
              .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
              .opacity,
          0,
        );
        await _doubleTap(tester, surface.center);
        await _until(tester, () => !snapshot.isPlaying);
        expect(
          tester
              .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
              .opacity,
          0,
        );
        for (var i = 0; i < 3; i++) {
          await _doubleTap(
            tester,
            Offset(surface.left + surface.width * .2, surface.center.dy),
          );
        }
        expect(find.byType(PlayerSeekFeedback), findsOneWidget);
        final viewport = tester.getRect(
          find.byKey(const Key('player-feedback-viewport')),
        );
        final direction = tester.getRect(find.byType(PlayerSeekFeedback));
        expect(viewport.contains(direction.center), isTrue);
        await tester.pump(const Duration(milliseconds: 1400));
        await playback.seekTo(Duration.zero);
        await playback.play();
        final hold = await tester.startGesture(surface.center);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await _until(tester, () => snapshot.speed == 3);
        final speedBefore = tester.getRect(
          find.byKey(const Key('temporary-triple-speed')),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          tester.getRect(find.byKey(const Key('temporary-triple-speed'))),
          speedBefore,
        );
        await hold.up();
        await _until(tester, () => snapshot.speed == 1);
        expect(snapshot.duration.inSeconds, greaterThanOrEqualTo(3));
        expect(tester.takeException(), isNull);
      } finally {
        await subscription.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await root.delete(recursive: true);
      }
    },
  );
}
