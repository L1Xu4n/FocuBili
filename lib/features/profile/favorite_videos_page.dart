import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/account_collection.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_service.dart';

/// 展示一个收藏夹内的只读视频列表，并在用户点击后查询公开详情进入播放器。
class FavoriteVideosPage extends StatefulWidget {
  /// 创建指定收藏夹的视频页面；服务可注入以支持测试和安全替换。
  const FavoriteVideosPage({
    super.key,
    required this.folder,
    this.accountDataService,
    this.bilibiliService,
  });

  /// 当前页面读取的收藏夹基本资料。
  final FavoriteFolder folder;

  /// 可选的只读账号数据服务，未传入时创建默认会话服务。
  final BilibiliAccountDataService? accountDataService;

  /// 可选的公开视频详情服务，未传入时使用默认公开视频查询实现。
  final BilibiliService? bilibiliService;

  /// 创建管理首次读取、分页、刷新和打开播放器状态的页面状态。
  @override
  State<FavoriteVideosPage> createState() => _FavoriteVideosPageState();
}

/// 管理收藏夹内容的读取、分页合并、失败恢复和单视频打开流程。
class _FavoriteVideosPageState extends State<FavoriteVideosPage> {
  late final BilibiliAccountDataService _accountDataService;
  late final BilibiliService _bilibiliService;
  List<FavoriteVideo> _videos = const <FavoriteVideo>[];
  AccountDataPage<FavoriteVideo>? _page;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _openingBvid;

  /// 创建页面服务并在首次进入时读取第 1 页收藏内容。
  @override
  void initState() {
    super.initState();
    _accountDataService =
        widget.accountDataService ?? BilibiliAccountDataService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    unawaited(_loadFirstPage());
  }

