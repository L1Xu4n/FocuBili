import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/app_favorite.dart';

/// Shares the same video result layout between a folder and global favorite search.
class AppFavoriteVideoTile extends StatefulWidget {
  /// Receives navigation/removal callbacks without owning storage or player state.
  const AppFavoriteVideoTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onRemove,
    this.folderNames,
    this.loadPartCount,
  });
  final AppFavoriteItem item;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final String? folderNames;
  final Future<int?> Function()? loadPartCount;

  /// Keeps a visible legacy video's metadata lookup stable across list rebuilds.
  @override
  State<AppFavoriteVideoTile> createState() => _AppFavoriteVideoTileState();
}

class _AppFavoriteVideoTileState extends State<AppFavoriteVideoTile> {
  int? _partCount;

  /// Uses saved P counts immediately and fetches only missing metadata.
  @override
  void initState() {
    super.initState();
    _partCount = widget.item.partCount;
    if (_partCount == null) _loadCount();
  }

  /// Updates the count without letting a failed request break a saved favorite.
  Future<void> _loadCount() async {
    try {
      final count = await widget.loadPartCount?.call();
      if (mounted) setState(() => _partCount = count);
    } catch (_) {
      /* Offline legacy items keep an explicit unknown count. */
    }
  }

  /// 使用主题统一的卡片圆角，封面与换行资料保持原有宽度。
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final onTap = widget.onTap;
    final onRemove = widget.onRemove;
    final folderNames = widget.folderNames;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              SizedBox(
                width: 96,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: item.coverUrl.isEmpty
                      ? const Icon(Icons.bookmark_rounded)
                      : CachedNetworkImage(
                          imageUrl: item.coverUrl,
                          httpHeaders: const {
                            'Referer': 'https://www.bilibili.com/',
                          },
                          fit: BoxFit.cover,
                          memCacheWidth: 256,
                          maxWidthDiskCache: 512,
                          errorWidget: (context, url, error) =>
                              const Icon(Icons.broken_image_outlined),
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
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.ownerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (item.durationText.isNotEmpty)
                      Text(
                        item.durationText,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    Text(
                      _partCount == null ? 'P 数未知' : '共 $_partCount P',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (folderNames != null)
                      Text(
                        folderNames,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  key: Key('remove-app-favorite-${item.bvid}'),
                  tooltip: '移除',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: onRemove,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
