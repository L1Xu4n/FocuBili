import 'package:flutter/material.dart';

import '../../models/account_collection.dart';
import '../../services/image_resource_cache.dart';
import 'app_network_image.dart';

/// Preview up to three already-saved public avatars, without fetching profiles.
List<String> followingGroupAvatarUrls(Iterable<FollowedCreator> members) {
  final urls = <String>{};
  for (final member in members) {
    final raw = member.avatarUrl.trim();
    final uri = Uri.tryParse(raw.startsWith('//') ? 'https:$raw' : raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(uri.host.endsWith('.hdslb.com') ||
            uri.host.endsWith('.biliimg.com'))) {
      continue;
    }
    urls.add(uri.replace(scheme: 'https').toString());
    if (urls.length == 3) break;
  }
  return List.unmodifiable(urls);
}

/// Decorative only: the surrounding row already announces the group name.
class FollowingGroupAvatar extends StatelessWidget {
  const FollowingGroupAvatar({super.key, required this.urls, this.cache});

  final List<String> urls;
  final ImageResourceCache? cache;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entries = urls.take(3).toList(growable: false);
    final size = entries.length == 1 ? 32.0 : 22.0;
    final stackWidth = size + 9.0 * (entries.length - 1);
    Widget placeholder(IconData icon, double iconSize) => ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(icon, size: iconSize, color: colors.onSurfaceVariant),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 40,
        child: entries.isEmpty
            ? ClipOval(child: placeholder(Icons.groups_outlined, 22))
            : Stack(
                children: [
                  for (var index = 0; index < entries.length; index++)
                    PositionedDirectional(
                      start: (40 - stackWidth) / 2 + index * 9,
                      top: (40 - size) / 2,
                      child: Container(
                        width: size,
                        height: size,
                        padding: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.surface,
                        ),
                        child: ClipOval(
                          child: AppNetworkImage(
                            imageUrl: entries[index],
                            cache: cache,
                            fit: BoxFit.cover,
                            memCacheWidth: 96,
                            excludeFromSemantics: true,
                            placeholder: (_, _) =>
                                placeholder(Icons.person_outline, 14),
                            errorWidget: (_, _, _) =>
                                placeholder(Icons.person_outline, 14),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