  /// 读取收藏夹第 1 页；刷新失败时保留原有已成功显示的视频列表。
  Future<void> _loadFirstPage() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }
    final AccountDataPage<FavoriteVideo> result =
        await _accountDataService.loadFavoriteVideos(widget.folder.mediaId);
    if (!mounted) {
      return;
    }
    final bool keepPreviousList = !result.isSuccess && _videos.isNotEmpty;
    setState(() {
      _isLoading = false;
      if (result.isSuccess) {
        _videos = result.items;
        _page = result;
      } else if (!keepPreviousList) {
        _videos = const <FavoriteVideo>[];
        _page = result;
      }
    });
    if (keepPreviousList) {
      _showMessage(result.message ?? '刷新收藏内容失败，请稍后重试。');
    }
  }

  /// 请求下一页并按 BV 号合并结果；下一页失败不会清空已经显示的内容。
  Future<void> _loadMore() async {
    final AccountDataPage<FavoriteVideo>? currentPage = _page;
    if (_isLoadingMore ||
        currentPage == null ||
        !currentPage.isSuccess ||
        !currentPage.hasMore) {
      return;
    }
    setState(() => _isLoadingMore = true);
    final AccountDataPage<FavoriteVideo> result =
        await _accountDataService.loadFavoriteVideos(
      widget.folder.mediaId,
      page: currentPage.page + 1,
    );
    if (!mounted) {
      return;
    }
    setState(() => _isLoadingMore = false);
    if (!result.isSuccess) {
      _showMessage(result.message ?? '加载更多收藏内容失败，请稍后重试。');
      return;
    }
    setState(() {
      _videos = _mergeVideos(_videos, result.items);
      _page = result;
    });
  }

  /// 按 BV 号去重合并两页数据，避免服务端边界重复时显示两张相同视频卡片。
  List<FavoriteVideo> _mergeVideos(
    List<FavoriteVideo> current,
    List<FavoriteVideo> incoming,
  ) {
    final Set<String> bvids =
        current.map((FavoriteVideo video) => video.bvid).toSet();
    final List<FavoriteVideo> merged = <FavoriteVideo>[...current];
    for (final FavoriteVideo video in incoming) {
      if (bvids.add(video.bvid)) {
        merged.add(video);
      }
    }
    return List<FavoriteVideo>.unmodifiable(merged);
  }

  /// 读取点击视频的公开详情，补齐 cid 和分P后才向播放器路由传递 VideoPreview。
  Future<void> _openVideo(FavoriteVideo video) async {
    if (!video.isAvailable || _openingBvid != null) {
      return;
    }
    setState(() => _openingBvid = video.bvid);
    try {
      final VideoPreview preview =
          await _bilibiliService.lookupVideo(video.bvid);
      if (!mounted) {
        return;
      }
      setState(() => _openingBvid = null);
      Navigator.of(context).pushNamed(AppRoutes.player, arguments: preview);
    } on BilibiliLookupException catch (error) {
      if (mounted) {
        setState(() => _openingBvid = null);
        _showMessage(error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _openingBvid = null);
        _showMessage('无法打开该视频，请稍后重试。');
      }
    }
  }

  /// 显示统一持续三秒的轻量提示，不会替换已有的收藏夹列表状态。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// 将视频总时长格式化为时分秒，供收藏视频卡片的辅助信息展示。
  String _formatDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 99 * 3600 + 3599).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int remainingSeconds = seconds % 60;
    final String minuteText = minutes.toString().padLeft(2, '0');
    final String secondText = remainingSeconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minuteText:$secondText'
        : '$minutes:$secondText';
  }

  /// 创建收藏视频缩略图、网络失败占位图和多分P角标。
  Widget _buildThumbnail(FavoriteVideo video) {
    return SizedBox(
      width: 132,
      height: 82,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (video.coverUrl.isEmpty)
              _buildThumbnailPlaceholder()
            else
              CachedNetworkImage(
                imageUrl: video.coverUrl,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                },
                fit: BoxFit.cover,
                memCacheWidth: 320,
                maxWidthDiskCache: 640,
                fadeInDuration: const Duration(milliseconds: 120),
                placeholder: (BuildContext context, String url) =>
                    _buildThumbnailPlaceholder(),
                errorWidget: (
                  BuildContext context,
                  String url,
                  Object error,
                ) =>
                    _buildThumbnailPlaceholder(),
              ),
            Positioned(
              right: 5,
              bottom: 5,
              child: _buildThumbnailBadge(_formatDuration(video.duration)),
            ),
            if (video.partCount > 1)
              Positioned(
                left: 5,
                bottom: 5,
                child: _buildThumbnailBadge('共 ${video.partCount} P'),
              ),
          ],
        ),
      ),
    );
  }

  /// 创建封面地址缺失或加载失败时使用的本地占位图。
  Widget _buildThumbnailPlaceholder() {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: const Center(
        child: Icon(Icons.play_arrow_rounded, color: Colors.black45),
      ),
    );
  }

  /// 创建缩略图上的半透明文字角标，确保时长与分P信息清晰可读。
  Widget _buildThumbnailBadge(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.72),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    );
  }

  /// 创建所有 AccountDataLoadStatus 对应的说明和重试入口，避免失败显示为空列表。
  Widget _buildStatusState(AccountDataPage<FavoriteVideo> page) {
    final IconData icon;
    switch (page.status) {
      case AccountDataLoadStatus.success:
        icon = Icons.video_library_outlined;
      case AccountDataLoadStatus.signedOut:
      case AccountDataLoadStatus.expired:
        icon = Icons.login_rounded;
      case AccountDataLoadStatus.networkError:
        icon = Icons.wifi_off_rounded;
      case AccountDataLoadStatus.permissionDenied:
        icon = Icons.lock_outline_rounded;
      case AccountDataLoadStatus.missingData:
      case AccountDataLoadStatus.unavailable:
      case AccountDataLoadStatus.malformedData:
        icon = Icons.error_outline_rounded;
    }
    return Center(
      key: Key('favorite-videos-status-${page.status.name}'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44),
            const SizedBox(height: 12),
            Text(
              page.message ?? '暂时无法读取收藏内容，请稍后重试。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('favorite-videos-retry'),
              // 重试按钮函数只重新发起当前收藏夹的第 1 页只读请求。
              onPressed: _isLoading ? null : _loadFirstPage,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建服务成功但没有任何收藏视频时的明确空状态。
  Widget _buildEmptyState() {
    return const Center(
      key: Key('favorite-videos-empty'),
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.video_library_outlined, size: 44),
            SizedBox(height: 12),
            Text('这个收藏夹还没有视频'),
          ],
        ),
      ),
    );
  }

  /// 创建底部的下一页加载器、加载更多按钮或内容结束提示。
  Widget _buildLoadMoreFooter() {
    final AccountDataPage<FavoriteVideo>? page = _page;
    if (page == null || !page.hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: Text('没有更多内容了')),
      );
    }
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: OutlinedButton(
          key: const Key('favorite-videos-load-more'),
          // 加载更多按钮函数只读取该收藏夹的下一页，不改变收藏夹内容。
          onPressed: _loadMore,
          child: const Text('加载更多'),
        ),
      ),
    );
  }

  /// 创建收藏视频卡片列表，失效视频保持可见但不会触发公开详情查询。
  Widget _buildVideoList() {
    return RefreshIndicator(
      // 下拉刷新函数只重新读取第 1 页，不会写入收藏夹或账号数据。
      onRefresh: _loadFirstPage,
      child: ListView.separated(
        key: const Key('favorite-videos-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _videos.length + 1,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) {
          if (index == _videos.length) {
            return _buildLoadMoreFooter();
          }
          final FavoriteVideo video = _videos[index];
          final bool isOpening = _openingBvid == video.bvid;
          return Card(
            key: Key('favorite-video-${video.bvid}'),
            child: ListTile(
              enabled: video.isAvailable,
              isThreeLine: true,
              leading: _buildThumbnail(video),
              title: Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                video.isAvailable
                    ? '${video.ownerName} · ${_formatDuration(video.duration)}'
                    : '${video.ownerName} · 视频已失效，暂不可播放',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: isOpening
                  ? const SizedBox.square(
                      dimension: 24,
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Icon(
                      video.isAvailable
                          ? Icons.play_circle_outline_rounded
                          : Icons.block_rounded,
                    ),
              // 视频点击函数仅在条目可播放时补齐详情并进入播放器。
              onTap: !video.isAvailable || isOpening
                  ? null
                  : () => _openVideo(video),
            ),
          );
        },
      ),
    );
  }

  /// 根据首次加载、失败、空和正常列表状态选择收藏视频页主体。
  Widget _buildBody() {
    if (_isLoading && _page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final AccountDataPage<FavoriteVideo>? page = _page;
    if (page == null) {
      return _buildStatusState(
        AccountDataPage<FavoriteVideo>.unavailable(),
      );
    }
    if (!page.isSuccess) {
      return _buildStatusState(page);
    }
    if (_videos.isEmpty) {
      return _buildEmptyState();
    }
    return _buildVideoList();
  }

  /// 创建收藏夹标题、刷新入口和随状态变化的内容区域。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folder.title),
        actions: <Widget>[
          IconButton(
            // 刷新按钮函数只读取当前收藏夹第 1 页，不写入任何 B 站数据。
            onPressed: _isLoading ? null : () => unawaited(_loadFirstPage()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新收藏内容',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}
