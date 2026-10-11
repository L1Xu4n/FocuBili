import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import '../player_action_feedback_test.dart' show GesturePlayback, doubleTap;
import '../refactor_r3_feedback_test.dart' show video;
import '../subscription_compact_ui_test.dart'
    show loadBetaReviewFonts, captureSubscriptionUi;

void main() {
  testWidgets(
    'capture the actual desktop player feedback with a playback double',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await loadBetaReviewFonts(tester);
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark().copyWith(
              textTheme: AppTheme.dark().textTheme.apply(
                fontFamily: 'BetaReview',
              ),
            ),
            home: PlayerPage(video: video, playbackService: GesturePlayback()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surface = tester.getRect(find.byKey(const Key('player-surface')));
      await doubleTap(
        tester,
        Offset(surface.left + surface.width * .8, surface.center.dy),
      );
      // Capture before advancing fake animation time; no native player is running.
      await tester.pump(const Duration(milliseconds: 180));
      await captureSubscriptionUi(
        tester,
        key,
        'player-desktop-forward',
        settle: false,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
