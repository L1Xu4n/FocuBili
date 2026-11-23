import 'package:flutter/material.dart';
import '../common/app_network_image.dart';
import '../common/favorite_folder_privacy_badge.dart';
import '../../services/image_resource_cache.dart';
import '../../services/bilibili_image_url_policy.dart';

/// 首页收藏入口的紧凑封面，复用账号隔离的图片缓存，不单独获取视频信息。
class HomeFavoriteCover extends StatelessWidget {
  const HomeFavoriteCover({
    super.key,
    required this.coverUrl,
    this.remote = false,
    this.isPrivate,
    this.cache,
  });
  final bool remote;
  final bool? isPrivate;
  final ImageResourceCache? cache;
  final String coverUrl;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.folder_outlined, color: colors.onSurfaceVariant),
      ),
    );
    final locked = remote && isPrivate == true;
    return SizedBox(
      width: 72,
      height: 45,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              child: coverUrl.trim().isEmpty
                  ? placeholder
                  : AppNetworkImage(
                      imageUrl: coverUrl,
                      imageVariant: BilibiliImageVariant.cover16x9,
                      cache: cache,
                      fit: BoxFit.cover,
                      memCacheWidth: 256,
                      placeholder: (_, _) => placeholder,
                      errorWidget: (_, _, _) => placeholder,
                    ),
            ),
            Positioned(
              right: locked ? 26 : 4,
              bottom: locked ? 6 : 4,
              child: Icon(
                remote ? Icons.cloud_outlined : Icons.bookmark_outline,
                size: 14,
                color: Colors.white,
                // Keep the glyph visible against bright covers without a badge plate.
                shadows: const [Shadow(color: Colors.black87, blurRadius: 3)],
              ),
            ),
            if (locked)
              const Positioned(
                right: 4,
                bottom: 4,
                child: FavoriteFolderPrivacyBadge(),
              ),
          ],
        ),
      ),
    );
  }
}
