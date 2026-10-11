import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/subscription.dart';
import '../../models/subscription_history.dart';
import '../../models/video_preview.dart';
import '../../services/subscription_service.dart';
import '../../services/bilibili_service.dart';
import '../player/player_page.dart';
import 'subscription_feed_tile.dart';

class SubscriptionHistoryPage extends StatefulWidget {
  const SubscriptionHistoryPage({
    super.key,
    required this.service,
    required this.source,
    this.videoService,
    this.playerBuilder,
  });
  final SubscriptionService service;
  final SubscriptionSource source;
  final BilibiliService? videoService;
  final Widget Function(VideoPreview video)? playerBuilder;
  @override
  State<SubscriptionHistoryPage> createState() =>
      _SubscriptionHistoryPageState();
}

class _SubscriptionHistoryPageState extends State<SubscriptionHistoryPage> {
  Future<List<SubscriptionFeedItem>>? _items;
  (String?, int, int)? _loaded;
  int _visible = 100;
  bool _opening = false;
  Timer? _retryTimer;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_changed);
    _changed();
  }

  void _changed() {
    final job = widget.service.historyJob(widget.source.key);
    _retryTimer?.cancel();
    final now = DateTime.now();
    final deadlines = [
      if (!widget.service.historyRunning(widget.source.key) &&
          job?.status == HistoryImportStatus.running &&
          job?.runUntil != null)
        job!.runUntil!,
      if (job?.retryAt != null) job!.retryAt!,
    ].where((date) => date.isAfter(now)).toList()..sort();
    if (deadlines.isNotEmpty) {
      _retryTimer = Timer(
        deadlines.first.difference(now) + const Duration(milliseconds: 100),
        _changed,
      );
    }
    final key = (job?.id, job?.ids.length ?? 0, _visible);
    if (_loaded != key) {
      _loaded = key;
      _items = widget.service.historyItems(widget.source.key, count: _visible);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('操作未完成，已保存的内容保留，请稍后重试。')));
      }
    }
  }

  Future<void> _open(SubscriptionFeedItem item) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final videos = widget.videoService ?? BilibiliVideoInfoService();
      final video = await videos.lookupVideo(item.bvid);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              widget.playerBuilder?.call(video) ??
              PlayerPage(video: video, bilibiliService: videos),
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
  Widget build(BuildContext context) {
    final service = widget.service;
    final job = service.historyJob(widget.source.key);
    final running =
        service.historyRunning(widget.source.key) &&
        job?.status == HistoryImportStatus.running;
    final now = DateTime.now();
    final awaitingOwner =
        !running &&
        job?.status == HistoryImportStatus.running &&
        job?.runUntil?.isAfter(now) == true;
    final backingOff = job?.retryAt?.isAfter(now) == true;
    final canStart =
        service.enabled &&
        !widget.source.paused &&
        !awaitingOwner &&
        !backingOff;
    final state = switch (job?.status) {
      HistoryImportStatus.complete => '已到达接口返回的末页',
      HistoryImportStatus.limited => '已导入所选数量',
      HistoryImportStatus.blocked => '获取已停止 · 范围尚未完整确认',
      HistoryImportStatus.failed => '导入中断 · 已保存内容保留',
      _ =>
        awaitingOwner
            ? '正在等待上次任务释放，请稍后继续'
            : running
            ? '正在导入'
            : job == null
            ? '尚未导入历史'
            : '已暂停 · 可以继续',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('订阅历史')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.source.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text('历史单独保存，不增加新更新未读或系统通知。返回页面后仍可在前台导入；离开应用会暂停。'),
                      const SizedBox(height: 12),
                      Text(state),
                      if (job != null)
                        Text(
                          '已保存 ${job.ids.length} 条 · 下一页 ${job.nextPage}${job.total == null ? '' : ' · 接口当前总数 ${job.total}'}',
                        ),
                      if (job?.listChanged == true)
                        const Text('获取期间列表发生变化；已保存内容可查看，历史覆盖可能不完整。'),
                      if (job?.error != null) Text(job!.error!),
                      if (job?.retryAt != null)
                        Text('可重试时间：${job!.retryAt!.toLocal()}'),
                      if (awaitingOwner)
                        Text('最迟可继续时间：${job!.runUntil!.toLocal()}'),
                      if (running)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: LinearProgressIndicator(),
                        ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (job == null)
                            FilledButton.tonal(
                              onPressed: canStart
                                  ? () => unawaited(
                                      _action(
                                        () => service.startHistory(
                                          widget.source.key,
                                        ),
                                      ),
                                    )
                                  : null,
                              child: const Text('导入最近 100 条'),
                            ),
                          if (!running &&
                              job?.status != HistoryImportStatus.complete &&
                              job?.status != HistoryImportStatus.limited &&
                              job != null)
                            FilledButton.tonal(
                              onPressed: canStart
                                  ? () => unawaited(
                                      _action(
                                        () => service.resumeHistory(
                                          widget.source.key,
                                        ),
                                      ),
                                    )
                                  : null,
                              child: const Text('继续导入'),
                            ),
                          if (!running &&
                              (job == null ||
                                  job.status == HistoryImportStatus.limited))
                            TextButton(
                              onPressed: canStart
                                  ? () => unawaited(
                                      _action(
                                        () => service.startHistory(
                                          widget.source.key,
                                          limit: null,
                                        ),
                                      ),
                                    )
                                  : null,
                              child: const Text('导入全部可获取内容'),
                            ),
                          if (running)
                            OutlinedButton(
                              onPressed: () => unawaited(
                                _action(
                                  () => service.pauseHistory(widget.source.key),
                                ),
                              ),
                              child: const Text('暂停导入'),
                            ),
                        ],
                      ),
                      if (job == null)
                        const Text('全部导入可能需要较多请求；接口受限时会保留已保存内容并停止。'),
                    ],
                  ),
                ),
              ),
              FutureBuilder<List<SubscriptionFeedItem>>(
                future: _items,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('历史缓存暂时无法读取，原文件已保留。'),
                      ),
                    );
                  }
                  final items = snapshot.data ?? [];
                  return SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) => Card(
                      child: SubscriptionFeedTile(
                        item: items[index],
                        historical: true,
                        onTap: () => unawaited(_open(items[index])),
                      ),
                    ),
                  );
                },
              ),
              if ((job?.ids.length ?? 0) > _visible)
                SliverToBoxAdapter(
                  child: TextButton(
                    onPressed: () {
                      _visible += 100;
                      _changed();
                    },
                    child: const Text('显示更多历史'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
