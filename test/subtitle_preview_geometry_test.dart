import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_text_scale.dart';
import 'package:focubili/features/player/widgets/player_feedback_layout.dart';
import 'package:focubili/features/player/widgets/player_subtitle_caption.dart';
import 'package:focubili/features/player/widgets/player_subtitle_preview.dart';
import 'package:focubili/features/profile/app_text_scale_controller.dart';

const _previewFrame = Key('subtitle-preview-frame');
const _previewCaption = Key('subtitle-appearance-preview');
const _playbackFrame = Key('test-playback-frame');
const _playbackCaption = Key('test-playback-caption');
const _sample =
    '先观察图中的变化，再比较两条曲线经过同一点时的斜率。'
    '\n把这些点连起来，就能看出下一步的变化。';

void main() {
  const cases = [
    (
      name: 'portrait player',
      viewport: SubtitlePreviewViewport(
        size: Size(390, 219.375),
        sideInset: 16,
      ),
      previewWidth: 342.0,
      fontSize: 20.0,
      osScale: 1.0,
      position: 1.0,
    ),
    (
      name: 'landscape player with asymmetric cutout',
      viewport: SubtitlePreviewViewport(
        size: Size(844, 390),
        edgeInsets: EdgeInsets.fromLTRB(47, 0, 12, 21),
        sideInset: 48,
        bottomOverlayHeight: 36,
      ),
      previewWidth: 330.0,
      fontSize: 30.0,
      osScale: 1.3,
      position: 0.0,
    ),
    (
      name: 'desktop player with enlarged multiline subtitle',
      viewport: SubtitlePreviewViewport(size: Size(1120, 630), sideInset: 16),
      previewWidth: 382.0,
      fontSize: 36.0,
      osScale: 1.6,
      position: .5,
    ),
  ];
  for (final scenario in cases) {
    testWidgets('${scenario.name}: preview is a scaled playback frame', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1350, 950);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final controller = AppTextScaleController()..preview(1.3);
      addTearDown(controller.dispose);
      final viewport = scenario.viewport;
      final osScaler = TextScaler.linear(scenario.osScale);
      const opacity = .65;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: osScaler),
              child: AppTextScale(
                controller: controller,
                child: Material(
                  child: Column(
                    children: [
                      SizedBox(
                        key: _playbackFrame,
                        width: viewport.size.width,
                        height: viewport.size.height,
                        child: PlayerFeedbackViewport(
                          controlsVisible: false,
                          edgeInsets: viewport.edgeInsets,
                          sideInset: viewport.sideInset,
                          topControls: const SizedBox.shrink(),
                          bottomControls: const SizedBox.shrink(),
                          bottomOverlay: SizedBox(
                            height: viewport.bottomOverlayHeight,
                          ),
                          feedback: PlayerFeedbackLanes(
                            top: const SizedBox.shrink(),
                            center: const SizedBox.shrink(),
                            bottom: const SizedBox.shrink(),
                            subtitlePosition: scenario.position,
                            subtitle: Center(
                              heightFactor: 1,
                              child: PlayerSubtitleCaption(
                                key: _playbackCaption,
                                text: _sample,
                                fontSize: scenario.fontSize,
                                opacity: opacity,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: scenario.previewWidth,
                        child: PlayerSubtitlePreview(
                          viewport: viewport,
                          text: _sample,
                          fontSize: scenario.fontSize,
                          opacity: opacity,
                          position: scenario.position,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final playerFrame = tester.getRect(find.byKey(_playbackFrame));
      final previewFrame = tester.getRect(find.byKey(_previewFrame));
      final paintScale = previewFrame.width / playerFrame.width;
      expect(paintScale, greaterThan(0));
      expect(paintScale, lessThan(1));
      expect(previewFrame.height, closeTo(playerFrame.height * paintScale, .1));

      final playerCaption = find.byKey(_playbackCaption);
      final previewCaption = find.byKey(_previewCaption);
      expect(
        tester.widget<PlayerSubtitleCaption>(previewCaption).opacity,
        opacity,
      );
      final playerBox = tester
          .getRect(playerCaption)
          .shift(-playerFrame.topLeft);
      final previewBox = tester
          .getRect(previewCaption)
          .shift(-previewFrame.topLeft);
      _expectScaledRect(previewBox, playerBox, paintScale);
      // Independently check quiet playback endpoint and cutout math. Movement
      // is relative to the available caption lane, not the raw sheet height.
      final insets = viewport.edgeInsets;
      final left = insets.left + viewport.sideInset;
      final right = playerFrame.width - insets.right - viewport.sideInset;
      final top = insets.top + 8;
      final bottom =
          playerFrame.height -
          math.max(insets.bottom + 2, viewport.bottomOverlayHeight) -
          8;
      expect(playerBox.center.dx, closeTo((left + right) / 2, .1));
      expect(
        playerBox.top,
        closeTo(
          top + (bottom - top - playerBox.height) * scenario.position,
          .1,
        ),
      );
      expect(playerBox.left, greaterThanOrEqualTo(left - .1));
      expect(playerBox.right, lessThanOrEqualTo(right + .1));
      expect(playerBox.top, greaterThanOrEqualTo(top - .1));
      expect(playerBox.bottom, lessThanOrEqualTo(bottom + .1));

      final playerText = find.descendant(
        of: playerCaption,
        matching: find.text(_sample),
      );
      final previewText = find.descendant(
        of: previewCaption,
        matching: find.text(_sample),
      );
      final playerParagraph = tester.renderObject<RenderParagraph>(playerText);
      final previewParagraph = tester.renderObject<RenderParagraph>(
        previewText,
      );
      expect(
        previewParagraph.textScaler.scale(scenario.fontSize),
        osScaler.scale(scenario.fontSize),
      );
      final playerBaseline = _alphabeticBaseline(playerParagraph);
      final previewBaseline = _alphabeticBaseline(previewParagraph);
      final playerBaselineY =
          playerParagraph.localToGlobal(Offset(0, playerBaseline)).dy -
          playerFrame.top;
      final previewBaselineY =
          previewParagraph.localToGlobal(Offset(0, previewBaseline)).dy -
          previewFrame.top;
      expect(previewBaselineY, closeTo(playerBaselineY * paintScale, .1));

      // Compare visible line selection boxes: this would catch a preview that
      // just changes its font size or wraps at the bottom-sheet width.
      final selection = TextSelection(
        baseOffset: 0,
        extentOffset: _sample.length,
      );
      final playerGlyphBoxes = playerParagraph.getBoxesForSelection(selection);
      final previewGlyphBoxes = previewParagraph.getBoxesForSelection(
        selection,
      );
      expect(
        playerGlyphBoxes.map((box) => box.top).toSet().length,
        greaterThan(1),
      );
      expect(previewGlyphBoxes.length, playerGlyphBoxes.length);
      for (var i = 0; i < playerGlyphBoxes.length; i++) {
        final player = playerGlyphBoxes[i].toRect().shift(
          playerParagraph.localToGlobal(Offset.zero) - playerFrame.topLeft,
        );
        final previewRect = previewGlyphBoxes[i].toRect();
        final preview = Rect.fromPoints(
          previewParagraph.localToGlobal(previewRect.topLeft) -
              previewFrame.topLeft,
          previewParagraph.localToGlobal(previewRect.bottomRight) -
              previewFrame.topLeft,
        );
        _expectScaledRect(preview, player, paintScale);
      }
    });
  }

  testWidgets('video fit changes only the preview picture, not captions', (
    tester,
  ) async {
    const pictureKey = Key('subtitle-preview-picture');
    Rect? subtitleRect;
    for (final scenario in [
      (fit: BoxFit.contain, picture: const Rect.fromLTWH(90, 0, 180, 180)),
      (fit: BoxFit.cover, picture: const Rect.fromLTWH(0, -90, 360, 360)),
      (fit: BoxFit.fill, picture: const Rect.fromLTWH(0, 0, 360, 180)),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Center(
              child: SizedBox(
                width: 360,
                child: PlayerSubtitlePreview(
                  viewport: SubtitlePreviewViewport(
                    size: const Size(800, 400),
                    videoAspectRatio: 1,
                    videoFit: scenario.fit,
                  ),
                  text: _sample,
                  fontSize: 24,
                  opacity: 1,
                  position: 1,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final frame = tester.getRect(find.byKey(_previewFrame));
      final picture = find.byKey(pictureKey);
      final pictureRect = tester.getRect(picture).shift(-frame.topLeft);
      _expectScaledRect(pictureRect, scenario.picture, 1);
      // Cover paints a cropped rectangle; the clip keeps its paint within
      // the video surface, not outside the sheet.
      expect(
        find.ancestor(
          of: picture,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is FittedBox &&
                widget.fit == scenario.fit &&
                widget.clipBehavior == Clip.hardEdge,
          ),
        ),
        findsOneWidget,
      );

      final caption = tester
          .getRect(find.byKey(_previewCaption))
          .shift(-frame.topLeft);
      subtitleRect ??= caption;
      _expectScaledRect(caption, subtitleRect, 1);
      expect(tester.takeException(), isNull);
    }
  });
}

void _expectScaledRect(Rect actual, Rect source, double scale) {
  expect(actual.left, closeTo(source.left * scale, .1));
  expect(actual.top, closeTo(source.top * scale, .1));
  expect(actual.width, closeTo(source.width * scale, .1));
  expect(actual.height, closeTo(source.height * scale, .1));
}

// RenderBox.getDistanceToBaseline is only valid during rendering; match the
// paragraph's actual text configuration without mutating its render tree.
double _alphabeticBaseline(RenderParagraph paragraph) {
  final painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '…' : null,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout(maxWidth: paragraph.size.width);
  final baseline = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  painter.dispose();
  return baseline;
}
