import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show FloatingHeaderSnapConfiguration;
import 'package:focubili/features/common/app_network_image.dart';

import '../../core/widgets/drag_selection_region.dart';
import '../../models/subscription.dart';
import '../../platform/app_platform.dart';
import '../../platform/platform_capabilities.dart';
import '../../services/bilibili_image_url_policy.dart';
import '../../services/image_resource_cache.dart';
import '../../models/public_profile.dart';
import '../../services/subscription_service.dart';
import '../../services/subscription_source_visits.dart';
import '../../services/bilibili_service.dart';
import '../../services/focus_notification_service.dart';
import '../../services/learning_list_service.dart';
import '../common/discovery_blocklist.dart';
import '../common/selection_range_snapshot.dart';
import '../learning/learning_add_sheet.dart';
import '../player/player_page.dart';
import '../profile/user_profile_page.dart';
import '../profile/collection_detail_page.dart';
import 'subscription_source_rail.dart';
import 'subscription_timeline_tile.dart';
import 'subscription_history_page.dart';

class SubscriptionUpdatesPage extends StatefulWidget {
  /// 创建订阅更新页，并将可选的测试平台传给设置页。
  const SubscriptionUpdatesPage({
    super.key,
    this.service,
    this.videoService,
    this.coverCache,
    this.learningService,
    this.notificationService = const FocusNotificationService(),
    this.appPlatform,
  });
  final SubscriptionService? service;
  final ImageResourceCache? coverCache;
  final BilibiliService? videoService;
  final LearningListService? learningService;
  final FocusNotificationService notificationService;
  final AppPlatform? appPlatform;
  @override
  State<SubscriptionUpdatesPage> createState() =>
      _SubscriptionUpdatesPageState();
}

