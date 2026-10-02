import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 按实际字体与系统文字比例测量单行笔记文字，供卡片和跑马灯共享尺寸。
Size measurePlayerNoteText(BuildContext context, String text, TextStyle style) {
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final Size size = painter.size;
  painter.dispose();
  return size;
}

/// 根据笔记标题、时间点和分 P 标签测得横向卡片的有限宽高。
Size measurePlayerNoteStripTile(
  BuildContext context, {
  required String title,
  required String positionLabel,
  required String partLabel,
}) {
  final TextTheme textTheme = Theme.of(context).textTheme;
  final Size titleSize = measurePlayerNoteText(
    context,
    title,
    PlayerNoteTile.stripTitleStyle,
  );
  final Size positionSize = measurePlayerNoteText(
    context,
    positionLabel,
    (textTheme.bodySmall ?? const TextStyle()).copyWith(
      fontSize: 11,
      height: 1.25,
    ),
  );
  final Size partSize = measurePlayerNoteText(
    context,
    partLabel,
    (textTheme.labelMedium ?? const TextStyle()).copyWith(
      fontSize: 11,
      height: 1.25,
      fontWeight: FontWeight.w800,
    ),
  );
  return Size(
    math.max(108, positionSize.width + partSize.width + 6 + 16).ceilToDouble(),
    math
        .max(
          44,
          titleSize.height +
              2 +
              math.max(positionSize.height, partSize.height) +
              12,
        )
        .ceilToDouble(),
  );
}

/// 展示可选择的笔记卡片；横向卡片按测量尺寸展示，竖向卡片自然增高。
class PlayerNoteTile extends StatelessWidget {
  /// 创建只负责展示和选择的笔记卡片，不持有笔记或播放业务状态。
  const PlayerNoteTile({
    super.key,
    required this.title,
    required this.positionLabel,
    required this.partLabel,
    required this.selected,
    required this.onTap,
    required this.tapKey,
    this.partKey,
    this.horizontal = false,
    this.scrollingTitle,
  });

  static const TextStyle stripTitleStyle = TextStyle(
    fontSize: 12,
    height: 1.25,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle listTitleStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
  );

  final String title;
  final String positionLabel;
  final String partLabel;
  final bool selected;
  final VoidCallback onTap;
  final Key tapKey;
  final Key? partKey;
  final bool horizontal;
  final Widget? scrollingTitle;

  /// 保留完整标题提示和可点选区域，时间与分 P 在窄列表中自动分行。
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Widget titleWidget = Tooltip(
      message: title,
      child:
          scrollingTitle ??
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: horizontal ? stripTitleStyle : listTitleStyle,
          ),
    );
    final Widget metadata = horizontal
        ? Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  positionLabel,
                  maxLines: 1,
                  style: textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                partLabel,
                key: partKey,
                style: textTheme.labelMedium?.copyWith(
                  fontSize: 11,
                  height: 1.25,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? colors.primary.withValues(alpha: 0.22)
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Wrap(
                spacing: 5,
                runSpacing: 2,
                children: <Widget>[
                  Text(
                    partLabel,
                    key: partKey,
                    style: textTheme.labelMedium?.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    positionLabel,
                    style: textTheme.labelMedium?.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          );
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        titleWidget,
        SizedBox(height: horizontal ? 2 : 3),
        metadata,
      ],
    );
    return Material(
      color: selected
          ? (horizontal
                ? colors.primaryContainer
                : colors.primary.withValues(alpha: 0.18))
          : (horizontal ? colors.surfaceContainerLow : Colors.transparent),
      borderRadius: BorderRadius.circular(horizontal ? 12 : 9),
      child: InkWell(
        key: tapKey,
        borderRadius: BorderRadius.circular(horizontal ? 12 : 9),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontal ? 8 : 9,
            vertical: horizontal ? 6 : 7,
          ),
          child: horizontal
              ? content
              : Row(
                  children: <Widget>[
                    Container(
                      width: 3,
                      height: 32,
                      decoration: BoxDecoration(
                        color: selected
                            ? colors.primary
                            : colors.outlineVariant,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: content),
                  ],
                ),
        ),
      ),
    );
  }
}
