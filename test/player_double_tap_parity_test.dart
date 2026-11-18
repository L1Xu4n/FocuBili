import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_action_feedback.dart';
import 'package:focubili/features/profile/double_tap_regions_page.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/playback_video_surface.dart';
import 'player_action_feedback_test.dart'
    show GesturePlayback, fits, paintedRect;
import 'player_ab_repeat_test.dart' show AbOverlay;
import 'refactor_r3_feedback_test.dart' show video;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;
import 'subscription_compact_ui_test.dart'
    show captureSubscriptionUi, loadBetaReviewFonts;

class _SurfacePlayback extends GesturePlayback implements PlaybackVideoSurface {
  @override
  Widget buildVideoSurface() => const DecoratedBox(
    // Stand-in for decoded video: enough contrast to see the moving shade,
    // with no network, decoder, text controller or native texture.
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xff5a8b9a), Color(0xff736f8d), Color(0xff326364)],
      ),
    ),
  );
}

const _surface = Key('player-surface');
const _viewport = Key('player-feedback-viewport');
const _preview = Key('double-tap-region-preview');
const _backdrop = Key('double-tap-seek-backdrop');
const _retry = Key('retry-playback');

Future<void> _tapSide(
  WidgetTester tester, {
  required Finder surface,
  required bool forward,
  required PointerDeviceKind kind,
}) async {
  final rect = tester.getRect(surface);
  final point = Offset(
    rect.left + rect.width * (forward ? .83 : .17),
    rect.center.dy,
  );
  await tester.tapAt(point, kind: kind);
  await tester.pump(const Duration(milliseconds: 70));
  await tester.tapAt(point, kind: kind);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 180));
}

Finder _background() => find.byKey(_backdrop).evaluate().isNotEmpty
    ? find.byKey(_backdrop)
    : find.descendant(
        of: find.byType(PlayerSeekFeedback),
        matching: find.byType(DecoratedBox),
      );

Finder _triangles() => find.descendant(
  of: find.byType(PlayerSeekFeedback),
  matching: find.byType(CustomPaint),
);

