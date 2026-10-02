import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'refactor_r3_feedback_test.dart'
    show FeedbackPlayback, FeedbackLibrary, video;

/// Detects accidental seek commands when a second finger cancels a single-finger preview.
class PictureGesturePlayback extends FeedbackPlayback {
  int seeks = 0;

  /// Records absolute seek requests without using a real platform player.
  @override
  Future<void> seekTo(Duration position) async => seeks++;

  /// Records relative seek requests so paired reset taps cannot silently fast-forward.
  @override
  Future<void> seekBy(Duration offset) async => seeks++;
}

/// Checks the real mobile player integration and isolation from playback controls.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'mobile picture transform is fullscreen-only and never commits a scrub',
    (tester) async {
      final backend = PictureGesturePlayback();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            video: video,
            appPlatform: AppPlatform.android,
            playbackService: backend,
            offlineVideoService: FeedbackLibrary(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('进入全屏'));
      await tester.pumpAndSettle();
      final picture = find.byKey(
        const Key('fullscreen-video-picture-transform'),
      );
      final center = tester.getCenter(picture);
      final first = await tester.createGesture(pointer: 1);
      final second = await tester.createGesture(pointer: 2);
      await first.down(center - const Offset(50, 0));
      await first.moveBy(const Offset(25, 0));
      await tester.pump();
      await second.down(center + const Offset(50, 0));
      await tester.pump();
      await first.moveTo(center - const Offset(100, 25));
      await second.moveTo(center + const Offset(100, 25));
      await tester.pump();
      expect(
        tester.widget<Transform>(picture).transform.entry(0, 0),
        greaterThan(1),
      );
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(backend.seeks, 0);
      await tester.tap(find.byTooltip('退出全屏'));
      await tester.pumpAndSettle();
      expect(tester.widget<Transform>(picture).transform, Matrix4.identity());
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
