import 'dart:async';

import 'package:focubili/features/common/app_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/router/app_router.dart';
import '../../core/widgets/drag_selection_region.dart';
import '../common/video_batch_actions.dart';
import '../common/video_list_selection.dart';
import '../../models/public_profile.dart';
import '../../models/subscription.dart';
import '../../models/video_preview.dart';
import '../../models/playback_queue.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/learning_list_service.dart';
import '../../services/subscription_service.dart';
import '../learning/learning_add_sheet.dart';
import '../subscriptions/subscription_updates_page.dart';

/// 展示一个 UGC 合集中的独立视频列表，不把它解释为单视频分P。
class CollectionDetailPage extends StatefulWidget {
  /// 创建合集详情页，并允许测试注入公开内容与视频详情服务。
  const CollectionDetailPage({
    super.key,
    required this.collection,
    this.publicContentService,
    this.videoService,
    this.learningListService,
    this.subscriptionService,
    this.batchActions,
  });

  final SubscriptionService? subscriptionService;
  final VideoBatchActions? batchActions;
  final CreatorCollection collection;
  final BilibiliPublicContentService? publicContentService;
  final BilibiliService? videoService;
  final LearningListService? learningListService;

  /// 从视频详情自带的 UGC 合集模型创建统一合集详情页。
  factory CollectionDetailPage.fromVideoCollection({
    Key? key,
    required VideoCollection collection,
    BilibiliPublicContentService? publicContentService,
    BilibiliService? videoService,
    LearningListService? learningListService,
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
      learningListService: learningListService,
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
  late final LearningListService _learningListService;
  final VideoListSelection _selection = VideoListSelection();
  late final VideoBatchActions _batchActions;
  bool _batchBusy = false;
  int _dataGeneration = 0;
  final ScrollController _scrollController = ScrollController();
  List<CreatorVideo> _videos = const <CreatorVideo>[];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  bool _needsPageTap = false;
  String? _errorMessage;
  String? _openingBvid;
  String? _addingBvid;
  Set<String> _learningListBvids = const <String>{};

  /// 初始化服务、滚动监听，并读取合集第一页。
  @override
  void initState() {
    super.initState();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _learningListService = widget.learningListService ?? LearningListService();
    _batchActions =
        widget.batchActions ??
        VideoBatchActions(
          learningService: _learningListService,
          videoService: _videoService,
        );
    _scrollController.addListener(_loadMoreNearBottom);
    unawaited(_loadFirstPage());
    unawaited(_loadLearningListMembership());
  }

  /// 读取本机学习清单中的 BV 集合，供合集条目右侧图标显示当前状态。
  Future<void> _loadLearningListMembership() async {
    final entries = await _learningListService.loadEntries();
    if (mounted) {
      setState(() {
        _learningListBvids = entries.map((entry) => entry.bvid).toSet();
      });
    }
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
    if (_selection.active) return;
    final generation = ++_dataGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _needsPageTap = false;
        _errorMessage = null;
      });
    }
    try {
      final CreatorContentPage<CreatorVideo> result =
          await _publicContentService.loadCollectionVideos(
            widget.collection.ownerMid,
            widget.collection.id,
          );
      if (!mounted || generation != _dataGeneration) {
        return;
      }
      setState(() {
        _videos = _mergeVideos(const [], result.items);
        _page = result.page;
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _dataGeneration) {
        return;
      }
      setState(() {
        _videos = _mergeVideos(const [], widget.collection.previewVideos);
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

  /// 偏移分页可能整页重合。有限地越过重复页；不把它误认作合集结束。
  Future<void> _loadMore({bool manual = false}) async {
    if (_loading || _loadingMore || !_hasMore || (_needsPageTap && !manual)) {
      return;
    }
    final generation = _dataGeneration;
    setState(() {
      _loadingMore = true;
      _needsPageTap = false;
    });
    try {
      const maxAutomaticPages = 3;
      for (var attempt = 0; attempt < maxAutomaticPages; attempt++) {
        final next = _page + 1;
        final result = await _publicContentService.loadCollectionVideos(
          widget.collection.ownerMid,
          widget.collection.id,
          page: next,
        );
        if (!mounted || generation != _dataGeneration) return;
        if (result.page != next) {
          // 服务端页码停滞/跳号，保留最后一个可靠游标，允许显式重试。
          setState(() => _needsPageTap = true);
          return;
        }
        final size = _videos.length;
        setState(() {
          _videos = _mergeVideos(_videos, result.items);
          _page = result.page;
          _hasMore = result.hasMore;
        });
        if (!_hasMore || _videos.length > size) return;
      }
      // 服务端仍提示有后页。限制本次请求数，由用户决定是否继续查找。
      setState(() => _needsPageTap = true);
    } catch (error) {
      if (mounted && generation == _dataGeneration) {
        setState(() => _needsPageTap = true);
        _showMessage('加载更多失败：$error');
      }
    } finally {
      if (mounted && generation == _dataGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  /// 按 BV 号合并视频页，避免接口分页边界重复卡片。
  List<CreatorVideo> _mergeVideos(
    List<CreatorVideo> current,
    List<CreatorVideo> incoming,
  ) {
    final Set<String> bvids = current
        .map((CreatorVideo video) => video.bvid)
        .toSet();
    return List<CreatorVideo>.unmodifiable(<CreatorVideo>[
      ...current,
      ...incoming.where(
        (CreatorVideo video) => video.bvid.isNotEmpty && bvids.add(video.bvid),
      ),
    ]);
  }

  /// 查询点击视频的完整分P信息后打开播放器，避免用合集卡片的轻量数据直接播放。
  Future<void> _openVideo(CreatorVideo item) async {
    if (_openingBvid != null || _addingBvid != null) {
      return;
    }
    setState(() => _openingBvid = item.bvid);
    try {
      final VideoPreview video = await _videoService.lookupVideo(item.bvid);
      if (!mounted) {
        return;
      }
      final service = _publicContentService;
      final collection = widget.collection;
      final queue = PlaybackQueue(
        title: collection.title,
        items: _videos.map(
          (entry) => PlaybackQueueItem(bvid: entry.bvid, title: entry.title),
        ),
        nextPage: _page + 1,
        hasMore: _hasMore,
        // 保持当前合集来源，后续分页不依赖列表页面生命周期。
        loadPage: (page) async {
          final result = await service.loadCollectionVideos(
            collection.ownerMid,
            collection.id,
            page: page,
          );
          return PlaybackQueuePage(
            result.items
                .map(
                  (entry) =>
                      PlaybackQueueItem(bvid: entry.bvid, title: entry.title),
                )
                .toList(),
            hasMore: result.hasMore,
          );
        },
      );
      await Navigator.of(context).pushNamed(
        AppRoutes.player,
        arguments: PlayerLaunchRequest(video, queue),
      );
      await _loadLearningListMembership();
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
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// Opens explicit P selection even when another P of the BV already exists.
  Future<void> _toggleVideoLearningList(CreatorVideo item) async {
    if (_openingBvid != null || _addingBvid != null) return;
    setState(() => _addingBvid = item.bvid);
    try {
      final video = await _videoService.lookupVideo(item.bvid);
      if (!mounted) return;
      setState(() => _addingBvid = null);
      final result = await LearningAddSheet.show(
        context,
        video: video,
        service: _learningListService,
      );
      if (result == null || !mounted) return;
      await _loadLearningListMembership();
      if (mounted) _showMessage('已加入所选分 P，已有进度已保留。');
    } catch (_) {
      if (mounted) _showMessage('详情读取或保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _addingBvid = null);
    }
  }

  Future<void> _saveSelected() async {
    if (_batchBusy || _selection.ids.isEmpty) return;
    final items = _videos
        .where((e) => _selection.ids.contains(e.bvid))
        .toList(growable: false);
    setState(() => _batchBusy = true);
    try {
      final saved = await _batchActions.run(
        context,
        videos: items,
        ownerName: widget.collection.ownerName,
      );
      if (!mounted) return;
      if (saved) {
        setState(_selection.end);
        await _loadLearningListMembership();
      }
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  // 放大文字时把空间留给可区分课程的标题，而不是装饰性缩略图。
  bool get _largeTypeOnPhone =>
      MediaQuery.sizeOf(context).width < 600 &&
      MediaQuery.textScalerOf(context).scale(14) >= 21;

  /// 创建合集封面、标题、简介和真实视频数量头部。
  Widget _buildHeader() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildCover(
                  widget.collection.coverUrl,
                  width: _largeTypeOnPhone ? 78 : 122,
                  height: _largeTypeOnPhone ? 52 : 76,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.collection.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.collection.totalCount} 支视频',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (widget.collection.description.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              widget.collection.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('视频列表', style: theme.textTheme.titleSmall)),
              if (_selection.active)
                const SizedBox(height: 48)
              else
                TextButton.icon(
                  key: const Key('select-collection-videos'),
                  onPressed: _addingBvid != null || _openingBvid != null
                      ? null
                      : () => setState(() => _selection.start()),
                  icon: const Icon(Icons.checklist_rounded, size: 20),
                  label: const Text('多选'),
                ),
            ],
          ),
          Divider(height: 1, color: colors.outlineVariant),
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
    return AppNetworkImage(
      imageUrl: url,
      httpHeaders: const <String, String>{
        'Referer': 'https://www.bilibili.com/',
      },
      width: width,
      height: height,
      fit: BoxFit.cover,
      memCacheWidth: 480,
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
  Widget _buildVideoTile(CreatorVideo item, Key handleKey) {
    final bool opening = _openingBvid == item.bvid;
    final bool adding = _addingBvid == item.bvid;
    final bool added = _learningListBvids.contains(item.bvid);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      key: Key('collection-video-${item.bvid}'),
      color: _selection.ids.contains(item.bvid)
          ? colors.secondaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 合集视频点击函数查询完整详情后进入播放器。
        onTap: _batchBusy || opening || adding
            ? null
            : _selection.active
            ? () => setState(() => _selection.toggle(item.bvid))
            : () => unawaited(_openVideo(item)),
        onLongPress:
            _selection.active || _addingBvid != null || _openingBvid != null
            ? null
            : () => setState(() => _selection.start(item.bvid)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    _buildCover(
                      item.coverUrl,
                      width: _largeTypeOnPhone ? 76 : 128,
                      height: _largeTypeOnPhone ? 54 : 72,
                    ),
                    if (item.duration > Duration.zero)
                      Container(
                        margin: const EdgeInsets.all(4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _formatDuration(item.duration),
                          maxLines: 1,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: _largeTypeOnPhone ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
              if (_selection.active)
                SizedBox(
                  key: handleKey,
                  width: 48,
                  height: 48,
                  child: Checkbox(
                    key: ValueKey('check-collection-${item.bvid}'),
                    semanticLabel: '选择 ${item.title}',
                    value: _selection.ids.contains(item.bvid),
                    onChanged: _batchBusy
                        ? null
                        : (_) => setState(() => _selection.toggle(item.bvid)),
                  ),
                )
              else if (opening)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: IconButton(
                    key: Key('add-learning-collection-${item.bvid}'),
                    tooltip: added ? '选择更多分 P' : '加入学习清单',
                    // 右侧学习清单图标函数替代播放三角，并独立处理加入或确认取消。
                    onPressed: adding
                        ? null
                        : () => unawaited(_toggleVideoLearningList(item)),
                    icon: adding
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            added
                                ? Icons.playlist_add_check_rounded
                                : Icons.playlist_add_rounded,
                          ),
                  ),
                ),
            ],
          ),
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
    return DragSelectionRegion(
      controller: _scrollController,
      itemCount: _videos.length,
      enabled: _selection.active && !_batchBusy,
      checkedAt: (i) => _selection.ids.contains(_videos[i].bvid),
      onDragUpdate: (change) =>
          setState(() => _selection.range(change, _videos)),
      builder: (context, dragging) => RefreshIndicator(
        notificationPredicate: (notification) =>
            !_selection.active && notification.depth == 0,
        onRefresh: _loadFirstPage,
        child: AdaptiveTwoColumnList(
          key: const Key('collection-detail-video-list'),
          controller: _scrollController,
          physics: dragging
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          header: _buildHeader(),
          itemCount: _videos.length,
          footer: _loadingMore
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _needsPageTap
              ? Center(
                  child: TextButton.icon(
                    key: const Key('continue-collection-pages'),
                    onPressed: () => _loadMore(manual: true),
                    icon: const Icon(Icons.expand_more),
                    label: const Text('继续加载后续视频'),
                  ),
                )
              : const SizedBox(height: 8),
          mainAxisSpacing: 4,
          itemBuilder: (BuildContext context, int index) {
            return DragSelectionTarget(
              index: index,
              builder: (context, key) => _buildVideoTile(_videos[index], key),
            );
          },
        ),
      ),
    );
  }

  /// 创建带刷新入口的 UGC 合集详情页。
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selection.active,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && _selection.active && !_batchBusy) {
          setState(_selection.end);
        }
      },
      child: Scaffold(
        appBar: _selection.active
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '退出多选',
                  onPressed: _batchBusy ? null : () => setState(_selection.end),
                ),
                title: Text(
                  '已选 ${_selection.ids.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  TextButton.icon(
                    key: const Key('batch-save-selected'),
                    onPressed: _batchBusy || _selection.ids.isEmpty
                        ? null
                        : _saveSelected,
                    icon: _largeTypeOnPhone
                        ? null
                        : const Icon(Icons.add_rounded),
                    label: const Text('添加到'),
                  ),
                ],
              )
            : AppBar(
                title: const Text('合集详情'),
                actions: <Widget>[
                  FocusSubscriptionButton(
                    service: widget.subscriptionService,
                    source: SubscriptionSource(
                      kind: SubscriptionKind.collection,
                      mid: widget.collection.ownerMid,
                      seasonId: widget.collection.id,
                      name: widget.collection.title,
                      imageUrl: widget.collection.coverUrl,
                      token: DateTime.now().microsecondsSinceEpoch.toString(),
                    ),
                  ),
                ],
              ),
        body: AdaptivePageFrame(maxWidth: 1180, child: _buildBody()),
      ),
    );
  }
}
