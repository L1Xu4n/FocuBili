import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/content_blocklist.dart';
import '../../models/public_profile.dart';
import '../../models/subscription.dart';
import '../../services/content_blocklist_service.dart';
import '../profile/content_blocklist_page.dart';

/// Locally filters already loaded discovery items; never changes their source
/// list, saved state, pagination cursor, or network requests.
mixin DiscoveryBlocklistState<T extends StatefulWidget> on State<T> {
  ContentBlocklist discoveryBlocklist = const ContentBlocklist();

  /// A previous successful snapshot remains usable for display, not actions,
  /// while a replacement is loading or failed.
  bool discoveryBlocklistReady = false;
  bool _readingDiscoveryRules = true;
  bool _failedDiscoveryRules = false;
  bool get discoveryBlocklistActionsReady =>
      discoveryBlocklistReady &&
      !_readingDiscoveryRules &&
      !_failedDiscoveryRules;

  int discoveryBlocklistGeneration = 0;
  int _readGeneration = 0;

  @override
  void initState() {
    super.initState();
    ContentBlocklistService.changes.addListener(_readDiscoveryBlocklist);
    unawaited(_readDiscoveryBlocklist());
  }

  @override
  void dispose() {
    ContentBlocklistService.changes.removeListener(_readDiscoveryBlocklist);
    super.dispose();
  }

  Future<void> _readDiscoveryBlocklist() async {
    final generation = ++_readGeneration;
    if (mounted && (!_readingDiscoveryRules || _failedDiscoveryRules)) {
      setState(() {
        _readingDiscoveryRules = true;
        _failedDiscoveryRules = false;
      });
    }
    try {
      final list = await const ContentBlocklistService().load();
      if (!mounted || generation != _readGeneration) return;
      setState(() {
        discoveryBlocklist = list;
        discoveryBlocklistReady = true;
        _readingDiscoveryRules = false;
        _failedDiscoveryRules = false;
        discoveryBlocklistGeneration++;
        onDiscoveryBlocklistChanged();
      });
    } catch (_) {
      // An unavailable rule store is not an empty rule store. Keep a previous
      // valid snapshot for display, but don't make visibility-dependent writes.
      if (mounted && generation == _readGeneration) {
        setState(() {
          _readingDiscoveryRules = false;
          _failedDiscoveryRules = true;
        });
      }
    }
  }

  Widget buildDiscoveryBlocklistStatus() {
    if (!_failedDiscoveryRules) return const LinearProgressIndicator();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            discoveryBlocklistReady
                ? '黑名单读取失败，使用上次规则显示，相关操作已暂停。'
                : '黑名单读取失败，内容暂未显示。',
          ),
          TextButton(
            onPressed: () => unawaited(_readDiscoveryBlocklist()),
            child: const Text('重试读取黑名单'),
          ),
        ],
      ),
    );
  }

  /// Allows selection-capable hosts to prune hidden IDs in the same frame.
  void onDiscoveryBlocklistChanged() {}
}

bool blocksCreatorPost(
  ContentBlocklist list,
  CreatorVideo video, {
  required int profileMid,
  required String profileName,
}) {
  final ownerName = video.ownerName.trim();
  final knownProfileName =
      const {'未知 UP 主', '未知用户', 'UP 主'}.contains(profileName.trim())
      ? ''
      : profileName.trim();
  final sameProfile = video.ownerMid > 0
      ? video.ownerMid == profileMid
      : ownerName.isEmpty ||
            (knownProfileName.isNotEmpty &&
                ContentBlockRule.normalizeText(ownerName) ==
                    ContentBlockRule.normalizeText(knownProfileName));
  return list.blocks(
    bvid: video.bvid,
    title: video.title,
    ownerMid: video.ownerMid > 0
        ? video.ownerMid
        : (sameProfile ? profileMid : 0),
    ownerName: ownerName.isNotEmpty
        ? ownerName
        : (sameProfile ? knownProfileName : ''),
    tags: video.tags,
  );
}

bool blocksSubscriptionUpdate(
  ContentBlocklist list,
  SubscriptionFeedItem item,
) {
  // Old and new feed rows have only source keys and labels, not video author
  // names or tags. A collection organizer is not the video's author. If a
  // row has conflicting creator sources, leave the UID unverified.
  var creatorUid = 0;
  for (final key in item.sources.keys) {
    if (!key.startsWith('creator:')) continue;
    final uid = int.tryParse(key.substring('creator:'.length));
    if (uid == null || uid <= 0) continue;
    if (creatorUid != 0 && creatorUid != uid) {
      creatorUid = 0;
      break;
    }
    creatorUid = uid;
  }
  return list.blocks(bvid: item.bvid, title: item.title, ownerMid: creatorUid);
}

class DiscoveryBlocklistNotice extends StatelessWidget {
  const DiscoveryBlocklistNotice({
    super.key,
    required this.hiddenCount,
    this.onLoadNextPage,
  });

  final int hiddenCount;
  final VoidCallback? onLoadNextPage;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '黑名单已隐藏 $hiddenCount 条',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (onLoadNextPage != null)
          TextButton(onPressed: onLoadNextPage, child: const Text('继续加载下一页')),
        TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const ContentBlocklistPage()),
          ),
          child: const Text('管理黑名单'),
        ),
      ],
    ),
  );
}