class _SubscriptionUpdatesPageState extends State<SubscriptionUpdatesPage>
    with
        TickerProviderStateMixin,
        DiscoveryBlocklistState<SubscriptionUpdatesPage> {
  late final SubscriptionService _service =
      widget.service ?? SubscriptionService.instance;
  late final BilibiliService _videos =
      widget.videoService ?? BilibiliVideoInfoService();
  late final LearningListService _learning =
      widget.learningService ?? LearningListService();
  bool _unreadOnly = false, _todayOnly = false, _busy = false;
  bool _settingsOpen = false;
  String? _sourceKey;
  final _scrollController = ScrollController();
  final Set<String> _selected = {};
  final _selectionRange = SelectionRangeSnapshot();
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _endSelection() {
    _selecting = false;
    _selected.clear();
    _selectionRange.clear();
  }

  void _updateSelectionRange(DragSelectionUpdate update, List<String> ids) {
    if (!_selecting || _busy || !discoveryBlocklistActionsReady) return;
    final next = _selectionRange.apply(update, ids, _selected);
    if (next == null) return;
    setState(
      () => _selected
        ..clear()
        ..addAll(next),
    );
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy || !discoveryBlocklistActionsReady) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      _message('操作未保存，请检查设备存储后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 从订阅更新页打开设置，并沿用当前页面的平台。
  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SubscriptionSettingsPage(
            service: _service,
            notificationService: widget.notificationService,
            appPlatform: widget.appPlatform,
          ),
        ),
      );
    } finally {
      _settingsOpen = false;
    }
  }

  bool _isUpdateBlocked(SubscriptionFeedItem item) =>
      discoveryBlocklist.isNotEmpty &&
      blocksSubscriptionUpdate(discoveryBlocklist, item);

  Future<void> _play(SubscriptionFeedItem item) => _action(() async {
    if (_isUpdateBlocked(item)) return;
    if (item.readAt == null) {
      // Save the tap independently of whether the player can open.
      unawaited(
        _service
            .markRead(item.bvid)
            .onError<SubscriptionStorageException>(
              (_, _) {}, // The service already exposes the storage error.
            ),
      );
    }
    final video = await _videos.lookupVideo(item.bvid);
    if (!mounted || !discoveryBlocklistActionsReady || _isUpdateBlocked(item)) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PlayerPage(video: video, bilibiliService: _videos),
      ),
    );
  });

  Future<void> _addLearning(SubscriptionFeedItem item) => _action(() async {
    if (_isUpdateBlocked(item)) return;
    final video = await _videos.lookupVideo(item.bvid);
    if (!mounted || !discoveryBlocklistActionsReady || _isUpdateBlocked(item)) {
      return;
    }
    final result = await LearningAddSheet.show(
      context,
      video: video,
      service: _learning,
      canConfirm: () =>
          mounted && discoveryBlocklistActionsReady && !_isUpdateBlocked(item),
    );
    if (result != null) _message('已加入所选分 P。');
  });

  Future<void> _addSelected() => _action(() async {
    final targets = _service.feed
        .where(
          (item) => _selected.contains(item.bvid) && !_isUpdateBlocked(item),
        )
        .toList();
    if (targets.isEmpty) return;
    final selections = <LearningPartSelection>[];
    var failed = 0;
    for (final item in targets) {
      if (!discoveryBlocklistActionsReady) return;
      if (_isUpdateBlocked(item)) continue;
      try {
        final video = await _videos.lookupVideo(item.bvid);
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
    if (!discoveryBlocklistActionsReady) return;
    final stillVisible = _service.feed
        .where((item) => !_isUpdateBlocked(item))
        .map((item) => item.bvid)
        .toSet();
    final eligible = selections
        .where((item) => stillVisible.contains(item.video.bvid))
        .toList();
    if (eligible.isEmpty && selections.isNotEmpty) {
      _message('所选更新已隐藏，未加入学习清单。');
      return;
    }
    final result = await _learning.addBatch(eligible);
    if (!mounted) return;
    if (!result.persisted) {
      _message('学习清单未保存，请重试。');
      return;
    }
    setState(_endSelection);
    _message(
      '已加入 ${result.addedIds.length} 项，已有 ${result.existingIds.length} 项'
      '${failed > 0 ? '，$failed 项详情读取失败' : ''}'
      '${result.capacityExceeded ? '；学习清单已满，部分未加入' : ''}。多分 P 视频可在学习清单中继续选择分 P。',
    );
  });

  void _toggle(SubscriptionFeedItem item) {
    if (_busy || !discoveryBlocklistActionsReady || _isUpdateBlocked(item)) {
      return;
    }
    setState(() {
      _selecting = true;
      _selectionRange.clear();
      if (!_selected.remove(item.bvid)) _selected.add(item.bvid);
    });
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    final today = DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final prefix = DateUtils.isSameDay(local, today)
        ? '今天 · '
        : DateUtils.isSameDay(local, yesterday)
        ? '昨天 · '
        : local.year == today.year
        ? ''
        : '${local.year}年';
    return '$prefix${local.month}月${local.day}日';
  }

  bool _visibleInGlobalFilters(SubscriptionFeedItem item, DateTime today) =>
      (!_unreadOnly || item.readAt == null) &&
      (!_todayOnly ||
          DateUtils.isSameDay(
            (item.publishedAt ?? item.discoveredAt).toLocal(),
            today,
          ));

  List<SubscriptionFeedItem> _railFeed() {
    if (!discoveryBlocklistReady) return const [];
    final today = DateTime.now();
    return _service.feed
        .where(
          (item) =>
              !_isUpdateBlocked(item) && _visibleInGlobalFilters(item, today),
        )
        .toList();
  }

  bool _canConfirmSource(SubscriptionSource source, Set<String> presented) =>
      mounted &&
      discoveryBlocklistActionsReady &&
      _service.sources.any(
        (s) => s.key == source.key && s.token == source.token,
      ) &&
      _railFeed()
          .where((e) => e.sources.containsKey(source.key))
          .map(SubscriptionSourceVisits.event)
          .toSet()
          .containsAll(presented);

  List<SubscriptionFeedItem> _itemsForFilters() {
    final today = DateTime.now();
    // A deleted source cannot strand the feed behind an invisible filter.
    final key = _service.sources.any((s) => s.key == _sourceKey)
        ? _sourceKey
        : null;
    if (key == null) _sourceKey = null;
    return _service.feed
        .where(
          (item) =>
              _visibleInGlobalFilters(item, today) &&
              (key == null || item.sources.containsKey(key)),
        )
        .toList();
  }

  bool get _hasHiddenUnread =>
      discoveryBlocklist.isNotEmpty &&
      _service.feed.any(
        (item) => item.readAt == null && _isUpdateBlocked(item),
      );

  Future<void> _markVisibleRead() => _action(() async {
    // Re-evaluate even if this callback came from the previous frame.
    if (!_hasHiddenUnread) {
      await _service.markAllRead();
      return;
    }
    final ids = {
      for (final item in _itemsForFilters())
        if (item.readAt == null && !_isUpdateBlocked(item)) item.bvid,
    };
    if (ids.isNotEmpty) await _service.markReadBatch(ids);
  });

  double _filterHeight(BuildContext context, String markReadLabel) {
    final available = MediaQuery.sizeOf(context).width.clamp(0.0, 900.0) - 32;
    final scaler = MediaQuery.textScalerOf(context);
    var rows = 1;
    var used = 0.0;
    var lineHeight = 48.0;
    final labels = ['仅未读', '今日发布', markReadLabel];
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
        (_service.sources.isEmpty ? 0 : 40 + scaler.scale(14));
  }

  Widget _filters({
    required String markReadLabel,
    required VoidCallback? markRead,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_service.sources.isNotEmpty)
          Expanded(
            child: SubscriptionSourceRail(
              sources: _service.sources,
              retainedFeed: _service.feed,
              actionsReady: discoveryBlocklistActionsReady,
              visibleFeed: _railFeed(),
              canConfirm: _canConfirmSource,
              selected: _sourceKey,
              onSelect: (key) {
                if (!mounted) return;
                setState(() {
                  _sourceKey = key;
                  _endSelection();
                });
              },
            ),
          ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              label: const Text('仅未读'),
              selected: _unreadOnly,
              onSelected: (value) => setState(() {
                _unreadOnly = value;
                _endSelection();
              }),
            ),
            FilterChip(
              label: const Text('今日发布'),
              selected: _todayOnly,
              onSelected: (value) => setState(() {
                _todayOnly = value;
                _endSelection();
              }),
            ),
            TextButton(
              onPressed: _busy ? null : markRead,
              child: Text(markReadLabel),
            ),
          ],
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
    for (final (index, item) in items.indexed) {
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
            child: Semantics(
              header: true,
              child: Text(
                date,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ));
      }
      rows.add((
        key: item.bvid,
        builder: (context) => DragSelectionTarget(
          index: index,
          builder: (context, handleKey) => SubscriptionTimelineTile(
            key: ValueKey('subscription-feed-${item.bvid}'),
            coverCache: widget.coverCache,
            item: item,
            selected: _selecting ? _selected.contains(item.bvid) : null,
            selectionHandleKey: handleKey,
            enabled: !_busy && discoveryBlocklistActionsReady,
            onLongPress: _selecting || _busy || !discoveryBlocklistActionsReady
                ? null
                : () => _toggle(item),
            onTap: _busy || !discoveryBlocklistActionsReady
                ? null
                : () => _selecting ? _toggle(item) : unawaited(_play(item)),
            onRead: () => unawaited(
              _action(() async {
                if (!_isUpdateBlocked(item)) await _service.markRead(item.bvid);
              }),
            ),
            onAdd: () => unawaited(_addLearning(item)),
          ),
        ),
      ));
    }
    rows.add((
      key: 'retention',
      builder: (context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 20, horizontal: 12),
        child: Text('只保留最近 14 天的订阅更新，已读和未读相同', textAlign: TextAlign.center),
      ),
    ));
    return rows;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final candidates = _itemsForFilters();
      final items = !discoveryBlocklistReady
          ? const <SubscriptionFeedItem>[]
          : discoveryBlocklist.isNotEmpty
          ? candidates.where((item) => !_isUpdateBlocked(item)).toList()
          : candidates;
      final hidden = discoveryBlocklistReady
          ? candidates.length - items.length
          : 0;
      final hasHiddenUnread = _hasHiddenUnread;
      final markReadLabel = hasHiddenUnread ? '显示项标为已读' : '全部标为已读';
      final markRead =
          !discoveryBlocklistActionsReady ||
              (hasHiddenUnread && !items.any((item) => item.readAt == null))
          ? null
          : () => unawaited(_markVisibleRead());
      final orderedIds = items.map((e) => e.bvid).toList();
      final visibleIds = orderedIds.toSet();
      _selected.removeWhere((id) => !visibleIds.contains(id));
      final batchEnabled =
          !_busy && discoveryBlocklistActionsReady && _selected.isNotEmpty;
      final rows = _rows(items);
      final height = _filterHeight(context, markReadLabel);
      return PopScope(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _selecting) setState(_endSelection);
        },
        child: Scaffold(
          appBar: AppBar(
            leading: _selecting
                ? IconButton(
                    tooltip: '退出多选',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_endSelection),
                  )
                : null,
            title: Text(_selecting ? '已选 ${_selected.length} 项' : '焦点订阅'),
            actions: _selecting
                ? [
                    IconButton(
                      tooltip: _selected.length == items.length ? '取消全选' : '全选',
                      onPressed:
                          _busy ||
                              !discoveryBlocklistActionsReady ||
                              items.isEmpty
                          ? null
                          : () => setState(() {
                              _selectionRange.clear();
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
                      onPressed: !batchEnabled
                          ? null
                          : () => _action(() async {
                              await _service.markReadBatch({
                                for (final item in _service.feed)
                                  if (_selected.contains(item.bvid) &&
                                      !_isUpdateBlocked(item))
                                    item.bvid,
                              });
                              if (mounted) setState(_endSelection);
                            }),
                      icon: const Icon(Icons.done_all),
                    ),
                    IconButton(
                      tooltip: '加入学习清单',
                      onPressed: batchEnabled ? _addSelected : null,
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
              child: DragSelectionRegion(
                controller: _scrollController,
                itemCount: orderedIds.length,
                enabled: _selecting && !_busy && discoveryBlocklistActionsReady,
                checkedAt: (index) => _selected.contains(orderedIds[index]),
                onDragUpdate: (update) =>
                    _updateSelectionRange(update, orderedIds),
                builder: (context, dragging) => RefreshIndicator(
                  onRefresh: () => _service.refresh(manual: true),
                  notificationPredicate: (notification) =>
                      !dragging && notification.depth == 0,
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: dragging
                        ? const NeverScrollableScrollPhysics()
                        : const AlwaysScrollableScrollPhysics(),
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
                      if (!discoveryBlocklistActionsReady)
                        SliverToBoxAdapter(
                          child: buildDiscoveryBlocklistStatus(),
                        ),
                      SliverPersistentHeader(
                        floating: true,
                        delegate: _SubscriptionFilterHeader(
                          extent: height,
                          vsync: this,
                          child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            child: _filters(
                              markReadLabel: markReadLabel,
                              markRead: markRead,
                            ),
                          ),
                        ),
                      ),
                      if (hidden > 0)
                        SliverToBoxAdapter(
                          child: DiscoveryBlocklistNotice(hiddenCount: hidden),
                        ),
                      if (discoveryBlocklistReady &&
                          items.isEmpty &&
                          hidden == 0)
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
                          findChildIndexCallback: (key) =>
                              key is ValueKey<String>
                              ? rows.indexWhere((row) => row.key == key.value) <
                                        0
                                    ? null
                                    : rows.indexWhere(
                                        (row) => row.key == key.value,
                                      )
                              : null,
                          itemBuilder: (context, index) => KeyedSubtree(
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
  /// 创建订阅设置页，测试可指定平台以覆盖不同设备能力。
  const SubscriptionSettingsPage({
    super.key,
    required this.service,
    this.notificationService = const FocusNotificationService(),
    this.appPlatform,
  });
  final SubscriptionService service;
  final FocusNotificationService notificationService;
  final AppPlatform? appPlatform;
  @override
  State<SubscriptionSettingsPage> createState() =>
      _SubscriptionSettingsPageState();
}

class _SubscriptionSettingsPageState extends State<SubscriptionSettingsPage> {
  SubscriptionService get _service => widget.service;
  bool _busy = false;
  final _scrollController = ScrollController();
  final Set<String> _selected = {};
  final _selectionRange = SelectionRangeSnapshot();
  bool _selecting = false;

  void _endSelection() {
    _selecting = false;
    _selected.clear();
    _selectionRange.clear();
  }

  void _updateSelectionRange(DragSelectionUpdate update, List<String> ids) {
    if (!_selecting || _busy) return;
    final next = _selectionRange.apply(update, ids, _selected);
    if (next == null) return;
    setState(
      () => _selected
        ..clear()
        ..addAll(next),
    );
  }

  void _toggleSource(SubscriptionSource source) {
    if (_busy) return;
    setState(() {
      _selecting = true;
      _selectionRange.clear();
      if (!_selected.remove(source.key)) _selected.add(source.key);
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    if (keys.isEmpty) return;
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
        if (mounted) setState(_endSelection);
      });
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: _service, builder: _buildSettings);

  /// 构建订阅设置及订阅源列表，独立判断后台调度与网络计费检测能力。
  Widget _buildSettings(BuildContext context, Widget? _) {
    final sources = _service.sources;
    final orderedIds = sources.map((source) => source.key).toList();
    _selected.retainAll(orderedIds);
    final batchEnabled = !_busy && _selected.isNotEmpty;
    final supportsMeteredDetection = PlatformCapabilities.forPlatform(
      widget.appPlatform ?? AppPlatformDetector.current,
    ).supportsMeteredNetworkDetection;
    final wifiOnlyBackground = _service.wifiOnlyBackgroundRefresh;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) setState(_endSelection);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  tooltip: '退出多选',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_endSelection),
                )
              : null,
          title: Text(_selecting ? '已选 ${_selected.length} 个来源' : '焦点订阅设置'),
          actions: _selecting
              ? [
                  IconButton(
                    tooltip: _selected.length == sources.length ? '取消全选' : '全选',
                    icon: const Icon(Icons.select_all),
                    onPressed: _busy || sources.isEmpty
                        ? null
                        : () => setState(() {
                            _selectionRange.clear();
                            if (_selected.length == sources.length) {
                              _selected.clear();
                            } else {
                              _selected.addAll(orderedIds);
                            }
                          }),
                  ),
                  PopupMenuButton<bool>(
                    tooltip: '批量暂停或恢复',
                    enabled: batchEnabled,
                    icon: const Icon(Icons.pause_circle_outline),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: true, child: Text('暂停所选')),
                      PopupMenuItem(value: false, child: Text('恢复所选')),
                    ],
                    onSelected: (paused) => _action(() async {
                      await _service.pauseSources(Set.of(_selected), paused);
                      if (mounted) setState(_endSelection);
                    }),
                  ),
                  IconButton(
                    tooltip: '删除所选',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: batchEnabled
                        ? () => _deleteSources(Set.of(_selected))
                        : null,
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
            child: DragSelectionRegion(
              controller: _scrollController,
              itemCount: orderedIds.length,
              enabled: _selecting && !_busy,
              checkedAt: (index) => _selected.contains(orderedIds[index]),
              onDragUpdate: (update) =>
                  _updateSelectionRange(update, orderedIds),
              builder: (context, dragging) => ListView(
                controller: _scrollController,
                physics: dragging ? const NeverScrollableScrollPhysics() : null,
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
                    if (_service.backgroundRefreshEnabled ||
                        wifiOnlyBackground ||
                        !supportsMeteredDetection)
                      SwitchListTile(
                        key: const Key(
                          'subscription-wifi-only-background-switch',
                        ),
                        title: const Text('仅在未计量网络后台检查'),
                        value: wifiOnlyBackground,
                        subtitle: Text(
                          supportsMeteredDetection
                              ? '开启后，后台任务仅在确认非计费网络（如不计费 Wi-Fi）时联网检查更新。'
                              : wifiOnlyBackground
                              ? '当前平台暂不支持检测网络计费状态。后台检查运行时，即使连接普通 Wi-Fi，此限制也会阻止联网。请关闭此开关以解除限制。'
                              : '当前平台暂不支持检测网络计费状态，此功能暂不可用。',
                        ),
                        onChanged:
                            _busy ||
                                (!supportsMeteredDetection &&
                                    !wifiOnlyBackground)
                            ? null
                            : (value) {
                                // 不支持检测的平台只允许解除已保存的限制。
                                if (value && !supportsMeteredDetection) return;
                                _action(
                                  () => _service.setWifiOnlyBackgroundRefresh(
                                    value,
                                  ),
                                );
                              },
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
                    '订阅源（${sources.length}/${_service.maxSources}）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (sources.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('UP 主和合集只读取部分内容建立基线。历史导入与更新提醒相互独立。'),
                    ),
                  for (final (index, source) in sources.indexed)
                    DragSelectionTarget(
                      key: ValueKey(source.key),
                      index: index,
                      builder: (context, handleKey) => Card(
                        key: ValueKey('subscription-source-${source.key}'),
                        color: _selected.contains(source.key)
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        child: InkWell(
                          onTap: _busy ? null : () => _openSource(source),
                          onLongPress: _busy || _selecting
                              ? null
                              : () => _toggleSource(source),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_selecting)
                                      SubscriptionSelectionHandle(
                                        handleKey: handleKey,
                                        checked: _selected.contains(source.key),
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
                                            source.kind ==
                                                    SubscriptionKind.creator
                                                ? 'UP主 ${source.mid}'
                                                : 'UGC合集 ${source.seasonId} · UP主 ${source.mid}',
                                          ),
                                          Text(
                                            source.paused
                                                ? '已暂停 · 历史保留'
                                                : _service
                                                          .checkpoint(
                                                            source.key,
                                                          )
                                                          ?.error !=
                                                      null
                                                ? _service
                                                              .checkpoint(
                                                                source.key,
                                                              )
                                                              ?.initialized ==
                                                          true
                                                      ? '更新检查失败 · 可重试此来源'
                                                      : '获取已有内容失败 · 可重试此来源'
                                                : _service
                                                          .checkpoint(
                                                            source.key,
                                                          )
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
                                                                service:
                                                                    _service,
                                                                source: source,
                                                              ),
                                                        ),
                                                      ),
                                                  child: const Text('历史内容'),
                                                ),
                                                if (!source.paused &&
                                                    _service
                                                            .checkpoint(
                                                              source.key,
                                                            )
                                                            ?.error !=
                                                        null)
                                                  TextButton(
                                                    onPressed:
                                                        !_service.enabled ||
                                                            _service
                                                                .refreshing ||
                                                            _busy
                                                        ? null
                                                        : () => _action(
                                                            () => _service
                                                                .retrySource(
                                                                  source.key,
                                                                ),
                                                          ),
                                                    child: const Text('重试此来源'),
                                                  ),
                                                TextButton(
                                                  onPressed: _busy
                                                      ? null
                                                      : () => _action(
                                                          () => _service
                                                              .pauseSource(
                                                                source.key,
                                                                !source.paused,
                                                              ),
                                                        ),
                                                  child: Text(
                                                    source.paused
                                                        ? '恢复订阅'
                                                        : '暂停',
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
                imageVariant: creator
                    ? BilibiliImageVariant.avatar
                    : BilibiliImageVariant.cover16x9,
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
    this.addDirectly = false,
  });
  final bool addDirectly;
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
      final source = widget.source;
      await _service.initialize();
      if (!mounted || source.key != widget.source.key) return;
      if (widget.addDirectly) {
        await _service.addSource(source, enableFocus: true);
        _showMessage('已添加到焦点订阅');
      } else {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              _AddSourceDialog(service: _service, initialSource: source),
        );
      }
    } catch (error) {
      _showMessage(error is StateError ? error.message.toString() : '添加失败，请重试');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _showMessage(String text) {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
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
        tooltip: subscribed
            ? '取消焦点订阅'
            : widget.addDirectly
            ? '添加订阅源'
            : '加入焦点订阅',
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
