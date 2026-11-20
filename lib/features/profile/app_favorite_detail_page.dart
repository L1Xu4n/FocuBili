import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/router/app_router.dart';
import '../../core/widgets/drag_selection_region.dart';
import '../../models/app_favorite.dart';
import '../../models/playback_queue.dart';
import '../../models/public_profile.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/learning_list_service.dart';
import '../learning/learning_add_sheet.dart';
import 'app_favorite_reorder.dart';
import 'app_favorite_video_tile.dart';
import 'local_video_list_selection.dart';

/// 展示一个软件收藏夹内保存的全部视频，支持打开播放和移除收藏。
class AppFavoriteDetailPage extends StatefulWidget {
  /// 创建软件收藏夹详情页；服务可注入以支持测试。
  const AppFavoriteDetailPage({
    super.key,
    required this.folder,
    this.favoritesService,
    this.bilibiliService,
    this.learningService,
  });

  /// 当前展示的软件收藏夹。
  final AppFavoriteFolder folder;

  /// 可选的软件收藏夹服务，未传入时使用设备默认实现。
  final AppFavoritesService? favoritesService;

  /// 可选的公开视频详情服务，用于打开收藏视频前补齐播放数据。
  final BilibiliService? bilibiliService;

  /// Learning-list backend; the add sheet writes only after confirmation.
  final LearningListService? learningService;

  /// 创建管理收藏项读取与移除行为的状态对象。
  @override
  State<AppFavoriteDetailPage> createState() => _AppFavoriteDetailPageState();
}

/// 管理软件收藏夹内视频列表的读取、移除和播放跳转。
class _AppFavoriteDetailPageState extends State<AppFavoriteDetailPage> {
  late final AppFavoritesService _favoritesService;
  late final BilibiliService _bilibiliService;
  late final LearningListService _learningService;
  List<AppFavoriteItem> _items = const <AppFavoriteItem>[];
  bool _isLoading = true;
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _selection = LocalVideoListSelection();
  List<AppFavoriteItem> _visibleItems = const [];
  bool _removing = false;
  bool _reordering = false;
  bool _addingToLearning = false;
  bool get _busy => _removing || _reordering || _addingToLearning;
  int _loadGeneration = 0;
  int _openGeneration = 0;

  /// Releases the within-folder video search input.
  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 初始化服务并在首次进入时读取一次收藏项。
  @override
  void initState() {
    super.initState();
    _favoritesService = widget.favoritesService ?? AppFavoritesService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    _learningService = widget.learningService ?? LearningListService();
    unawaited(_loadItems());
  }

