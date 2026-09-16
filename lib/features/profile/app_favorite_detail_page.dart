import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/router/app_router.dart';
import '../../models/app_favorite.dart';
import '../../models/video_preview.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_service.dart';

/// 展示一个软件收藏夹内的视频列表，支持进入播放器、移除和空状态提示。
class AppFavoriteDetailPage extends StatefulWidget {
  /// 创建指定软件收藏夹的详情页；服务可注入以支持测试和安全替换。
  const AppFavoriteDetailPage({
    super.key,
    required this.folder,
    this.favoritesService,
    this.accountDataService,
    this.bilibiliService,
  });

  /// 当前页面读取的软件收藏夹资料。
  final AppFavoriteFolder folder;

  /// 可选的软件收藏夹服务，未传入时使用设备默认存储。
  final AppFavoritesService? favoritesService;

  /// 可选的 B 站账号数据服务，保留给后续从账号导入时复用。
  final BilibiliAccountDataService? accountDataService;

  /// 可选的公开视频详情服务，未传入时使用默认公开视频查询实现。
  final BilibiliService? bilibiliService;

  /// 创建管理条目读取、打开播放器和移除行为的状态对象。
  @override
  State<AppFavoriteDetailPage> createState() => _AppFavoriteDetailPageState();
}

/// 管理软件收藏夹内容的读取、打开播放器和移除操作。
class _AppFavoriteDetailPageState extends State<AppFavoriteDetailPage> {
  late final AppFavoritesService _favoritesService;
  late final BilibiliService _bilibiliService;
  List<AppFavoriteItem> _items = const <AppFavoriteItem>[];
  bool _isLoading = true;
  String? _openingBvid;

  /// 创建页面服务并在首次进入时读取一次本机收藏条目。
  @override
  void initState() {
    super.initState();
    _favoritesService = widget.favoritesService ?? AppFavoritesService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    unawaited(_loadItems());
  }

  /// 读取本收藏夹全部条目，失败时保留上一次成功显示的数据。
  Future<void> _loadItems() async {
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
  }

  /// 查询点击视频的公开详情并进入播放器；失败时保留列表并提示原因。
  Future<void> _openVideo(AppFavoriteItem item) async {
    if (_openingBvid != null) {
      return;
    }
    setState(() => _openingBvid = item.bvid);
    try {
      final VideoPreview preview = await _bilibiliService.lookupVideo(
        item.bvid,
      );
      if (!mounted) {
        return;
      }
      setState(() => _openingBvid = null);
      await Navigator.of(
        context,
      ).pushNamed(AppRoutes.player, arguments: preview);
    } on BilibiliLookupException catch (error) {
      if (mounted) {
        setState(() => _openingBvid = null);
        _showMessage(error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _openingBvid = null);
        _showMessage('暂时无法打开这支视频，请稍后重试。');
      }
    }
  }

  /// 确认后从本收藏夹移除一条视频。
  Future<void> _removeItem(AppFavoriteItem item) async {
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
    setState(() {
      _items = _items
          .where((AppFavoriteItem existing) => existing.bvid != item.bvid)
          .toList(growable: false);
    });
    _showMessage('已从收藏夹移除');
  }

  /// 显示统一持续三秒的轻量提示。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 创建条目封面缩略图，失败时显示固定占位图标。
  Widget _buildThumbnail(AppFavoriteItem item) {
    return SizedBox(
      width: 112,
      height: 70,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: item.coverUrl.isEmpty
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.play_circle_outline_rounded),
              )
            : CachedNetworkImage(
                imageUrl: item.coverUrl,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                },
                fit: BoxFit.cover,
                memCacheWidth: 256,
                maxWidthDiskCache: 512,
                fadeInDuration: const Duration(milliseconds: 120),
                placeholder: (BuildContext context, String url) => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                errorWidget: (BuildContext context, String url, Object error) =>
                    ColoredBox(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
              ),
      ),
    );
  }

  /// 创建单个收藏条目卡片，点击进入播放器并提供移除操作。
  Widget _buildItemCard(AppFavoriteItem item) {
    return Card(
      key: Key('app-favorite-item-${item.bvid}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openingBvid == null ? () => _openVideo(item) : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              _buildThumbnail(item),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.ownerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (item.durationText.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        item.durationText,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (item.sourceLabel != null &&
                        item.sourceLabel!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        item.sourceLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: Key('remove-app-favorite-${item.bvid}'),
                tooltip: '移除',
                icon: const Icon(Icons.remove_circle_outline_rounded),
                onPressed: () => unawaited(_removeItem(item)),
              ),
            ],
          ),
        ),
      ),
    );
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
              Icon(Icons.star_outline_rounded, size: 44),
              SizedBox(height: 12),
              Text('收藏夹还是空的'),
              SizedBox(height: 6),
              Text('在看视频时点收藏，或回到列表页从 B 站账号导入', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return AdaptiveTwoColumnList(
      key: const Key('app-favorite-items-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _items.length,
      mainAxisSpacing: 8,
      itemBuilder: (BuildContext context, int index) {
        return _buildItemCard(_items[index]);
      },
    );
  }

  /// 创建收藏夹详情页标题和条目列表。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.folder.name)),
      body: AdaptivePageFrame(maxWidth: 1180, child: _buildBody()),
    );
  }
}
