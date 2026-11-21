import 'package:flutter/material.dart';

import 'player_feedback_layout.dart';
import 'player_subtitle_caption.dart';

/// The actual player surface, not the window or the source video's resolution.
@immutable
class SubtitlePreviewViewport {
  const SubtitlePreviewViewport({
    required this.size,
    this.edgeInsets = EdgeInsets.zero,
    this.sideInset = 16,
    this.bottomOverlayHeight = 0,
    this.videoAspectRatio = 16 / 9,
    this.videoFit = BoxFit.contain,
  });

  final Size size;
  final EdgeInsets edgeInsets;
  final double sideInset;
  final double bottomOverlayHeight;
  final double videoAspectRatio;
  final BoxFit videoFit;

  @override
  bool operator ==(Object other) =>
      other is SubtitlePreviewViewport &&
      size == other.size &&
      edgeInsets == other.edgeInsets &&
      sideInset == other.sideInset &&
      bottomOverlayHeight == other.bottomOverlayHeight &&
      videoAspectRatio == other.videoAspectRatio &&
      videoFit == other.videoFit;

  @override
  int get hashCode => Object.hash(
    size,
    edgeInsets,
    sideInset,
    bottomOverlayHeight,
    videoAspectRatio,
    videoFit,
  );
}

/// Lay out in playback coordinates first. The single outer transform preserves
/// the caption baseline, safe area, padding and line breaks together.
class PlayerSubtitlePreview extends StatelessWidget {
  const PlayerSubtitlePreview({
    super.key,
    required this.viewport,
    required this.text,
    required this.fontSize,
    required this.opacity,
    required this.position,
  });

  final SubtitlePreviewViewport viewport;
  final String text;
  final double fontSize;
  final double opacity;
  final double position;

  @override
  Widget build(BuildContext context) => Center(
    heightFactor: 1,
    child: AspectRatio(
      aspectRatio: viewport.size.aspectRatio,
      child: ClipRRect(
        key: const Key('subtitle-preview-frame'),
        borderRadius: BorderRadius.circular(10),
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: viewport.size,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: viewport.videoFit,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: 180 * viewport.videoAspectRatio,
                      height: 180,
                      child: const CustomPaint(
                        key: Key('subtitle-preview-picture'),
                        painter: _LessonStill(),
                      ),
                    ),
                  ),
                  PlayerFeedbackViewport(
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
                      subtitlePosition: position,
                      subtitle: Center(
                        heightFactor: 1,
                        child: PlayerSubtitleCaption(
                          key: const Key('subtitle-appearance-preview'),
                          text: text,
                          fontSize: fontSize,
                          opacity: opacity,
                        ),
                      ),
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
}

/// An offline sample frame: a tangent meeting a curve on a graph-paper board.
/// Varying luminance makes opacity visible without fetching the video's cover.
class _LessonStill extends CustomPainter {
  const _LessonStill();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF34585B), Color(0xFF19363B)],
        ).createShader(bounds),
    );
    // Draw at a constant reference scale with no dependence on the sheet.
    canvas.save();
    canvas.clipRect(bounds);
    canvas.translate(w * .5, h * .51);
    final scale = size.shortestSide / 180;
    canvas.scale(scale);
    final hw = w / (2 * scale), hh = h / scale;
    final ink = Paint()
      ..strokeWidth = .6
      ..color = const Color(0x22D9E6CD);
    for (double x = 0; x <= hw; x += 20) {
      canvas.drawLine(Offset(x, -hh), Offset(x, hh), ink);
      if (x != 0) canvas.drawLine(Offset(-x, -hh), Offset(-x, hh), ink);
    }
    for (double y = -100; y <= 100; y += 20) {
      canvas.drawLine(Offset(-hw, y), Offset(hw, y), ink);
    }
    ink.color = const Color(0x668FAFA7);
    canvas.drawLine(Offset(-hw, 20), Offset(hw, 20), ink);
    canvas.drawLine(Offset(-60, -hh), Offset(-60, hh), ink);
    ink
      ..color = const Color(0xFFACDCCF)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(-132, -78)
        ..quadraticBezierTo(-35, 126, 126, -84),
      ink,
    );
    // Tangent at t=.5 of the quadratic above.
    ink
      ..color = const Color(0xFFE1BB80)
      ..strokeWidth = 1.1;
    canvas.drawLine(
      const Offset(-107.5, 24.75),
      const Offset(69.5, 20.63),
      ink,
    );
    ink.style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(-19, 22.5), 3, ink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LessonStill oldDelegate) => false;
}