  @override
  void didUpdateWidget(covariant AppFavoriteDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder.id != widget.folder.id) {
      ++_openGeneration;
      _selection.end();
      _searchController.clear();
      _removing = false;
      _reordering = false;
      _addingToLearning = false;
      _items = const [];
      _updateVisibleItems();
      _isLoading = true;
      unawaited(_loadItems());
    }
  }

  void _updateVisibleItems() {
    _visibleItems = _items
        .where((item) => item.matchesQuery(_searchController.text))
        .toList(growable: false);
    _selection.project(_visibleItems.map((item) => item.bvid));
  }

  void _startSelection([String? anchor]) {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      ++_openGeneration;
      _selection.start(anchor);
    });
  }

  /// 读取收藏项；失败时保留上一次成功显示的数据。
  Future<void> _loadItems() async {
    final generation = ++_loadGeneration;
    try {
      final List<AppFavoriteItem> items = await _favoritesService.loadItems(
        widget.folder.id,
      );
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _isLoading = false;
        _items = items;
        if (items.isEmpty) _selection.end();
        _updateVisibleItems();
      });
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  Future<void> _reorderItems(List<String> ids) async {
    if (_busy ||
        _selection.active ||
        _searchController.text.trim().isNotEmpty) {
      return;
    }
    final folderId = widget.folder.id;
    setState(() {
      _reordering = true;
      ++_openGeneration;
    });
    try {
      final saved = await _favoritesService.reorderItems(folderId, ids);
      if (!mounted || widget.folder.id != folderId) return;
      if (!saved) {
        _showMessage('未能保存视频顺序，请刷新后重试。');
        return;
      }
      await _loadItems();
    } catch (_) {
      if (mounted && widget.folder.id == folderId) {
        _showMessage('未能保存视频顺序，请重试。');
      }
    } finally {
      if (mounted && widget.folder.id == folderId) {
        setState(() => _reordering = false);
      }
    }
  }

  /// 点击收藏项时先补齐公开视频数据，再进入播放器。
  Future<void> _openVideo(AppFavoriteItem item) async {
    final generation = ++_openGeneration;
    try {
      final preview = await _bilibiliService.lookupVideo(item.bvid);
      if (!mounted || generation != _openGeneration || _busy) {
        return;
      }
      await Navigator.of(context).pushNamed(
        AppRoutes.player,
        arguments: PlayerLaunchRequest(
          preview,
          PlaybackQueue(
            title: widget.folder.name,
            items: _visibleItems.map(
              (entry) =>
                  PlaybackQueueItem(bvid: entry.bvid, title: entry.title),
            ),
          ),
        ),
      );
    } on Object {
      if (mounted && generation == _openGeneration && !_busy) {
        _showMessage('无法打开视频，请检查网络后重试。');
      }
    }
  }

  /// Use the shared picker for real part IDs and optional subject folders.
  Future<void> _addToLearning() async {
    if (_busy || !_selection.active) return;
    final selectedIds = {..._selection.ids};
    final selected = [
      for (final item in _visibleItems)
        if (selectedIds.contains(item.bvid))
          CreatorVideo(
            bvid: item.bvid,
            title: item.title,
            coverUrl: item.coverUrl,
            duration: Duration.zero,
          ),
    ];
    if (selected.isEmpty) return;

    final generation = ++_openGeneration;
    setState(() => _addingToLearning = true);
    bool isCurrent() =>
        mounted &&
        generation == _openGeneration &&
        _selection.active &&
        _selection.ids.length == selectedIds.length &&
        _selection.ids.containsAll(selectedIds);
    try {
      final result = await LearningAddSheet.showSelectedVideos(
        context,
        items: selected,
        canConfirm: isCurrent,
        videoService: _bilibiliService,
        service: _learningService,
      );
      if (result == null || !isCurrent()) return;
      setState(_selection.end);
      final added = result.addedIds.length;
      final existing = result.existingIds.length;
      _showMessage(
        added == 0
            ? '学习清单中已有 $existing 项'
            : '已添加到学习清单：$added 项${existing == 0 ? '' : '，已有 $existing 项'}',
      );
    } catch (_) {
      if (isCurrent()) _showMessage('未能加入学习清单，请重试。');
    } finally {
      if (mounted && generation == _openGeneration) {
        setState(() => _addingToLearning = false);
      }
    }
  }

  /// Removes the selected videos from the current folder only.
  Future<void> _removeItems() async {
    if (_busy) return;
    final folder = widget.folder;
    final bvids = {..._selection.ids};
    if (bvids.isEmpty) return;
    setState(() {
      _removing = true;
      ++_openGeneration;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('移除所选收藏'),
          content: Text(
            '将把所选 ${bvids.length} 个视频从“${folder.name}”中移除，不影响其他收藏夹。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('移除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || widget.folder.id != folder.id) {
        return;
      }
      final removed = await _favoritesService.removeItems(folder.id, bvids);
      if (!mounted || widget.folder.id != folder.id) return;
      if (removed == null) {
        _showMessage('移除失败，请稍后重试。');
        return;
      }
      await _loadItems();
      if (mounted && widget.folder.id == folder.id) {
        setState(_selection.end);
      }
    } catch (_) {
      if (mounted && widget.folder.id == folder.id) {
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    } finally {
      if (mounted && widget.folder.id == folder.id) {
        setState(() => _removing = false);
      }
    }
  }

  Widget _buildItemCard(
    AppFavoriteItem item,
    Key handleKey,
    Widget? reorderHandle,
  ) {
    void toggle() => setState(() => _selection.toggle(item.bvid));
    return AppFavoriteVideoTile(
      key: Key('app-favorite-item-${item.bvid}'),
      item: item,
      loadPartCount: () => _favoritesService.resolvePartCount(
        item,
        _bilibiliService.lookupVideo,
      ),
      onTap: _busy
          ? null
          : _selection.active
          ? toggle
          : () => unawaited(_openVideo(item)),
      onLongPress: _selection.active || _busy
          ? null
          : () => _startSelection(item.bvid),
      reorderHandle: reorderHandle,
      selectionControl: _selection.active
          ? _selection.checkbox(
              handleKey: handleKey,
              id: item.bvid,
              title: item.title,
              onToggle: _busy ? null : toggle,
            )
          : null,
    );
  }

  /// 显示统一轻量提示。
  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 根据加载状态和空数据创建页面主体。
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(
        key: Key('app-favorite-detail-empty'),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.bookmark_add_outlined, size: 44),
              SizedBox(height: 12),
              Text('这个收藏夹还是空的'),
              SizedBox(height: 6),
              Text('在看视频时点击“软件收藏”即可加入', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (_visibleItems.isEmpty) {
      return const Center(child: Text('没有匹配的收藏视频'));
    }
    return _selection.region(
      controller: _scrollController,
      busy: _busy,
      setState: setState,
      builder: (context, dragging) => RefreshIndicator(
        notificationPredicate: (notification) =>
            !_selection.active && notification.depth == 0,
        onRefresh: _loadItems,
        child: AppFavoriteReorder(
          ids: [for (final item in _visibleItems) item.bvid],
          enabled:
              !_selection.active &&
              !_busy &&
              _searchController.text.trim().isEmpty,
          onDragStarted: () => ++_openGeneration,
          onReorder: (ids) => unawaited(_reorderItems(ids)),
          builder: (context, reorder) => AdaptiveTwoColumnList(
            key: const Key('app-favorite-items-list'),
            controller: _scrollController,
            physics: dragging
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: _visibleItems.length,
            mainAxisSpacing: 8,
            itemBuilder: (context, index) {
              final item = _visibleItems[index];
              return DragSelectionTarget(
                key: ValueKey(item.bvid),
                index: index,
                builder: (context, handleKey) => reorder.row(
                  context: context,
                  id: item.bvid,
                  title: item.title,
                  handleKey: Key('reorder-app-favorite-item-${item.bvid}'),
                  builder: (handle) => _buildItemCard(item, handleKey, handle),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    final selecting = _selection.active;
    final canAct = !_busy && _selection.ids.isNotEmpty;
    return AppBar(
      leading: selecting
          ? IconButton(
              tooltip: '退出多选',
              onPressed: _busy ? null : () => setState(_selection.end),
              icon: const Icon(Icons.close_rounded),
            )
          : null,
      title: Text(
        selecting ? '已选 ${_selection.ids.length} 项' : widget.folder.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (selecting) ...[
          IconButton(
            tooltip: '添加到学习清单',
            onPressed: canAct ? () => unawaited(_addToLearning()) : null,
            icon: const Icon(Icons.playlist_add_rounded),
          ),
          IconButton(
            tooltip: '移除所选',
            onPressed: canAct ? () => unawaited(_removeItems()) : null,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ] else if (_visibleItems.isNotEmpty)
          IconButton(
            tooltip: '多选',
            onPressed: _busy ? null : _startSelection,
            icon: const Icon(Icons.checklist_rounded),
          ),
      ],
    );
  }

  /// 创建收藏夹详情页标题和内容区域。
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selection.active,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && _selection.active && !_busy) {
          setState(_selection.end);
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: AdaptivePageFrame(
          maxWidth: 1180,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextField(
                  key: const Key('app-favorite-videos-search'),
                  controller: _searchController,
                  enabled: !_busy,
                  onChanged: (_) => setState(_updateVisibleItems),
                  decoration: InputDecoration(
                    hintText: '搜索收藏视频、UP 主或 BV 号',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空搜索',
                            icon: const Icon(Icons.close),
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _searchController.clear();
                                    _updateVisibleItems();
                                  }),
                          ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.bookmark_rounded, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '共 ${_items.length} 个视频',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }
}
