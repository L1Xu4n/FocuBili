import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/public_profile.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';

/// 展示一个 UGC 合集中的独立视频列表，不把它解释为单视频分P。
class CollectionDetailPage extends StatefulWidget {
  /// 创建合集详情页，并允许测试注入公开内容与视频详情服务。
  const CollectionDetailPage({
    super.key,
    required this.collection,
    this.publicContentService,
    this.videoService,
  });

  final CreatorCollection collection;
  final BilibiliPublicContentService? publicContentService;
  final BilibiliService? videoService;

  /// 从视频详情自带的 UGC 合集模型创建统一合集详情页。
  factory CollectionDetailPage.fromVideoCollection({
    Key? key,
    required VideoCollection collection,
    BilibiliPublicContentService? publicContentService,
    BilibiliService? videoService,
  }) {
    return CollectionDetailPage(
      key: key,
      collection: CreatorCollection(
        id: collection.id,
        ownerMid: collection.ownerMid,
        title: collection.title,
        coverUrl: collection.coverUrl,
        description: collection.description,
        totalCount: collection.totalCount,
        previewVideos: collection.entries
            .map(
              (VideoCollectionEntry entry) => CreatorVideo(
                bvid: entry.bvid,
                title: entry.title,
                coverUrl: entry.thumbnailUrl,
                duration: entry.duration,
                publishedAt: entry.publishedAt,
                stats: entry.stats,
              ),
            )
            .toList(growable: false),
      ),
      publicContentService: publicContentService,
      videoService: videoService,
    );
  }

  /// 创建负责分页加载和打开视频的合集详情状态。
  @override
  State<CollectionDetailPage> createState() => _CollectionDetailPageState();
}

/// 管理合集分页、错误恢复以及点击视频后的详情查询。
class _CollectionDetailPageState extends State<CollectionDetailPage> {
  late final BilibiliPublicContentService _publicContentService;
  late final BilibiliService _videoService;
  final ScrollController _scrollController = ScrollController();
  List<CreatorVideo> _videos = const <CreatorVideo>[];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  String? _errorMessage;
  String? _openingBvid;

  /// 初始化服务、滚动监听，并读取合集第一页。
  @override
  void initState() {
    super.initState();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _scrollController.addListener(_loadMoreNearBottom);
    unawaited(_loadFirstPage());
  }

  /// 移除滚动监听并释放控制器。
  @override
  void dispose() {
    _scrollController
      ..removeListener(_loadMoreNearBottom)
      ..dispose();
    super.dispose();
  }

