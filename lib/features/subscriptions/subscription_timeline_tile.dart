import 'package:flutter/material.dart';

import '../../models/subscription.dart';
import '../../services/image_resource_cache.dart';
import '../common/app_network_image.dart';

/// Chronological inbox row. Playback, opening the menu and selecting a row
/// deliberately never mark the video's independent read state.
class SubscriptionTimelineTile extends StatelessWidget {
  const SubscriptionTimelineTile({
    super.key,
    required this.item,
    this.selected,
    this.onTap,
    this.onLongPress,
    this.onRead,
    this.onAdd,
    this.enabled = true,
    this.coverCache,
  });
  final SubscriptionFeedItem item;
  final bool? selected;
  final bool enabled;
  final ImageResourceCache? coverCache;
  final VoidCallback? onTap, onLongPress, onRead, onAdd;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final unread = item.readAt == null;
    final published = item.publishedAt?.toLocal();
    final metadata = [
      if (item.collectionAdded) '合集新增',
      item.sources.values.join(' · '),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Material(
      color: selected == true ? colors.secondaryContainer : colors.surface,
      child: Column(
        children: [
          InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: LayoutBuilder(
              builder: (context, bounds) {
                final coverWidth = (bounds.maxWidth * .27).clamp(60.0, 144.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: selected == null ? 14 : 26,
                        height: coverWidth * 9 / 16,
                        child: Center(
                          child: selected != null
                              ? Icon(
                                  selected!
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  size: 21,
                                  semanticLabel: selected! ? '已选' : '未选',
                                )
                              : Icon(
                                  Icons.circle,
                                  size: 7,
                                  color: unread
                                      ? colors.primary
                                      : Colors.transparent,
                                  semanticLabel: unread ? '未读' : '已读',
                                ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      ExcludeSemantics(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: coverWidth,
                            height: coverWidth * 9 / 16,
                            key: ValueKey('subscription-cover-${item.bvid}'),
                            child: ColoredBox(
                              color: colors.surfaceContainerHighest,
                              child: item.coverUrl.isEmpty
                                  ? const Icon(Icons.video_library_outlined)
                                  : AppNetworkImage(
                                      imageUrl: item.coverUrl,
                                      cache: coverCache,
                                      fit: BoxFit.cover,
                                      memCacheWidth:
                                          (coverWidth *
                                                  MediaQuery.devicePixelRatioOf(
                                                    context,
                                                  ))
                                              .ceil(),
                                      httpHeaders: const {
                                        'Referer': 'https://www.bilibili.com/',
                                      },
                                      errorWidget: (_, _, _) => const Icon(
                                        Icons.video_library_outlined,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: unread
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              metadata,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selected == null)
                        PopupMenuButton<String>(
                          enabled: enabled,
                          tooltip: '${item.title}的更多操作',
                          icon: const Icon(Icons.more_vert, size: 21),
                          onSelected: (action) =>
                              action == 'read' ? onRead?.call() : onAdd?.call(),
                          itemBuilder: (_) => [
                            if (published != null)
                              PopupMenuItem(
                                enabled: false,
                                child: Text(
                                  '发布于 ${published.year}年${published.month}月${published.day}日',
                                ),
                              ),
                            if (unread)
                              const PopupMenuItem(
                                value: 'read',
                                child: Text('标为已读'),
                              ),
                            const PopupMenuItem(
                              value: 'add',
                              child: Text('加入学习清单'),
                            ),
                          ],
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          Divider(height: 1, thickness: .6, color: colors.outlineVariant),
        ],
      ),
    );
  }
}
