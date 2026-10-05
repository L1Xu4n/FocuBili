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
  bool _settingsOpen = false;
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

  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SubscriptionSettingsPage(
            service: _service,
            notificationService: widget.notificationService,
          ),
        ),
      );
    } finally {
      _settingsOpen = false;
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
          title: const Text('焦点订阅'),
          actions: [
            IconButton(
              tooltip: '手动刷新',
              onPressed: !_service.enabled || _service.refreshing
                  ? null
                  : () => unawaited(_service.refresh(manual: true)),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '焦点订阅设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _openSettings,
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_service.storageError != null)
                  Text(
                    _service.storageError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (!_service.enabled)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('焦点订阅尚未开启，请在右上角设置中选择学习来源。'),
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
                    child: Text('暂无匹配的更新。首次订阅会先获取已有内容，之后的新视频会出现在这里。'),
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

/// Source management stays one level below the update feed.
class SubscriptionSettingsPage extends StatefulWidget {
  const SubscriptionSettingsPage({
    super.key,
    required this.service,
    this.notificationService = const FocusNotificationService(),
  });
  final SubscriptionService service;
  final FocusNotificationService notificationService;
  @override
  State<SubscriptionSettingsPage> createState() =>
      _SubscriptionSettingsPageState();
}

class _SubscriptionSettingsPageState extends State<SubscriptionSettingsPage> {
  SubscriptionService get _service => widget.service;
  bool _busy = false;
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
      _message('操作未保存，请稍后重试。');
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

  Future<void> _addSource() => _action(() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddSourceDialog(service: _service),
    );
  });

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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('焦点订阅设置'),
        actions: [
          IconButton(
            tooltip: '检查更新',
            icon: const Icon(Icons.refresh),
            onPressed: !_service.enabled || _service.refreshing
                ? null
                : () => _action(() => _service.refresh(manual: true)),
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
                title: const Text('开启焦点订阅'),
                value: _service.enabled,
                subtitle: const Text('启动、回到前台、手动及前台每小时检查更新。'),
                onChanged: _busy
                    ? null
                    : (value) => _action(() => _service.setEnabled(value)),
              ),
              if (_service.storageError != null)
                Text(
                  _service.storageError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_service.enabled) ...[
                SwitchListTile(
                  title: const Text('系统通知（默认关闭）'),
                  value: _service.notificationsEnabled,
                  subtitle: const Text('明确开启时才请求权限；专注期间只更新角标。'),
                  onChanged: _busy ? null : _notifications,
                ),
                SwitchListTile(
                  key: const Key('subscription-background-switch'),
                  title: const Text('Android 后台每小时检查（默认关闭）'),
                  value: _service.backgroundRefreshEnabled,
                  subtitle: Text(
                    _service.backgroundRefreshSupported
                        ? '系统可能延后执行；强行停止应用后需重新打开。后台检查不代表一定收到通知。'
                        : '当前平台不支持后台检查，可在前台检查更新。',
                  ),
                  onChanged: _busy || !_service.backgroundRefreshSupported
                      ? null
                      : (value) => _action(
                          () => _service.setBackgroundRefreshEnabled(value),
                        ),
                ),
                Text(
                  _service.lastBackgroundCheckAt == null
                      ? '最近后台检查：尚无记录'
                      : '最近后台检查：${_service.lastBackgroundCheckAt!.toLocal().toString().split('.').first}',
                ),
                if (_service.backgroundStatus != null)
                  Text(_service.backgroundStatus!),
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
                  child: Text('主动选择学习来源。先获取已有内容，之后只提醒新增视频。'),
                ),
              for (final source in _service.sources)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SubscriptionSourceImage(source: source),
                        const SizedBox(height: 8),
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
                              : _service.checkpoint(source.key)?.error != null
                              ? _service.checkpoint(source.key)?.initialized ==
                                        true
                                    ? '更新检查失败 · 请刷新重试'
                                    : '获取已有内容失败 · 请刷新重试'
                              : _service.checkpoint(source.key)?.initialized ==
                                    true
                              ? '已订阅更新'
                              : '正在获取已有内容',
                        ),
                        if (_service.checkpoint(source.key)?.error != null)
                          Text(_service.checkpoint(source.key)!.error!),
                        if (_service.checkpoint(source.key)?.partial == true)
                          Text(
                            '正在继续获取内容 · 下一页 ${_service.checkpoint(source.key)!.nextPage}',
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
            ],
          ),
        ),
      ),
    ),
  );
}

