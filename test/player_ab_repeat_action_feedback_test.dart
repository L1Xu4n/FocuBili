import 'dart:async';

import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_action_feedback.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_ab_repeat_test.dart'
    show AbOverlay, AbPlayback, abVideo, configureAb, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

final _feedback = find.byType(PlayerActionFeedback);
final _playPause = find.byKey(const Key('play-pause-button'));

class _DelayedPause extends AbPlayback {
  final pauseGate = Completer<void>();

  @override
  Future<void> pause() async {
    await pauseGate.future;
    await super.pause();
  }
}

Future<void> _mount(WidgetTester t, AbPlayback p, AppPlatform platform) async {
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: abVideo,
        playbackService: p,
        appPlatform: platform,
        initialPosition: const Duration(seconds: 20),
        offlineVideoService: ReviewOfflineLibrary(),
        playerOverlayService: AbOverlay(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final platform in AppPlatform.values.where(
    (p) => p.isMobile || p.isDesktop,
  )) {
    testWidgets(
      '${platform.name}: an automatic A–B seek after the seek Future is silent',
      (t) async {
        final p = AbPlayback();
        await _mount(t, p, platform);
        await configureAb(t, a: '20', b: '30');
        p.emitOnSeek = false;
        p.at(30);
        await t.pump();
        expect(p.seeks, [const Duration(seconds: 20)]);

        // The seek Future completed earlier. On some native players ready
        // briefly reports not playing at A before the playing bit arrives.
        p.at(20, playing: false, phase: PlaybackPhase.loading);
        await t.pump();
        p.at(20, playing: false);
        await t.pump();
        expect(_feedback, findsNothing);
        p.at(20);
        await t.pump();
        expect(
          _feedback,
          findsNothing,
          reason: 'A–B is not a play button press',
        );
        expect(p.plays, 0);

        // The in-range automatic event cannot steal the next actual actions.
        await t.tap(_playPause);
        await t.pump();
        expect(t.widget<PlayerActionFeedback>(_feedback).playing, isFalse);
        await t.tap(_playPause);
        await t.pump();
        expect(t.widget<PlayerActionFeedback>(_feedback).playing, isTrue);
        await unmountAb(t);
      },
    );
  }

  testWidgets(
    'EOF ready/stopped, ended, and automatic resume are not action feedback',
    (t) async {
      final p = AbPlayback();
      await _mount(t, p, AppPlatform.windows);
      await configureAb(t, a: '110', b: '120');
      final seekCount = p.seeks.length;
      p.at(120, playing: false);
      await t.pump();
      expect(_feedback, findsNothing, reason: 'EOF stop is not a manual pause');
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await t.pump();
      expect(p.seeks.length, seekCount + 1);
      expect(p.seeks.last, const Duration(seconds: 110));
      expect(p.plays, 1);
      expect(
        _feedback,
        findsNothing,
        reason: 'resume is part of the same loop',
      );
      await unmountAb(t);
    },
  );

  testWidgets(
    'a real delayed pause during an in-flight loop still animates once',
    (t) async {
      final p = _DelayedPause();
      await _mount(t, p, AppPlatform.android);
      await configureAb(t, a: '20', b: '30');
      p.seekGate = Completer<void>();
      p.emitOnSeek = false;
      p.at(30);
      await t.pump();
      expect(p.seeks, [const Duration(seconds: 20)]);
      await t.tap(_playPause);
      await t.pump();

      p.at(21, playing: false, phase: PlaybackPhase.loading);
      await t.pump();
      p.at(21, playing: false);
      await t.pump();
      p.at(21);
      await t.pump();
      expect(
        _feedback,
        findsNothing,
        reason: 'buffer echo does not acknowledge pause',
      );
      p.pauseGate.complete();
      await t.pump();
      expect(t.widget<PlayerActionFeedback>(_feedback).playing, isFalse);
      expect(p.pauses, 1);
      p.seekGate!.complete();
      await t.pump();

      await t.tap(_playPause);
      await t.pump();
      expect(t.widget<PlayerActionFeedback>(_feedback).playing, isTrue);
      expect(p.plays, 1);
      await unmountAb(t);
    },
  );

  testWidgets(
    '5x loop accepts a late sparse ready clock without ever animating',
    (t) async {
      final p = AbPlayback();
      await _mount(t, p, AppPlatform.macos);
      await configureAb(t, a: '20', b: '21');
      p.emitOnSeek = false;
      for (var i = 0; i < 2; i++) {
        p.at(21, speed: 5);
        await t.pump();
        expect(p.seeks, List.filled(i + 1, const Duration(seconds: 20)));
        p.emit(
          p.current.copyWith(
            isPlaying: false,
            position: const Duration(milliseconds: 20400),
            speed: 5,
          ),
        );
        await t.pump();
        expect(_feedback, findsNothing);
        p.emit(p.current.copyWith(isPlaying: true));
        await t.pump();
        expect(_feedback, findsNothing);
      }
      await unmountAb(t);
    },
  );

  testWidgets(
    'older playback snapshots without intent still suppress just the automatic seek',
    (t) async {
      final p = AbPlayback();
      await _mount(t, p, AppPlatform.ios);
      await configureAb(t, a: '20', b: '30');
      p.emitOnSeek = false;
      void ready(int second, bool playing) => p.emit(
        PlaybackSnapshot(
          phase: PlaybackPhase.ready,
          isPlaying: playing,
          position: Duration(seconds: second),
          duration: const Duration(minutes: 2),
        ),
      );
      ready(30, true);
      await t.pump();
      ready(20, false);
      await t.pump();
      expect(_feedback, findsNothing);
      ready(20, true);
      await t.pump();
      expect(_feedback, findsNothing);
      ready(21, false);
      await t.pump();
      expect(t.widget<PlayerActionFeedback>(_feedback).playing, isFalse);
      await unmountAb(t);
    },
  );

  testWidgets('ordinary confirmed backend playback changes retain feedback', (
    t,
  ) async {
    final p = AbPlayback();
    await _mount(t, p, AppPlatform.linux);
    await p.pause();
    await t.pump();
    expect(t.widget<PlayerActionFeedback>(_feedback).playing, isFalse);
    await p.play();
    await t.pump();
    expect(t.widget<PlayerActionFeedback>(_feedback).playing, isTrue);
    await unmountAb(t);
  });
}
