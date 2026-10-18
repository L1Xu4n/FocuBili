import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show FloatingHeaderSnapConfiguration;
import 'package:focubili/features/common/app_network_image.dart';

import '../../models/subscription.dart';
import '../../models/public_profile.dart';
import '../../services/subscription_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/focus_notification_service.dart';
import '../../services/learning_list_service.dart';
import '../learning/learning_add_sheet.dart';
import '../player/player_page.dart';
import '../profile/user_profile_page.dart';
import '../profile/collection_detail_page.dart';
import 'subscription_feed_tile.dart';
import 'subscription_history_page.dart';

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

class _SubscriptionUpdatesPageState extends State<SubscriptionUpdatesPage>
    with TickerProviderStateMixin {
  late final SubscriptionService _service =
      widget.service ?? SubscriptionService.instance;
  late final BilibiliService _videos =
      widget.videoService ?? BilibiliVideoInfoService();
  late final LearningListService _learning =
      widget.learningService ?? LearningListService();
  bool _unreadOnly = false, _todayOnly = false, _busy = false;
  bool _settingsOpen = false;
  String? _sourceKey;
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

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
    if (result != null) _message('已加入所选分 P。');
  });

  Future<void> _addSelected() => _action(() async {
    final ids = Set<String>.of(_selected);
    final selections = <LearningPartSelection>[];
    var failed = 0;
    for (final id in ids) {
      try {
        final video = await _videos.lookupVideo(id);
        // Batch selection adds the first part. Existing tasks retain all progress.
        if (video.parts.isEmpty) {
          failed++;
          continue;
        }
        selections.add(LearningPartSelection(video, video.parts.first));
      } catch (_) {
        failed++;
      }
      if (!mounted) return;
    }
    final result = await _learning.addBatch(selections);
    if (!mounted) return;
    if (!result.persisted) {
      _message('学习清单未保存，请重试。');
      return;
    }
    setState(_selected.clear);
    _message(
      '已加入 ${result.addedIds.length} 项，已有 ${result.existingIds.length} 项'
      '${failed > 0 ? '，$failed 项详情读取失败' : ''}'
      '${result.capacityExceeded ? '；学习清单已满，部分未加入' : ''}。多分 P 视频可在学习清单中继续选择分 P。',
    );
  });

  void _toggle(SubscriptionFeedItem item) => setState(() {
    if (!_selected.remove(item.bvid)) _selected.add(item.bvid);
  });

  String _date(DateTime date) {
    final local = date.toLocal();
    return '--${local.year}年${local.month.toString().padLeft(2, '0')}月${local.day.toString().padLeft(2, '0')}日--';
  }

  List<SubscriptionFeedItem> _visibleItems() {
    final today = _date(DateTime.now());
    // A deleted source cannot strand the feed behind an invisible filter.
    final key = _service.sources.any((s) => s.key == _sourceKey)
        ? _sourceKey
        : null;
    if (key == null) _sourceKey = null;
    return _service.feed
        .where(
          (item) =>
              (!_unreadOnly || item.readAt == null) &&
              (!_todayOnly ||
                  _date(item.publishedAt ?? item.discoveredAt) == today) &&
              (key == null || item.sources.containsKey(key)),
        )
        .toList();
  }

  double _filterHeight(BuildContext context) {
    final available = MediaQuery.sizeOf(context).width.clamp(0.0, 900.0) - 32;
    final scaler = MediaQuery.textScalerOf(context);
    var rows = 1;
    var used = 0.0;
    var lineHeight = 48.0;
    final labels = ['仅未读', '今日发布', '全部标为已读'];
    for (var i = 0; i < labels.length; i++) {
      final painter = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: Theme.of(context).textTheme.labelLarge,
        ),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout();
      final width =
          painter.width +
          40 +
          (i == 0 && _unreadOnly || i == 1 && _todayOnly ? 20 : 0);
      if (painter.height + 24 > lineHeight) lineHeight = painter.height + 24;
      if (used > 0 && used + 8 + width > available) {
        rows++;
        used = 0;
      }
      used += width + (used > 0 ? 8 : 0);
      painter.dispose();
    }
    return 8 +
        rows * lineHeight +
        (_service.sources.isEmpty ? 0 : 64 + scaler.scale(14));
  }

  Widget _filters(List<SubscriptionFeedItem> items) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              label: const Text('仅未读'),
              selected: _unreadOnly,
              onSelected: (value) => setState(() {
                _unreadOnly = value;
                _selected.clear();
              }),
            ),
            FilterChip(
              label: const Text('今日发布'),
              selected: _todayOnly,
              onSelected: (value) => setState(() {
                _todayOnly = value;
                _selected.clear();
              }),
            ),
            TextButton(
              onPressed: _busy ? null : () => _action(_service.markAllRead),
              child: const Text('全部标为已读'),
            ),
          ],
        ),
        if (_service.sources.isNotEmpty)
          Expanded(
            child: ListView(
              key: const Key('subscription-source-filters'),
              scrollDirection: Axis.horizontal,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: const Text('全部来源'),
                    selected: _sourceKey == null,
                    onSelected: (_) => setState(() {
                      _sourceKey = null;
                      _selected.clear();
                    }),
                  ),
                ),
                for (final source in _service.sources)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Semantics(
                      selected: _sourceKey == source.key,
                      child: InkWell(
                        key: ValueKey('source-filter-${source.key}'),
                        onTap: () => setState(() {
                          _sourceKey = _sourceKey == source.key
                              ? null
                              : source.key;
                          _selected.clear();
                        }),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 96,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: _sourceKey == source.key
                                ? Theme.of(
                                    context,
                                  ).colorScheme.secondaryContainer
                                : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                height: 44,
                                child: FittedBox(
                                  child: SubscriptionSourceImage(
                                    source: source,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                source.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );

  List<({String key, WidgetBuilder builder})> _rows(
    List<SubscriptionFeedItem> items,
  ) {
    final rows = <({String key, WidgetBuilder builder})>[];
    String? previousDate;
    var readSection = false;
    for (final item in items) {
      if (!readSection && item.readAt != null) {
        readSection = true;
        previousDate = null;
        rows.add((
          key: 'read',
          builder: (context) => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('已读'),
                ),
                Expanded(child: Divider()),
              ],
            ),
          ),
        ));
      }
      final date = _date(item.discoveredAt);
      if (date != previousDate) {
        previousDate = date;
        rows.add((
          key: '${readSection ? 'read' : 'unread'}-$date',
          builder: (context) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              date,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ));
      }
      rows.add((
        key: item.bvid,
        builder: (context) => Card(
          key: ValueKey('subscription-feed-${item.bvid}'),
          color: _selected.contains(item.bvid)
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          clipBehavior: Clip.antiAlias,
          child: SubscriptionFeedTile(
            item: item,
            selected: _selecting ? _selected.contains(item.bvid) : null,
            onLongPress: _busy ? null : () => _toggle(item),
            onTap: _busy
                ? null
                : () => _selecting ? _toggle(item) : unawaited(_play(item)),
            actions: _selecting
                ? null
                : Wrap(
                    spacing: 8,
                    children: [
                      if (item.readAt == null)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () =>
                                    _action(() => _service.markRead(item.bvid)),
                          child: const Text('标为已读'),
                        ),
                      TextButton.icon(
                        onPressed: _busy ? null : () => _addLearning(item),
                        icon: const Icon(Icons.playlist_add),
                        label: const Text('加入学习清单'),
                      ),
                    ],
                  ),
          ),
        ),
      ));
    }
    rows.add((
      key: 'retention',
      builder: (context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 20, horizontal: 12),
        child: Text('已读记录会保留七天，到期后自动清除', textAlign: TextAlign.center),
      ),
    ));
    return rows;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final items = _visibleItems();
      final visibleIds = items.map((e) => e.bvid).toSet();
      _selected.removeWhere((id) => !visibleIds.contains(id));
      final rows = _rows(items);
      final height = _filterHeight(context);
      return PopScope(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _selecting) setState(_selected.clear);
        },
        child: Scaffold(
          appBar: AppBar(
            leading: _selecting
                ? IconButton(
                    tooltip: '退出多选',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_selected.clear),
                  )
                : null,
            title: Text(_selecting ? '已选 ${_selected.length} 项' : '焦点订阅'),
            actions: _selecting
                ? [
                    IconButton(
                      tooltip: _selected.length == items.length ? '取消全选' : '全选',
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              if (_selected.length == items.length) {
                                _selected.clear();
                              } else {
                                _selected.addAll(visibleIds);
                              }
                            }),
                      icon: const Icon(Icons.select_all),
                    ),
                    IconButton(
                      tooltip: '标为已读',
                      onPressed: _busy
                          ? null
                          : () => _action(() async {
                              await _service.markReadBatch(Set.of(_selected));
                              if (mounted) setState(_selected.clear);
                            }),
                      icon: const Icon(Icons.done_all),
                    ),
                    IconButton(
                      tooltip: '加入学习清单',
                      onPressed: _busy ? null : _addSelected,
                      icon: const Icon(Icons.playlist_add),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip: '手动刷新',
                      onPressed: !_service.enabled || _service.refreshing
                          ? null
                          : () => unawaited(_service.refresh(manual: true)),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: '焦点订阅设置',
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: RefreshIndicator(
                onRefresh: () => _service.refresh(manual: true),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (_service.storageError != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_service.storageError!),
                        ),
                      ),
                    if (!_service.enabled)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('焦点订阅尚未开启，请在右上角设置中选择学习来源。'),
                        ),
                      ),
                    if (_service.refreshing || _busy)
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(),
                      ),
                    SliverPersistentHeader(
                      floating: true,
                      delegate: _SubscriptionFilterHeader(
                        extent: height,
                        vsync: this,
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: _filters(items),
                        ),
                      ),
                    ),
                    if (items.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text(
                            '暂无匹配的更新。UP 主和合集读取部分内容建立基线；历史视频可在订阅源设置中单独导入。',
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      sliver: SliverList.builder(
                        itemCount: rows.length,
                        findChildIndexCallback: (key) => key is ValueKey<String>
                            ? rows.indexWhere((row) => row.key == key.value) < 0
                                  ? null
                                  : rows.indexWhere(
                                      (row) => row.key == key.value,
                                    )
                            : null,
                        itemBuilder: (_, index) => KeyedSubtree(
                          key: ValueKey(rows[index].key),
                          child: rows[index].builder(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SubscriptionFilterHeader extends SliverPersistentHeaderDelegate {
  _SubscriptionFilterHeader({
    required this.extent,
    required this.child,
    required this.vsync,
  });
  @override
  final TickerProvider vsync;
  @override
  FloatingHeaderSnapConfiguration get snapConfiguration =>
      FloatingHeaderSnapConfiguration(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
  final double extent;
  final Widget child;
  @override
  double get minExtent => 0;
  @override
  double get maxExtent => extent;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ClipRect(
    child: OverflowBox(
      alignment: Alignment.topCenter,
      minHeight: extent,
      maxHeight: extent,
      child: child,
    ),
  );
  @override
  bool shouldRebuild(covariant _SubscriptionFilterHeader old) => true;
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
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;
  void _toggleSource(SubscriptionSource source) => setState(() {
    if (!_selected.remove(source.key)) _selected.add(source.key);
  });
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

  Future<void> _openSource(SubscriptionSource source) async {
    if (_selecting) {
      _toggleSource(source);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => source.kind == SubscriptionKind.creator
            ? UserProfilePage(
                mid: source.mid,
                initialName: source.name,
                initialAvatarUrl: source.imageUrl,
                publicContentService: _service.content,
                subscriptionService: _service,
              )
            : CollectionDetailPage(
                collection: CreatorCollection(
                  id: source.seasonId!,
                  ownerMid: source.mid,
                  title: source.name,
                  coverUrl: source.imageUrl,
                  description: '',
                  totalCount: _service.checkpoint(source.key)?.total ?? 0,
                  previewVideos: const [],
                ),
                publicContentService: _service.content,
                subscriptionService: _service,
              ),
      ),
    );
  }

  Future<void> _background(bool value) => _action(() async {
    await _service.setBackgroundRefreshEnabled(value);
    if (!value || !mounted || !_service.showAndroidBatteryGuidance) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('让每小时检查更可靠'),
        content: const Text(
          '建议将应用省电设置为“无限制”，在多任务界面加锁，并开启自启动。系统仍可能延后检查；强行停止后需重新打开应用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('知道了'),
          ),
          TextButton(
            onPressed: () async {
              await widget.notificationService.openBatterySettings();
            },
            child: const Text('省电设置'),
          ),
          TextButton(
            onPressed: () async {
              await widget.notificationService
                  .openBackgroundAutostartSettings();
            },
            child: const Text('自启动设置'),
          ),
        ],
      ),
    );
  });

  Future<void> _delete(SubscriptionSource source) =>
      _deleteSources({source.key});

  Future<void> _deleteSources(Set<String> keys) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('删除所选 ${keys.length} 个订阅源？已有更新历史、笔记和学习任务保留。'),
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
      await _action(() async {
        await _service.deleteSources(keys);
        if (mounted) setState(_selected.clear);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) => PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  tooltip: '退出多选',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_selected.clear),
                )
              : null,
          title: Text(_selecting ? '已选 ${_selected.length} 个来源' : '焦点订阅设置'),
          actions: _selecting
              ? [
                  IconButton(
                    tooltip: '全选',
                    icon: const Icon(Icons.select_all),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            if (_selected.length == _service.sources.length) {
                              _selected.clear();
                            } else {
                              _selected.addAll(
                                _service.sources.map((s) => s.key),
                              );
                            }
                          }),
                  ),
                  PopupMenuButton<bool>(
                    tooltip: '批量暂停或恢复',
                    enabled: !_busy,
                    icon: const Icon(Icons.pause_circle_outline),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: true, child: Text('暂停所选')),
                      PopupMenuItem(value: false, child: Text('恢复所选')),
                    ],
                    onSelected: (paused) => _action(() async {
                      await _service.pauseSources(Set.of(_selected), paused);
                      if (mounted) setState(_selected.clear);
                    }),
                  ),
                  IconButton(
                    tooltip: '删除所选',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy
                        ? null
                        : () => _deleteSources(Set.of(_selected)),
                  ),
                ]
              : [
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
                  SwitchListTile(
                    key: const Key('subscription-background-switch'),
                    title: Text(_service.backgroundCheckLabel),
                    value: _service.backgroundRefreshEnabled,
                    subtitle: Text(
                      _service.backgroundRefreshSupported
                          ? _service.backgroundCheckDescription
                          : '${_service.backgroundCheckDescription}\n系统暂未允许原生后台检查，当前使用前台检查。',
                    ),
                    onChanged:
                        _busy ||
                            (!_service.backgroundRefreshSupported &&
                                !_service.backgroundRefreshEnabled)
                        ? null
                        : _background,
                  ),
                  Text(
                    _service.lastBackgroundCheckAt == null
                        ? '最近后台检查：尚无记录'
                        : '最近后台检查：${_service.lastBackgroundCheckAt!.toLocal().toString().split('.').first}',
                  ),
                  if (_service.backgroundStatusText != null)
                    Text(_service.backgroundStatusText!),
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
                    child: Text('UP 主和合集只读取部分内容建立基线。历史导入与更新提醒相互独立。'),
                  ),
                for (final source in _service.sources)
                  Card(
                    key: ValueKey('subscription-source-${source.key}'),
                    color: _selected.contains(source.key)
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                    child: InkWell(
                      onTap: _busy ? null : () => _openSource(source),
                      onLongPress: _busy ? null : () => _toggleSource(source),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_selecting)
                                  Icon(
                                    _selected.contains(source.key)
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                  ),
                                SubscriptionSourceImage(source: source),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        source.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
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
                                                      ?.error !=
                                                  null
                                            ? _service
                                                          .checkpoint(
                                                            source.key,
                                                          )
                                                          ?.initialized ==
                                                      true
                                                  ? '更新检查失败 · 请刷新重试'
                                                  : '获取已有内容失败 · 请刷新重试'
                                            : _service
                                                      .checkpoint(source.key)
                                                      ?.initialized ==
                                                  true
                                            ? '已订阅更新'
                                            : source.kind ==
                                                  SubscriptionKind.creator
                                            ? '正在读取最近两页'
                                            : '正在读取合集首尾内容',
                                      ),
                                      if (_service
                                              .checkpoint(source.key)
                                              ?.error !=
                                          null)
                                        Text(
                                          _service
                                              .checkpoint(source.key)!
                                              .error!,
                                        ),
                                      if (_service
                                              .checkpoint(source.key)
                                              ?.partial ==
                                          true)
                                        Text(
                                          '${source.kind == SubscriptionKind.collection ? '合集核对' : '补查更新'}中 · 下一页 ${_service.checkpoint(source.key)!.nextPage}',
                                        ),
                                      if (source.kind ==
                                          SubscriptionKind.collection)
                                        Text(
                                          '最近检查：${_service.checkpoint(source.key)?.lastSuccess?.toLocal().toString() ?? '尚未完成'}。检查合集首尾各两页；中间位置新增或任意重排可能未覆盖，可单独导入历史。',
                                        ),
                                      if (!_selecting)
                                        Wrap(
                                          spacing: 12,
                                          children: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.of(
                                                    context,
                                                  ).push<void>(
                                                    MaterialPageRoute(
                                                      builder: (_) =>
                                                          SubscriptionHistoryPage(
                                                            service: _service,
                                                            source: source,
                                                          ),
                                                    ),
                                                  ),
                                              child: const Text('历史内容'),
                                            ),
                                            if (_service
                                                    .checkpoint(source.key)
                                                    ?.blocked ==
                                                true)
                                              TextButton(
                                                onPressed: () => _action(
                                                  () => _service.retrySource(
                                                    source.key,
                                                  ),
                                                ),
                                                child: const Text('重新检查'),
                                              ),
                                            TextButton(
                                              onPressed: _busy
                                                  ? null
                                                  : () => _action(
                                                      () =>
                                                          _service.pauseSource(
                                                            source.key,
                                                            !source.paused,
                                                          ),
                                                    ),
                                              child: Text(
                                                source.paused ? '恢复订阅' : '暂停',
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: _busy
                                                  ? null
                                                  : () => _delete(source),
                                              child: const Text('删除源'),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_service.refreshing) const LinearProgressIndicator(),
              ],
            ),
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
            : AppNetworkImage(
                imageUrl: source.imageUrl,
                httpHeaders: const {'Referer': 'https://www.bilibili.com/'},
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => fallback,
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
              Text(
                '确认来源：${_preview!.name}\nUP 主读取最近两页，合集读取首尾各两页后开始检查更新。合集中间位置或重排内容可能未覆盖；历史可单独导入，不修改 B站关注或收藏。',
              ),
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

  Future<void> _unsubscribe() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('取消焦点订阅'),
          content: Text('取消“${widget.source.name}”的焦点订阅？已有更新和学习任务保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('取消订阅'),
            ),
          ],
        ),
      );
      if (confirmed == true) await _service.deleteSource(widget.source.key);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取消未保存，请重试。')));
      }
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
        tooltip: subscribed ? '取消焦点订阅' : '加入焦点订阅',
        onPressed: _opening || widget.source.mid <= 0
            ? null
            : subscribed
            ? _unsubscribe
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