/// Bilibili images can be absent or blocked without breaking source management.
class SubscriptionSourceImage extends StatelessWidget {
  const SubscriptionSourceImage({super.key, required this.source});
  final SubscriptionSource source;
  @override
  Widget build(BuildContext context) {
    final creator = source.kind == SubscriptionKind.creator;
    final fallback = Icon(
      creator ? Icons.person_outline : Icons.video_library_outlined,
      size: 32,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(creator ? 28 : 8),
      child: SizedBox(
        width: creator ? 56 : 96,
        height: 56,
        child: source.imageUrl.isEmpty
            ? fallback
            : Image.network(
                source.imageUrl,
                headers: const {'Referer': 'https://www.bilibili.com/'},
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({required this.service, this.initialSource});
  final SubscriptionSource? initialSource;
  final SubscriptionService service;
  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _input = TextEditingController(), _mid = TextEditingController();
  SubscriptionKind _kind = SubscriptionKind.creator;
  bool _busy = false;
  bool _cancelled = false;
  String? _error;
  SubscriptionSource? _preview;
  @override
  void initState() {
    super.initState();
    _preview = widget.initialSource;
    _kind = _preview?.kind ?? SubscriptionKind.creator;
  }

  @override
  void dispose() {
    _input.dispose();
    _mid.dispose();
    super.dispose();
  }

  int? _number(String value) => int.tryParse(value.trim());
  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final raw = _input.text.trim();
      final uri = Uri.tryParse(
        raw.startsWith('space.bilibili.com/') ? 'https://$raw' : raw,
      );
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
        final profile = await widget.service.content
            .loadProfile(mid)
            .timeout(widget.service.requestTimeout);
        if (!mounted || _cancelled) return;
        _preview = SubscriptionSource(
          kind: _kind,
          mid: mid,
          name: profile.name,
          imageUrl: profile.avatarUrl,
          token: DateTime.now().microsecondsSinceEpoch.toString(),
        );
      } else {
        mid = _number(_mid.text);
        season = _number(raw);
        if (uri?.host == 'space.bilibili.com') {
          final paths = uri!.pathSegments;
          if (paths.isNotEmpty) mid = _number(paths.first) ?? mid;
          if (uri.queryParameters['type'] == 'series' ||
              paths.contains('seriesdetail')) {
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
          if (!mounted || _cancelled) return;
          final result = await widget.service.content
              .loadCollections(mid, page: page)
              .timeout(widget.service.requestTimeout);
          if (!mounted || _cancelled) return;
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
          imageUrl: found.coverUrl,
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
    if (_busy || _preview == null) return;
    setState(() => _busy = true);
    try {
      await widget.service.addSource(_preview!);
      if (!widget.service.enabled) await widget.service.setEnabled(true);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              widget.service.sources.any(
                (source) => source.key == _preview!.key,
              )
              ? '订阅源已保存，但开启检查失败；请在设置中重试。'
              : error is StateError
              ? error.message.toString()
              : '订阅未保存，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy || _preview == null,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _cancelled = true;
    },
    child: AlertDialog(
      title: const Text('添加订阅源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.initialSource == null) ...[
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
                enabled: !_busy,
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
                  enabled: !_busy,
                  onChanged: (_) => setState(() => _preview = null),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'UP主 mid（链接解析不到时必填）',
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                _kind == SubscriptionKind.creator
                    ? 'mid 是 UP 主空间网址中的数字，例如 space.bilibili.com/12345 中的 12345。可在 UP 主主页分享菜单复制空间链接，也可直接点主页的焦点订阅按钮。'
                    : '打开 UP 主空间 → 合集 → 目标合集，复制链接。例如 space.bilibili.com/12345/lists/67890?type=season。无法解析时，分别填写 UP 主 mid 和合集 seasonId。暂不支持普通 series 列表。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_error != null) Text(_error!),
            if (_preview != null) ...[
              const SizedBox(height: 12),
              SubscriptionSourceImage(source: _preview!),
              Text('确认来源：${_preview!.name}\n先获取已有内容，之后只提醒新视频；不修改 B站关注或收藏。'),
              if (!widget.service.enabled) const Text('确认订阅后将开启焦点订阅。'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy && _preview != null
              ? null
              : () {
                  _cancelled = true;
                  Navigator.pop(context);
                },
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
    ),
  );
}

/// Adds an already resolved profile or collection without requiring copied IDs.
class FocusSubscriptionButton extends StatefulWidget {
  const FocusSubscriptionButton({
    super.key,
    required this.source,
    this.service,
  });
  final SubscriptionSource source;
  final SubscriptionService? service;
  @override
  State<FocusSubscriptionButton> createState() =>
      _FocusSubscriptionButtonState();
}

class _FocusSubscriptionButtonState extends State<FocusSubscriptionButton> {
  late final SubscriptionService _service =
      widget.service ?? SubscriptionService.instance;
  bool _opening = false;
  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _AddSourceDialog(service: _service, initialSource: widget.source),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final subscribed = _service.sources.any(
        (source) => source.key == widget.source.key,
      );
      return IconButton(
        key: const Key('focus-subscribe-button'),
        tooltip: subscribed ? '已加入焦点订阅' : '加入焦点订阅',
        onPressed: _opening || subscribed || widget.source.mid <= 0
            ? null
            : _open,
        icon: Icon(
          subscribed
              ? Icons.notifications_active_outlined
              : Icons.notification_add_outlined,
        ),
      );
    },
  );
}
