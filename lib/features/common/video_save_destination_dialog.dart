import 'dart:math' as math;
import 'package:flutter/material.dart';

enum VideoSaveDestination { learning, favorites }

/// 两种不同目的地平级。选择只打开下一步；关闭这里不会写入任何数据。
Future<VideoSaveDestination?> chooseVideoSaveDestination(
  BuildContext context, {
  required int count,
}) => showDialog<VideoSaveDestination>(
  context: context,
  builder: (context) => _DestinationDialog(count: count),
);

class _DestinationDialog extends StatelessWidget {
  const _DestinationDialog({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      constraints: const BoxConstraints(maxWidth: 400),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    namesRoute: true,
                    child: Text('添加到', style: theme.textTheme.titleLarge),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Text(
              '已选 $count 支视频',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, size) {
                // 先保住方形触达与系统字号；极窄/大字时上下排列并可滚动。
                final textWidth =
                    MediaQuery.textScalerOf(context).scale(16) * 4 + 22;
                final side = (size.maxWidth - 12) / 2;
                final stack = side < textWidth;
                final edge = stack
                    ? math.min(size.maxWidth, math.max(124.0, textWidth + 8))
                    : side;
                Widget tile(
                  VideoSaveDestination target,
                  String label,
                  IconData icon,
                  Color fill,
                  Color ink,
                ) => SizedBox.square(
                  dimension: edge,
                  child: OutlinedButton(
                    key: ValueKey('save-destination-${target.name}'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(6),
                      foregroundColor: ink,
                      backgroundColor: fill,
                      side: BorderSide(color: colors.outlineVariant),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: () {
                      if (ModalRoute.of(context)?.isCurrent == true) {
                        Navigator.pop(context, target);
                      }
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 32),
                        const SizedBox(height: 10),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
                final a = tile(
                  VideoSaveDestination.learning,
                  '学习清单',
                  Icons.playlist_add_check_rounded,
                  colors.primaryContainer,
                  colors.onPrimaryContainer,
                );
                final b = tile(
                  VideoSaveDestination.favorites,
                  '收藏夹',
                  Icons.folder_outlined,
                  colors.secondaryContainer,
                  colors.onSecondaryContainer,
                );
                return stack
                    ? Column(children: [a, const SizedBox(height: 12), b])
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [a, const SizedBox(width: 12), b],
                      );
              },
            ),
          ],
        ),
      ),
    );
  }
}
