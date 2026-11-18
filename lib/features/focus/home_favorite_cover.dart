import 'package:flutter/material.dart';
import '../common/app_network_image.dart';

/// 首页收藏入口的紧凑封面，复用账号隔离的图片缓存，不单独获取视频信息。
class HomeFavoriteCover extends StatelessWidget {
  const HomeFavoriteCover({super.key, required this.coverUrl});
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
    return ExcludeSemantics(
      child: SizedBox(
        width: 72,
        height: 45,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: coverUrl.trim().isEmpty
              ? placeholder
              : AppNetworkImage(
                  imageUrl: coverUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 256,
                  placeholder: (_, _) => placeholder,
                  errorWidget: (_, _, _) => placeholder,
                ),
        ),
      ),
    );
  }
}
