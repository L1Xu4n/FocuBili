import 'package:flutter/material.dart';

import '../../../core/theme/app_text_scale.dart';

/// Displays the same caption style on the video and in the appearance preview.
class PlayerSubtitleCaption extends StatelessWidget {
  const PlayerSubtitleCaption({
    super.key,
    required this.text,
    required this.fontSize,
    required this.opacity,
    this.textKey,
  });

  final String text;
  final double fontSize;
  final double opacity;
  final Key? textKey;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          text,
          key: textKey,
          textScaler: AppTextScaleScope.subtitleScalerOf(context),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            height: 1.28,
            shadows: const <Shadow>[Shadow(color: Colors.black, blurRadius: 3)],
          ),
        ),
      ),
    ),
  );
}
