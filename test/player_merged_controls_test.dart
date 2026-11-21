import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_control_widgets.dart';
import 'package:focubili/features/player/widgets/player_timeline.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';

import 'player_ab_repeat_test.dart'
    show AbOverlay, AbPlayback, abVideo, configureAb, mountAb, unmountAb;
import 'player_action_feedback_test.dart' show doubleTap;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

class _Captions extends AbOverlay {
  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async => const SubtitleTrackLoadResult(
    status: SubtitleLoadStatus.available,
    message: '',
    tracks: [
      SubtitleTrack(
        id: 'synthetic',
        language: 'en',
        label: 'Synthetic captions',
        isLocked: false,
      ),
    ],
  );
  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async => const SubtitleCueLoadResult(
    status: SubtitleLoadStatus.available,
    message: '',
    cues: [
      SubtitleCue(
        from: Duration.zero,
        to: Duration(minutes: 2),
        content: 'Synthetic subtitle with A–B and buffered progress',
      ),
    ],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [const Size(360, 800), const Size(1280, 900)]) {
    testWidgets(
      'AB uses custom long-press rate and hidden double-tap pause $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await const PlaybackPreferencesService().saveLongPressPlaybackSpeed(
          2.5,
        );
        final p = AbPlayback();
        await mountAb(tester, p);
        await tester.tap(find.byTooltip('进入全屏'));
        await tester.pumpAndSettle();
        await configureAb(tester);
        final surface = tester.getRect(find.byKey(const Key('player-surface')));
        await tester.tapAt(surface.center);
        await tester.pump(const Duration(milliseconds: 550));
        final hold = await tester.startGesture(surface.center);
        await tester.pump(const Duration(milliseconds: 650));
        await tester.pump();
        expect(p.current.speed, 2.5);
        p.at(28, speed: 2.5);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 799));
        expect(p.seeks, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(p.seeks, [const Duration(seconds: 10)]);
        await hold.up();
        await tester.pump();
        expect(p.current.speed, 1);
        expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);

        // The new 1.8 gesture option must still go through the AB pause-intent path.
        await doubleTap(tester, surface.center);
        await tester.pump(const Duration(milliseconds: 100));
        expect(p.current.playRequested, isFalse);
        expect(
          tester
              .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
              .opacity,
          0,
        );
        final seekCount = p.seeks.length;
        await tester.pump(const Duration(seconds: 25));
        expect(
          p.seeks.length,
          seekCount,
          reason: 'Paused AB must never seek again',
        );
        await unmountAb(tester);
      },
    );
  }

  for (final entry in [
    (const Size(320, 900), 1.6),
    (const Size(1280, 900), 1.3),
  ]) {
    testWidgets(
      'real bottom controls measure AB, subtitle and buffer ${entry.$1}',
      (tester) async {
        tester.view.physicalSize = entry.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final p = AbPlayback();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(entry.$2)),
              child: child!,
            ),
            home: PlayerPage(
              video: abVideo,
              playbackService: p,
              initialPosition: const Duration(seconds: 20),
              playerOverlayService: _Captions(),
              offlineVideoService: ReviewOfflineLibrary(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Initial narrow player must fit',
        );
        await tester.tap(find.byTooltip('进入全屏'));
        await tester.pumpAndSettle();
        await configureAb(tester);
        await tester.tap(find.byKey(const Key('more-settings-menu')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('字幕').last);
        await tester.tap(find.text('字幕').last);
        await tester.pumpAndSettle();
        final tile = find.ancestor(
          of: find.text('Synthetic captions'),
          matching: find.byType(ListTile),
        );
        tester.widget<ListTile>(tile).onTap!();
        await tester.pumpAndSettle();
        p.emit(
          p.current.copyWith(
            bufferedRanges: const [
              PlaybackBufferRange(
                start: Duration(seconds: 10),
                end: Duration(seconds: 40),
              ),
              PlaybackBufferRange(
                start: Duration(seconds: 80),
                end: Duration(seconds: 90),
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump();
        final bottom = tester.getRect(
          find.byKey(const Key('bottom-player-bar')),
        );
        final viewport = tester.getRect(
          find.byKey(const Key('player-feedback-viewport')),
        );
        final subtitle = tester.getRect(
          find.byKey(const Key('active-subtitle')),
        );
        expect(viewport.bottom, closeTo(bottom.top - 8, .01));
        expect(subtitle.top, greaterThanOrEqualTo(viewport.top));
        expect(subtitle.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
        final slider = tester.widget<PlayerProgressSlider>(
          find.byType(PlayerProgressSlider),
        );
        final markers = tester.widget<PlayerAbRepeatMarkers>(
          find.byType(PlayerAbRepeatMarkers),
        );
        expect(slider.bufferedRanges, hasLength(2));
        expect(markers.duration, slider.duration);
        final sliderRect = tester.getRect(
          find.byKey(const Key('player-progress-slider')),
        );
        final markerRect = tester.getRect(find.byType(PlayerAbRepeatMarkers));
        expect(markerRect.left, sliderRect.left);
        expect(markerRect.width, sliderRect.width);
        expect(tester.takeException(), isNull);
        await unmountAb(tester);
      },
    );
  }
}
