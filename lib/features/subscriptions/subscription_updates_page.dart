import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/subscription.dart';
import '../../models/public_profile.dart';
import '../../services/subscription_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/focus_notification_service.dart';
import '../../services/learning_list_service.dart';
import '../learning/learning_add_sheet.dart';
import '../player/player_page.dart';

class SubscriptionUpdatesPage extends StatefulWidget {
  const SubscriptionUpdatesPage({
    super.key,
    this.service,
    this.videoService,
    this.learningService,
    this.notificationService = const FocusNotificationService(),
  });
  final SubscriptionService? service;
  final BilibiliService? videoService;
  final LearningListService? learningService;
  final FocusNotificationService notificationService;
  @override
  State<SubscriptionUpdatesPage> createState() =>
      _SubscriptionUpdatesPageState();
}

class _SubscriptionUpdatesPageState extends State<SubscriptionUpdatesPage> {
  late final SubscriptionService _service =
      widget.service ?? SubscriptionService.instance;
  late final BilibiliService _videos =
      widget.videoService ?? BilibiliVideoInfoService();
  late final LearningListService _learning =
      widget.learningService ?? LearningListService();
  bool _unreadOnly = true, _todayOnly = false, _busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      _message('操作未保存，请检查设备存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _notifications(bool value) async {
    await _action(() async {
      if (value) {
        final allowed = await widget.notificationService.requestPermission();
        if (!mounted) return;
        if (!allowed) {
          _message('通知未获授权，更新列表仍可使用。');
          return;
        }
      }
      await _service.setNotificationsEnabled(value);
    });
  }

