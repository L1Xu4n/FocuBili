import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/router/app_router.dart';
import '../../models/app_favorite.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_service.dart';
import 'app_favorite_video_tile.dart';

/// 展示一个软件收藏夹内保存的全部视频，支持打开播放和移除收藏。
class AppFavoriteDetailPage extends StatefulWidget {
  /// 创建软件收藏夹详情页；服务可注入以支持测试。
  const AppFavoriteDetailPage({
    super.key,
    required this.folder,
    this.favoritesService,
    this.bilibiliService,
  });

  /// 当前展示的软件收藏夹。
  final AppFavoriteFolder folder;

  /// 可选的软件收藏夹服务，未传入时使用设备默认实现。
  final AppFavoritesService? favoritesService;

  /// 可选的公开视频详情服务，用于打开收藏视频前补齐播放数据。
  final BilibiliService? bilibiliService;

  /// 创建管理收藏项读取与移除行为的状态对象。
  @override
  State<AppFavoriteDetailPage> createState() => _AppFavoriteDetailPageState();
}

/// 管理软件收藏夹内视频列表的读取、移除和播放跳转。
class _AppFavoriteDetailPageState extends State<AppFavoriteDetailPage> {
  late final AppFavoritesService _favoritesService;
  late final BilibiliService _bilibiliService;
  List<AppFavoriteItem> _items = const <AppFavoriteItem>[];
  bool _isLoading = true;
  final _searchController = TextEditingController();

  /// Releases the within-folder video search input.
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 初始化服务并在首次进入时读取一次收藏项。
  @override
  void initState() {
    super.initState();
    _favoritesService = widget.favoritesService ?? AppFavoritesService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    unawaited(_loadItems());
  }

  /// 读取收藏项；失败时保留上一次成功显示的数据。
  Future<void> _loadItems() async {
    try {
      final List<AppFavoriteItem> items = await _favoritesService.loadItems(
        widget.folder.id,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _items = items;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// 点击收藏项时先补齐公开视频数据，再进入播放器。
  Future<void> _openVideo(AppFavoriteItem item) async {
    try {
      final preview = await _bilibiliService.lookupVideo(item.bvid);
      if (!mounted) {
        return;
      }
      await Navigator.of(
        context,
      ).pushNamed(AppRoutes.player, arguments: preview);
    } on Object {
      if (mounted) {
        _showMessage('无法打开视频，请检查网络后重试。');
      }
    }
  }

  /// 确认后从软件收藏夹移除指定视频。
  Future<void> _removeItem(AppFavoriteItem item) async {
    try {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('移除收藏'),
          content: Text('将把“${item.title}”从“${widget.folder.name}”中移除。'),
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
      if (confirmed != true || !mounted) {
        return;
      }
      final bool removed = await _favoritesService.removeItem(
        widget.folder.id,
        item.bvid,
      );
      if (!mounted) {
        return;
      }
      if (!removed) {
        _showMessage('移除失败，请稍后重试。');
        return;
      }
      await _loadItems();
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// 创建单个收藏项卡片，点击进入播放器并提供移除入口。
  Widget _buildItemCard(AppFavoriteItem item) {
    return AppFavoriteVideoTile(
      key: Key('app-favorite-item-${item.bvid}'),
      item: item,
      loadPartCount: () => _favoritesService.resolvePartCount(
        item,
        _bilibiliService.lookupVideo,
      ),
      onTap: () => unawaited(_openVideo(item)),
      onRemove: () => unawaited(_removeItem(item)),
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
    final items = _items
        .where((item) => item.matchesQuery(_searchController.text))
        .toList();
    if (items.isEmpty) return const Center(child: Text('没有匹配的收藏视频'));
    return RefreshIndicator(
      onRefresh: _loadItems,
      child: AdaptiveTwoColumnList(
        key: const Key('app-favorite-items-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: items.length,
        mainAxisSpacing: 8,
        itemBuilder: (BuildContext context, int index) {
          return _buildItemCard(items[index]);
        },
      ),
    );
  }

  /// 创建收藏夹详情页标题和内容区域。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.folder.name)),
      body: AdaptivePageFrame(
        maxWidth: 1180,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                key: const Key('app-favorite-videos-search'),
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '搜索收藏视频、UP 主或 BV 号',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(_searchController.clear),
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
    );
  }
}
