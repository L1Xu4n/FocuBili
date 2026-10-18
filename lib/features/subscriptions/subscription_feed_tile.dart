import 'package:focubili/features/common/app_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/subscription.dart';

/// Shared compact presentation for the feed and the home card. Images never
/// dictate row height; long titles remain available to assistive technology.
class SubscriptionFeedTile extends StatelessWidget {
  const SubscriptionFeedTile({
    super.key,
    required this.item,
    this.onTap,
    this.onLongPress,
    this.selected,
    this.actions,
    this.compact = false,
    this.historical = false,
  });

  final SubscriptionFeedItem item;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool? selected;
  final Widget? actions;
  final bool compact, historical;

  static String date(DateTime? value) => value == null
      ? '未知'
      : '${value.toLocal().month.toString().padLeft(2, '0')}-${value.toLocal().day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth * .32).clamp(
          56.0,
          compact ? 112.0 : 172.0,
        );
        return InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (selected != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          selected!
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                        ),
                      ),
                    ExcludeSemantics(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          key: ValueKey('subscription-cover-${item.bvid}'),
                          width: width,
                          height: width * 9 / 16,
                          child: ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: item.coverUrl.isEmpty
                                ? const Icon(Icons.video_library_outlined)
                                : AppNetworkImage(
                                    imageUrl: item.coverUrl,
                                    httpHeaders: const {
                                      'Referer': 'https://www.bilibili.com/',
                                    },
                                    fit: BoxFit.cover,
                                    memCacheWidth:
                                        (width *
                                                MediaQuery.devicePixelRatioOf(
                                                  context,
                                                ))
                                            .ceil(),
                                    errorWidget: (_, _, _) => const Icon(
                                      Icons.video_library_outlined,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: compact ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.sources.values.join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            historical
                                ? '历史内容 · 发布 ${date(item.publishedAt)}'
                                : '${item.collectionAdded ? '合集新增 · ' : ''}发布 ${date(item.publishedAt)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (actions != null) ...[const SizedBox(height: 4), actions!],
              ],
            ),
          ),
        );
      },
    );
  }
}
