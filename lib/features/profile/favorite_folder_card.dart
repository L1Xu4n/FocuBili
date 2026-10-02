import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 为账号收藏与本机收藏提供同一套自适应封面、名称和数量布局。
class FavoriteFolderCard extends StatelessWidget {
  /// 接收收藏夹资料及可选管理操作，保持本机与账号收藏的操作边界。
  const FavoriteFolderCard({
    super.key,
    required this.title,
    required this.count,
    this.coverUrl = '',
    this.available = true,
    this.onTap,
    this.actions,
  });
  final String title;
  final int count;
  final String coverUrl;
  final bool available;
  final VoidCallback? onTap;
  final Widget? actions;

  /// 图片缺失时使用跟随明暗主题的占位图标，避免深色背景上的低对比图标。
  Widget _placeholder(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: Icon(
        Icons.folder_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  /// 窄屏缩小封面，放大字体时增加标题行数，数量只显示一次以减少干扰。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = ((constraints.maxWidth - 24) * .30).clamp(72.0, 112.0);
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: available ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                SizedBox(
                  width: width,
                  height: width * 5 / 8,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        coverUrl.isEmpty
                            ? _placeholder(context)
                            : CachedNetworkImage(
                                imageUrl: coverUrl,
                                httpHeaders: const {
                                  'Referer': 'https://www.bilibili.com/',
                                },
                                fit: BoxFit.cover,
                                memCacheWidth: 256,
                                maxWidthDiskCache: 512,
                                fadeInDuration: const Duration(
                                  milliseconds: 120,
                                ),
                                placeholder: (context, _) =>
                                    _placeholder(context),
                                errorWidget: (context, _, error) =>
                                    _placeholder(context),
                              ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: title,
                        child: Text(
                          title,
                          maxLines: largeText ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        available ? '$count 个视频' : '收藏夹已失效',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: available
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
                actions ??
                    Icon(
                      available
                          ? Icons.chevron_right_rounded
                          : Icons.block_rounded,
                    ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