  Future<void> _addSource() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _AddSourceDialog(service: _service),
    );
  }

  Future<void> _delete(SubscriptionSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('删除“${source.name}”？已有更新历史和学习任务保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _action(() => _service.deleteSource(source.key));
    }
  }

  Future<void> _play(SubscriptionFeedItem item) => _action(() async {
    final video = await _videos.lookupVideo(item.bvid);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PlayerPage(video: video, bilibiliService: _videos),
      ),
    );
  });
  Future<void> _addLearning(SubscriptionFeedItem item) => _action(() async {
    final video = await _videos.lookupVideo(item.bvid);
    if (!mounted) return;
    final result = await LearningAddSheet.show(
      context,
      video: video,
      service: _learning,
    );
    if (result != null) _message('已加入所选分 P；更新已读状态未改变。');
  });
  String _date(DateTime? date) => date == null
      ? '未知'
      : '${date.toLocal().year}-${date.toLocal().month.toString().padLeft(2, '0')}-${date.toLocal().day.toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final today = _date(DateTime.now());
      final items = _service.feed
          .where(
            (e) =>
                (!_unreadOnly || e.readAt == null) &&
                (!_todayOnly || _date(e.publishedAt) == today),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('订阅更新'),
          actions: [
            IconButton(
              tooltip: '手动刷新',
              onPressed: !_service.enabled || _service.refreshing
                  ? null
                  : () => unawaited(_service.refresh(manual: true)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  title: const Text('开启订阅更新'),
                  value: _service.enabled,
                  subtitle: const Text('仅在启动、回到前台、手动或前台每小时尝试刷新。退出后不推送。'),
                  onChanged: _busy
                      ? null
                      : (value) => _action(() => _service.setEnabled(value)),
                ),
                if (_service.storageError != null)
                  Text(
                    _service.storageError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_service.enabled) ...[
                  SwitchListTile(
                    title: const Text('系统通知（默认关闭）'),
                    value: _service.notificationsEnabled,
                    subtitle: const Text('明确开启时才请求权限；专注期间只更新角标。'),
                    onChanged: _busy ? null : _notifications,
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _addSource,
                    icon: const Icon(Icons.add),
                    label: const Text('添加 UP 主或 UGC 合集'),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  '订阅源（${_service.sources.length}/${_service.maxSources}）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_service.sources.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('主动选择你的学习来源。首次订阅只建立基线，不显示历史视频。'),
                  ),
                for (final source in _service.sources)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            source.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            source.kind == SubscriptionKind.creator
                                ? 'UP主 ${source.mid}'
                                : 'UGC合集 ${source.seasonId} · UP主 ${source.mid}',
                          ),
                          Text(
                            source.paused
                                ? '已暂停 · 历史保留'
                                : _service
                                          .checkpoint(source.key)
                                          ?.initialized ==
                                      true
                                ? '基线已建立'
                                : '正在建立基线 · 历史不会刷屏',
                          ),
                          if (_service.checkpoint(source.key)?.error != null)
                            Text(_service.checkpoint(source.key)!.error!),
                          if (_service.checkpoint(source.key)?.partial == true)
                            Text(
                              '未完成扫描 · 下一页 ${_service.checkpoint(source.key)!.nextPage}',
                            ),
                          Wrap(
                            spacing: 12,
                            children: [
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _action(
                                        () => _service.pauseSource(
                                          source.key,
                                          !source.paused,
                                        ),
                                      ),
                                child: Text(source.paused ? '恢复订阅' : '暂停'),
                              ),
                              TextButton(
                                onPressed: _busy ? null : () => _delete(source),
                                child: const Text('删除源'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_service.refreshing) const LinearProgressIndicator(),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  children: [
                    FilterChip(
                      label: const Text('仅未读'),
                      selected: _unreadOnly,
                      onSelected: (value) =>
                          setState(() => _unreadOnly = value),
                    ),
                    FilterChip(
                      label: const Text('今日发布'),
                      selected: _todayOnly,
                      onSelected: (value) => setState(() => _todayOnly = value),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _action(_service.markAllRead),
                      child: const Text('全部标为已读'),
                    ),
                  ],
                ),
                Text('未读 ${_service.unreadCount} · 仅本机保存，播放、已读与学习进度独立。'),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Text('暂无匹配的更新。订阅后首次成功扫描只建立基线。'),
                  ),
                for (final item in items)
                  Card(
                    key: Key('subscription-feed-${item.bvid}'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.coverUrl.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                item.coverUrl,
                                height: 120,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(
                                  height: 40,
                                  child: Icon(Icons.video_library),
                                ),
                              ),
                            ),
                          Text(
                            item.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Wrap(
                            spacing: 6,
                            children: [
                              for (final name in item.sources.values)
                                Chip(label: Text(name)),
                            ],
                          ),
                          Text(
                            '${item.collectionAdded ? '合集新增 · ' : ''}发布 ${_date(item.publishedAt)} · 发现 ${_date(item.discoveredAt)}',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: _busy ? null : () => _play(item),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('播放'),
                              ),
                              TextButton(
                                onPressed: _busy || item.readAt != null
                                    ? null
                                    : () => _action(
                                        () => _service.markRead(item.bvid),
                                      ),
                                child: Text(
                                  item.readAt == null ? '标为已读' : '已读',
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _addLearning(item),
                                icon: const Icon(Icons.playlist_add),
                                label: const Text('加入学习清单'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({required this.service});
  final SubscriptionService service;
  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _input = TextEditingController(), _mid = TextEditingController();
  SubscriptionKind _kind = SubscriptionKind.creator;
  bool _busy = false;
  String? _error;
  SubscriptionSource? _preview;
  @override
  void dispose() {
    _input.dispose();
    _mid.dispose();
    super.dispose();
  }

  int? _number(String value) => int.tryParse(value.trim());
  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final raw = _input.text.trim();
      final uri = Uri.tryParse(raw);
      int? mid, season;
      if (_kind == SubscriptionKind.creator) {
        mid = _number(raw);
        if (mid == null &&
            uri?.host == 'space.bilibili.com' &&
            uri!.pathSegments.isNotEmpty) {
          mid = _number(uri.pathSegments.first);
        }
        if (mid == null || mid <= 0) {
          throw const FormatException('请填写有效 UP 主 mid 或空间链接');
        }
        final profile = await widget.service.content.loadProfile(mid);
        _preview = SubscriptionSource(
          kind: _kind,
          mid: mid,
          name: profile.name,
          token: DateTime.now().microsecondsSinceEpoch.toString(),
        );
      } else {
        mid = _number(_mid.text);
        season = _number(raw);
        if (uri?.host == 'space.bilibili.com') {
          final paths = uri!.pathSegments;
          if (paths.isNotEmpty) mid ??= _number(paths.first);
          if (uri.queryParameters['type'] == 'series') {
            throw const FormatException('暂不支持普通 series，请使用 UGC 合集');
          }
          season = _number(
            uri.queryParameters['season_id'] ??
                uri.queryParameters['sid'] ??
                '',
          );
          if (season == null &&
              paths.length >= 3 &&
              paths[1] == 'lists' &&
              uri.queryParameters['type'] == 'season') {
            season = _number(paths[2]);
          }
        }
        if (mid == null || mid <= 0 || season == null || season <= 0) {
          throw const FormatException('无法解析时请补充 UP 主 mid 和 UGC 合集 seasonId');
        }
        CreatorCollection? found;
        for (var page = 1; page <= 20; page++) {
          final result = await widget.service.content.loadCollections(
            mid,
            page: page,
          );
          for (final item in result.items) {
            if (item.id == season) found = item;
          }
          if (found != null || !result.hasMore) break;
        }
        if (found == null) {
          throw const FormatException(
            '未找到此 UP 主的 UGC 合集，请核对 mid 与 seasonId，或稍后重试',
          );
        }
        _preview = SubscriptionSource(
          kind: _kind,
          mid: mid,
          seasonId: season,
          name: found.title,
          token: DateTime.now().microsecondsSinceEpoch.toString(),
        );
      }
    } catch (error) {
      _error = error is FormatException
          ? error.message
          : '无法预览：网络、登录会话或 B 站风控异常，请稍后重试。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.service.addSource(_preview!);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is StateError
              ? error.message.toString()
              : '订阅未保存，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加订阅源'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<SubscriptionKind>(
            segments: const [
              ButtonSegment(
                value: SubscriptionKind.creator,
                label: Text('UP主'),
              ),
              ButtonSegment(
                value: SubscriptionKind.collection,
                label: Text('UGC合集'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: _busy
                ? null
                : (set) => setState(() {
                    _kind = set.single;
                    _preview = null;
                  }),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            onChanged: (_) => setState(() => _preview = null),
            decoration: InputDecoration(
              labelText: _kind == SubscriptionKind.creator
                  ? 'mid 或空间链接'
                  : 'seasonId 或 UGC 合集链接',
            ),
          ),
          if (_kind == SubscriptionKind.collection)
            TextField(
              controller: _mid,
              onChanged: (_) => setState(() => _preview = null),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'UP主 mid（链接解析不到时必填）',
              ),
            ),
          if (_error != null) Text(_error!),
          if (_preview != null)
            Text('确认来源：${_preview!.name}\n首次扫描只建立基线；不修改 B站关注或收藏。'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : _preview == null
            ? _check
            : _save,
        child: Text(
          _busy
              ? '处理中…'
              : _preview == null
              ? '预览名称'
              : '确认订阅',
        ),
      ),
    ],
  );
}