Future<void> _mount(
  WidgetTester tester, {
  required GlobalKey boundary,
  required Widget page,
  required double textScale,
}) async {
  final theme = AppTheme.dark();
  const capture = String.fromEnvironment('BETA3_CAPTURE_DIR');
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: capture.isEmpty
            ? theme
            : theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'BetaReview'),
              ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, size, platform, textScale, forward) in [
    ('portrait-180pct', const Size(320, 760), AppPlatform.android, 1.8, false),
    ('landscape', const Size(820, 390), AppPlatform.android, 1.0, true),
    ('desktop', const Size(1280, 900), AppPlatform.linux, 1.0, true),
  ]) {
    testWidgets(
      'preview and real surface use the same normalized seek shape: $name',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await loadBetaReviewFonts(tester);
        final boundary = GlobalKey();
        final kind = platform == AppPlatform.android
            ? PointerDeviceKind.touch
            : PointerDeviceKind.mouse;
        await _mount(
          tester,
          boundary: boundary,
          page: const DoubleTapRegionsPage(
            regions: DoubleTapRegions(),
            service: PlaybackPreferencesService(),
          ),
          textScale: textScale,
        );
        final preview = find.byKey(_preview);
        await _tapSide(tester, surface: preview, forward: forward, kind: kind);
        await captureSubscriptionUi(
          tester,
          boundary,
          'preview-$name',
          settle: false,
        );
        final previewShape = paintedRect(tester, _background());
        final previewRect = tester.getRect(preview);
        final previewArrows = paintedRect(tester, _triangles());

        final playback = _SurfacePlayback();
        await _mount(
          tester,
          boundary: boundary,
          page: PlayerPage(
            video: video,
            appPlatform: platform,
            playbackService: playback,
            offlineVideoService: ReviewOfflineLibrary(),
            playerOverlayService: AbOverlay(),
          ),
          textScale: textScale,
        );
        final surface = find.byKey(_surface);
        if (platform == AppPlatform.android && size.width > size.height) {
          await tester.tap(find.byTooltip('进入全屏'));
          await tester.pumpAndSettle();
          expect(tester.getSize(surface), size);
        }
        await _tapSide(tester, surface: surface, forward: forward, kind: kind);
        await captureSubscriptionUi(
          tester,
          boundary,
          'player-$name',
          settle: false,
        );
        final realShape = paintedRect(tester, _background());
        final surfaceRect = tester.getRect(surface);
        final realArrows = paintedRect(tester, _triangles());
        final feedbackLane = tester.getRect(find.byKey(_viewport));
        final label = find.text(forward ? '快进 5 秒' : '快退 5 秒');
        debugPrint(
          '$name: preview ${previewShape.size}/${previewRect.size}; real ${realShape.size}/${surfaceRect.size}; arrows ${realArrows.size}; label ${paintedRect(tester, label).size}',
        );

        expect(
          realShape.height / surfaceRect.height,
          closeTo(previewShape.height / previewRect.height, .01),
        );
        expect(
          realShape.width / surfaceRect.width,
          closeTo(previewShape.width / previewRect.width, .01),
        );
        expect(
          realArrows.width / realArrows.height,
          closeTo(previewArrows.width / previewArrows.height, .05),
        );
        expect(
          forward ? realShape.right : realShape.left,
          closeTo(forward ? surfaceRect.right : surfaceRect.left, .1),
        );
        fits(paintedRect(tester, label), feedbackLane);
        fits(realArrows, feedbackLane);
        expect(paintedRect(tester, label).height, greaterThanOrEqualTo(14));

        // Repeat while the direction band is still painted. Its full height
        // must not consume touch or mouse taps.
        await _tapSide(tester, surface: surface, forward: forward, kind: kind);
        expect(
          playback.offsets.map((e) => e.inSeconds),
          forward ? [5, 5] : [-5, -5],
        );
        await tester.pump(const Duration(milliseconds: 1201));
        expect(_background(), findsNothing);
        expect(find.byType(PlayerSeekFeedback), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'short portrait loading keeps a readable line and does not shrink the band',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadBetaReviewFonts(tester);
      final boundary = GlobalKey();
      final playback = _SurfacePlayback();
      await _mount(
        tester,
        boundary: boundary,
        page: PlayerPage(
          video: video,
          appPlatform: AppPlatform.android,
          playbackService: playback,
          offlineVideoService: ReviewOfflineLibrary(),
          playerOverlayService: AbOverlay(),
        ),
        textScale: 1.8,
      );
      final surface = find.byKey(_surface);
      await _tapSide(
        tester,
        surface: surface,
        forward: true,
        kind: PointerDeviceKind.touch,
      );
      playback.controller.add(
        const PlaybackSnapshot(
          phase: PlaybackPhase.loading,
          duration: Duration(minutes: 2),
          message: '视频缓冲中',
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));
      await captureSubscriptionUi(
        tester,
        boundary,
        'portrait-loading-180pct',
        settle: false,
      );
      expect(
        tester.getSize(_background()).height,
        tester.getSize(surface).height,
      );
      final label = paintedRect(tester, find.text('快进 5 秒'));
      final loading = paintedRect(tester, find.text('视频缓冲中'));
      expect(label.height, greaterThanOrEqualTo(14));
      expect(loading.right, lessThanOrEqualTo(label.left));
      fits(loading, tester.getRect(find.byKey(_viewport)));
      await tester.pump(const Duration(milliseconds: 560));
      final fadingBand = find.ancestor(
        of: find.byKey(_backdrop),
        matching: find.byType(Opacity),
      );
      final fadingGlyphs = find.descendant(
        of: find.byType(PlayerSeekFeedback),
        matching: find.byType(Opacity),
      );
      final opacity = tester.widget<Opacity>(fadingBand.first).opacity;
      expect(opacity, inExclusiveRange(0.0, 1.0));
      expect(
        tester.widget<Opacity>(fadingGlyphs).opacity,
        closeTo(opacity, .005),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'retry owns its full lane while the noninteractive backdrop fades',
    (tester) async {
      tester.view.physicalSize = const Size(820, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadBetaReviewFonts(tester);
      final boundary = GlobalKey();
      final playback = _SurfacePlayback();
      await _mount(
        tester,
        boundary: boundary,
        page: PlayerPage(
          video: video,
          appPlatform: AppPlatform.android,
          playbackService: playback,
          offlineVideoService: ReviewOfflineLibrary(),
          playerOverlayService: AbOverlay(),
        ),
        textScale: 1.8,
      );
      await tester.tap(find.byTooltip('进入全屏'));
      await tester.pumpAndSettle();
      await _tapSide(
        tester,
        surface: find.byKey(_surface),
        forward: true,
        kind: PointerDeviceKind.touch,
      );
      playback.controller.add(
        const PlaybackSnapshot(
          phase: PlaybackPhase.error,
          message: '无法播放此视频',
          duration: Duration(minutes: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));
      await captureSubscriptionUi(
        tester,
        boundary,
        'landscape-retry-180pct',
        settle: false,
      );
      expect(_background(), findsOneWidget);
      expect(find.byType(PlayerSeekFeedback), findsNothing);
      expect(find.byKey(_retry).hitTestable(), findsOneWidget);
      final calls = playback.onlineOpens;
      await tester.tap(find.byKey(_retry));
      await tester.pump();
      expect(playback.onlineOpens, greaterThan(calls));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