  /// 首次或刷新时读取合集第一页，失败时仍保留接口自带的预览视频。
  Future<void> _loadFirstPage() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final CreatorContentPage<CreatorVideo> result =
          await _publicContentService.loadCollectionVideos(
        widget.collection.ownerMid,
        widget.collection.id,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _videos = result.items;
        _page = result.page;
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _videos = widget.collection.previewVideos;
        _page = 1;
        _hasMore = false;
        _loading = false;
        _errorMessage = error.toString();
      });
    }
  }

  /// 滚动接近底部时自动加载下一页合集视频。
  void _loadMoreNearBottom() {
    if (_scrollController.position.extentAfter < 420) {
      unawaited(_loadMore());
    }
  }

  /// 读取下一页并按 BV 号去重合并，失败时保留已有列表。
  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final CreatorContentPage<CreatorVideo> result =
          await _publicContentService.loadCollectionVideos(
        widget.collection.ownerMid,
        widget.collection.id,
        page: _page + 1,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _videos = _mergeVideos(_videos, result.items);
        _page = result.page;
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _loadingMore = false);
      _showMessage('加载更多失败：$error');
    }
  }

  /// 按 BV 号合并视频页，避免接口分页边界重复卡片。
  List<CreatorVideo> _mergeVideos(
    List<CreatorVideo> current,
    List<CreatorVideo> incoming,
  ) {
    final Set<String> bvids =
        current.map((CreatorVideo video) => video.bvid).toSet();
    return List<CreatorVideo>.unmodifiable(<CreatorVideo>[
      ...current,
      ...incoming.where((CreatorVideo video) => bvids.add(video.bvid)),
    ]);
  }

  /// 查询点击视频的完整分P信息后打开播放器，避免用合集卡片的轻量数据直接播放。
  Future<void> _openVideo(CreatorVideo item) async {
    if (_openingBvid != null) {
      return;
    }
    setState(() => _openingBvid = item.bvid);
    try {
      final VideoPreview video = await _videoService.lookupVideo(item.bvid);
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushNamed(
        AppRoutes.player,
        arguments: video,
      );
    } catch (error) {
      if (mounted) {
        _showMessage('无法打开视频：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _openingBvid = null);
      }
    }
  }

  /// 显示三秒轻量提示，不覆盖当前合集列表。
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

  /// 创建合集封面、标题、简介和真实视频数量头部。
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: _buildCover(
              widget.collection.coverUrl,
              width: 132,
              height: 84,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  widget.collection.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '共 ${widget.collection.totalCount} 支独立视频',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (widget.collection.description.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    widget.collection.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 创建带缓存和错误占位的 B 站封面。
  Widget _buildCover(
    String url, {
    required double width,
    required double height,
  }) {
    if (url.isEmpty) {
      return _buildCoverPlaceholder(width, height);
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: const <String, String>{
        'Referer': 'https://www.bilibili.com/',
      },
      width: width,
      height: height,
      fit: BoxFit.cover,
      memCacheWidth: 480,
      maxWidthDiskCache: 720,
      placeholder: (BuildContext context, String value) =>
          _buildCoverPlaceholder(width, height),
      errorWidget: (BuildContext context, String value, Object error) =>
          _buildCoverPlaceholder(width, height),
    );
  }

  /// 创建封面加载中或失败时的固定尺寸占位。
  Widget _buildCoverPlaceholder(double width, double height) {
    return SizedBox(
      width: width,
      height: height,
      child: const ColoredBox(
        color: Colors.black12,
        child: Icon(Icons.video_library_outlined),
      ),
    );
  }

  /// 将时长格式化为 mm:ss 或 h:mm:ss。
  String _formatDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 1 << 31).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 创建单支合集视频卡片，点击后打开这支独立视频而不是切换分P。
  Widget _buildVideoTile(CreatorVideo item) {
    final bool opening = _openingBvid == item.bvid;
    return Card(
      key: Key('collection-video-${item.bvid}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 合集视频点击函数查询完整详情后进入播放器。
        onTap: opening ? null : () => unawaited(_openVideo(item)),
        child: Row(
          children: <Widget>[
            Stack(
              alignment: Alignment.bottomRight,
              children: <Widget>[
                _buildCover(item.coverUrl, width: 150, height: 92),
                Container(
                  margin: const EdgeInsets.all(6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  color: Colors.black54,
                  child: Text(
                    _formatDuration(item.duration),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (opening)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.play_arrow_rounded),
              ),
          ],
        ),
      ),
    );
  }

  /// 根据加载、错误、空列表和成功状态创建合集主体。
  Widget _buildBody() {
    if (_loading && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_videos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.video_library_outlined, size: 48),
              const SizedBox(height: 12),
              Text(_errorMessage ?? '这个合集暂时没有可播放视频'),
              const SizedBox(height: 12),
              OutlinedButton(
                // 重试按钮函数重新读取合集第一页。
                onPressed: _loadFirstPage,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      // 下拉刷新函数重新读取合集第一页。
      onRefresh: _loadFirstPage,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _videos.length + 2,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 10),
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return _buildHeader();
          }
          if (index == _videos.length + 1) {
            return _loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const SizedBox(height: 8);
          }
          return _buildVideoTile(_videos[index - 1]);
        },
      ),
    );
  }

  /// 创建带刷新入口的 UGC 合集详情页。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.collection.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            // 顶部刷新函数重新读取合集第一页。
            onPressed: _loading ? null : () => unawaited(_loadFirstPage()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新合集',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}
