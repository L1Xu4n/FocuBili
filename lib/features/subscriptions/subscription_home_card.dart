import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/subscription.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../../services/subscription_service.dart';
import '../player/player_page.dart';
import 'subscription_feed_tile.dart';
import 'subscription_updates_page.dart';

/// Reads the same feed as the subscription page. Lifecycle polling remains
/// owned by the app; mounting or rebuilding a home card never starts a poll.
class SubscriptionHomeCard extends StatefulWidget {
  const SubscriptionHomeCard({
    super.key,
    this.service,
    this.videoService,
    this.playerBuilder,
  });
  final SubscriptionService? service;
  final BilibiliService? videoService;
  final Widget Function(VideoPreview video)? playerBuilder;

  @override
  State<SubscriptionHomeCard> createState() => _SubscriptionHomeCardState();
}

class _SubscriptionHomeCardState extends State<SubscriptionHomeCard> {
  late final _service = widget.service ?? SubscriptionService.instance;
  late final _videos = widget.videoService ?? BilibiliVideoInfoService();
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  void _openFeed() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          SubscriptionUpdatesPage(service: _service, videoService: _videos),
    ),
  );

  Future<void> _open(SubscriptionFeedItem item) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final video = await _videos.lookupVideo(item.bvid);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              widget.playerBuilder?.call(video) ??
              PlayerPage(video: video, bilibiliService: _videos),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法打开视频，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final items = _service.feed.take(3).toList();
      return Card(
        key: const Key('home-subscription-card'),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.rss_feed_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '焦点订阅',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新焦点订阅',
                    onPressed: !_service.enabled || _service.refreshing
                        ? null
                        : () => unawaited(_service.refresh(manual: true)),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '查看全部订阅更新',
                    onPressed: _openFeed,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '最近收到 · ${_service.unreadCount} 条未读',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_service.refreshing || _opening)
              const LinearProgressIndicator(),
            if (_service.storageError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_service.storageError!),
              ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _service.enabled
                          ? '还没有收到更新。新内容会自动出现在这里。'
                          : '选择感兴趣的 UP 主或合集，在首页接收更新。',
                    ),
                    TextButton(
                      onPressed: _openFeed,
                      child: Text(_service.enabled ? '查看订阅' : '设置焦点订阅'),
                    ),
                  ],
                ),
              ),
            for (final item in items)
              SubscriptionFeedTile(
                item: item,
                compact: true,
                onTap: _opening ? null : () => unawaited(_open(item)),
              ),
            const SizedBox(height: 4),
          ],
        ),
      );
    },
  );
}
