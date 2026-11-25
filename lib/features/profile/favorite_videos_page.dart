import 'dart:async';

import 'package:focubili/features/common/app_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/router/app_router.dart';
import '../../core/widgets/drag_selection_region.dart';
import '../../models/account_collection.dart';
import '../../models/public_profile.dart';
import '../../models/video_preview.dart';
import '../../models/playback_queue.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_image_url_policy.dart';
import '../../services/bilibili_service.dart';
import '../../services/bilibili_interaction_service.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/learning_list_service.dart';
import '../common/discovery_batch_selection.dart';
import '../common/video_batch_actions.dart';
import 'favorite_folder_edit_dialog.dart';

/// 展示收藏夹内容；只有本账号自建收藏夹入口可打开资料编辑器。
class FavoriteVideosPage extends StatefulWidget {
  /// 创建指定收藏夹的视频页面；服务可注入以支持测试和安全替换。
  const FavoriteVideosPage({
    super.key,
    required this.folder,
    this.accountDataService,
    this.bilibiliService,
    this.learningListService,
    this.editableOwnerMid,
    this.interactionService,
    this.onFolderEdited,
    this.prefetchedPage,
  });

  /// 当前页面读取的收藏夹基本资料。
  final FavoriteFolder folder;

  /// 可选的只读账号数据服务，未传入时创建默认会话服务。
  final BilibiliAccountDataService? accountDataService;

  /// 可选的公开视频详情服务，未传入时使用默认公开视频查询实现。
  final BilibiliService? bilibiliService;
  final LearningListService? learningListService;

  // Set by account-created-folder entry points, never by read-only previews.
  final int? editableOwnerMid;
  final BilibiliInteractionService? interactionService;
  final ValueChanged<FavoriteFolder>? onFolderEdited;

  /// Carries a short-lived first page from the folder cover request.
  final ({int revision, DateTime expires, AccountDataPage<FavoriteVideo> page})?
  prefetchedPage;

  /// 创建管理首次读取、分页、刷新和打开播放器状态的页面状态。
  @override
  State<FavoriteVideosPage> createState() => _FavoriteVideosPageState();
}

/// 管理收藏夹内容的读取、分页合并、失败恢复和单视频打开流程。
class _FavoriteVideosPageState extends State<FavoriteVideosPage> {
  late final BilibiliAccountDataService _accountDataService;
  late final BilibiliService _bilibiliService;
  late final VideoBatchActions _batchActions;
  final _batchSelection = DiscoveryBatchSelection();
  final _scrollController = ScrollController();
  late int _sourceAccount;
  var _loadGeneration = 0;
  bool _batchBusy = false;
  bool _editing = false;
  late FavoriteFolder _folder;

  bool get _sourceCurrent => _sourceAccount == CacheLifecycle.account.value;
  final TextEditingController _searchController = TextEditingController();
  List<FavoriteVideo> _videos = const <FavoriteVideo>[];
  AccountDataPage<FavoriteVideo>? _page;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _openingBvid;
  String _searchQuery = '';

  /// 创建页面服务并在首次进入时读取第 1 页收藏内容。
  @override
  void initState() {
    super.initState();
    _accountDataService =
        widget.accountDataService ?? BilibiliAccountDataService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    _batchActions = VideoBatchActions(
      learningService: widget.learningListService ?? LearningListService(),
      videoService: _bilibiliService,
      accountService: _accountDataService,
    );
    _folder = widget.folder;
    _sourceAccount = CacheLifecycle.account.value;
    CacheLifecycle.account.addListener(_accountChanged);
    unawaited(_loadFirstPage(usePrefetch: true));
  }

  @override
  void didUpdateWidget(covariant FavoriteVideosPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.folder.mediaId == oldWidget.folder.mediaId) return;
    _folder = widget.folder;
    _sourceAccount = CacheLifecycle.account.value;
    _accountChanged();
    unawaited(_loadFirstPage());
  }

  void _accountChanged() {
    _loadGeneration++;
    setState(() {
      _batchSelection.reset();
      _videos = const [];
      _page = null;
      _openingBvid = null;
      _isLoading = false;
      _isLoadingMore = false;
    });
  }

  /// 释放收藏内容搜索输入控制器。
  @override
  void dispose() {
    CacheLifecycle.account.removeListener(_accountChanged);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _editFolder() async {
    final mid = widget.editableOwnerMid;
    if (_editing || mid == null || !_sourceCurrent || !_folder.isAvailable) {
      return;
    }
    final originalId = _folder.mediaId;
    bool current() =>
        mounted &&
        _sourceCurrent &&
        _folder.mediaId == originalId &&
        widget.editableOwnerMid == mid;
    _editing = true;
    try {
      final edited = await showFavoriteFolderEditDialog(
        context,
        service: widget.interactionService ?? BilibiliInteractionService(),
        mediaId: originalId,
        ownerMid: mid,
        isCurrent: current,
      );
      if (edited == null || !current()) return;
      setState(() {
        _folder = _folder.withEditedMetadata(edited.title, edited.isPrivate);
      });
      widget.onFolderEdited?.call(_folder);
      _showMessage('已保存收藏夹设置');
    } finally {
      _editing = false;
    }
  }

  /// 读取收藏夹第 1 页；刷新失败时保留原有已成功显示的视频列表。
  Future<void> _loadFirstPage({bool usePrefetch = false}) async {
    if (!mounted || !_sourceCurrent) return;
    final generation = ++_loadGeneration;
    setState(() {
      _batchSelection.reset();
      _isLoading = true;
      _isLoadingMore = false;
      _openingBvid = null;
    });
    final prefetched = usePrefetch ? widget.prefetchedPage : null;
    final result =
        prefetched != null &&
            prefetched.revision == _sourceAccount &&
            prefetched.expires.isAfter(DateTime.now())
        ? prefetched.page
        : await _accountDataService.loadFavoriteVideos(widget.folder.mediaId);
    if (!mounted || generation != _loadGeneration || !_sourceCurrent) return;
    final bool keepPreviousList = !result.isSuccess && _videos.isNotEmpty;
    setState(() {
      _isLoading = false;
      if (result.isSuccess) {
        _videos = _mergeVideos(const [], result.items);
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
    if (!_sourceCurrent ||
        _isLoading ||
        _isLoadingMore ||
        currentPage == null ||
        !currentPage.isSuccess ||
        !currentPage.hasMore) {
      return;
    }
    final generation = _loadGeneration;
    setState(() => _isLoadingMore = true);
    final AccountDataPage<FavoriteVideo> result = await _accountDataService
        .loadFavoriteVideos(widget.folder.mediaId, page: currentPage.page + 1);
    if (!mounted || generation != _loadGeneration || !_sourceCurrent) return;
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
    final Set<String> bvids = current
        .map((FavoriteVideo video) => video.bvid)
        .toSet();
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
    if (!_sourceCurrent || !video.isAvailable || _openingBvid != null) {
      return;
    }
    final generation = _loadGeneration;
    setState(() => _openingBvid = video.bvid);
    try {
      final VideoPreview preview = await _bilibiliService.lookupVideo(
        video.bvid,
      );
      if (!mounted || generation != _loadGeneration || !_sourceCurrent) return;
      setState(() => _openingBvid = null);
      final service = _accountDataService;
      final folder = _folder;
      final account = _sourceAccount;
      final queue = PlaybackQueue(
        title: folder.title,
        items: _filteredVideos()
            .where((item) => item.isAvailable)
            .map(
              (item) => PlaybackQueueItem(bvid: item.bvid, title: item.title),
            ),
        nextPage: (_page?.page ?? 1) + 1,
        hasMore: (_page?.hasMore ?? false) && _searchQuery.trim().isEmpty,
        // 分页读取器仅持有服务和来源身份，不读取已离开的页面状态。
        loadPage: (page) async {
          if (account != CacheLifecycle.account.value) {
            throw StateError('账号已变化');
          }
          final result = await service.loadFavoriteVideos(
            folder.mediaId,
            page: page,
          );
          if (account != CacheLifecycle.account.value || !result.isSuccess) {
            throw StateError('收藏夹读取失败');
          }
          return PlaybackQueuePage(
            result.items
                .where((item) => item.isAvailable)
                .map(
                  (item) =>
                      PlaybackQueueItem(bvid: item.bvid, title: item.title),
                )
                .toList(),
            hasMore: result.hasMore,
          );
        },
      );
      Navigator.of(context).pushNamed(
        AppRoutes.player,
        arguments: PlayerLaunchRequest(preview, queue),
      );
    } on BilibiliLookupException catch (error) {
      if (mounted && generation == _loadGeneration && _sourceCurrent) {
        setState(() => _openingBvid = null);
        _showMessage(error.message);
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration && _sourceCurrent) {
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
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
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
              AppNetworkImage(
                imageUrl: video.coverUrl,
                imageVariant: BilibiliImageVariant.cover16x9,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                },
                fit: BoxFit.cover,
                memCacheWidth: 320,
                placeholder: (BuildContext context, String url) =>
                    _buildThumbnailPlaceholder(),
                errorWidget: (BuildContext context, String url, Object error) =>
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
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.play_arrow_rounded, color: Colors.black45),
      ),
    );
  }

  /// 创建缩略图上的半透明文字角标，确保时长与分P信息清晰可读。
  Widget _buildThumbnailBadge(String text) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
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

  /// 按标题、UP 主昵称或 BV 号筛选当前已经加载的收藏视频。
  List<FavoriteVideo> _filteredVideos() {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return _videos;
    }
    return _videos
        .where(
          (FavoriteVideo video) =>
              video.title.toLowerCase().contains(query) ||
              video.ownerName.toLowerCase().contains(query) ||
              video.bvid.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  /// 创建收藏内容搜索框，输入变化只筛选本页内存数据。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: TextField(
        key: const Key('favorite-videos-search'),
        controller: _searchController,
        onChanged: (String value) => setState(() {
          if (_searchQuery == value) return;
          _searchQuery = value;
          _batchSelection.reset();
        }),
        decoration: InputDecoration(
          hintText: '搜索视频标题、UP 主或 BV 号',
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  List<String> _eligibleIds(Iterable<FavoriteVideo> videos) => videos
      .where((video) => video.isAvailable && video.bvid.isNotEmpty)
      .map((video) => video.bvid)
      .toSet()
      .toList();

  bool get _canStartBatch =>
      _sourceCurrent &&
      !_isLoading &&
      !_batchBusy &&
      _openingBvid == null &&
      _eligibleIds(_filteredVideos()).length >= 2;

  void _startBatch([String? bvid]) {
    if (!_canStartBatch) return;
    FocusScope.of(context).unfocus();
    setState(() => _batchSelection.start(bvid));
  }

  Future<void> _saveSelectedFavorites() async {
    if (!_sourceCurrent || _batchBusy || _batchSelection.ids.isEmpty) return;
    final ids = Set<String>.of(_batchSelection.ids);
    final distinct = <String>{};
    final videos = [
      for (final row in _filteredVideos())
        if (row.isAvailable && ids.contains(row.bvid) && distinct.add(row.bvid))
          CreatorVideo(
            bvid: row.bvid,
            title: row.title,
            coverUrl: row.coverUrl,
            duration: row.duration,
            ownerName: row.ownerName,
            partCount: row.partCount,
          ),
    ];
    if (videos.length != ids.length) return;
    final generation = _loadGeneration;
    final account = _sourceAccount;
    final query = _searchQuery;
    bool isCurrent() =>
        mounted &&
        _sourceCurrent &&
        account == _sourceAccount &&
        generation == _loadGeneration &&
        query == _searchQuery &&
        _eligibleIds(_filteredVideos()).toSet().containsAll(ids);
    setState(() => _batchBusy = true);
    try {
      final saved = await _batchActions.run(
        context,
        videos: videos,
        sourceIsCurrent: isCurrent,
      );
      if (saved && isCurrent()) setState(_batchSelection.close);
    } finally {
      if (mounted) setState(() => _batchBusy = false);
    }
  }

  /// 创建自适应收藏视频卡片列表，避免宽封面和尾部图标在窄屏挤压标题。
  Widget _buildVideoList() {
    final List<FavoriteVideo> visibleVideos = _filteredVideos();
    final Widget footer =
        visibleVideos.isEmpty && _searchQuery.trim().isNotEmpty
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: Text('没有匹配的收藏视频')),
          )
        : _buildLoadMoreFooter();
    final eligibleIds = _eligibleIds(visibleVideos);
    final indices = {
      for (var i = 0; i < eligibleIds.length; i++) eligibleIds[i]: i,
    };
    _batchSelection.sync(eligibleIds);
    final epoch = _batchSelection.epoch;
    final canStart = _canStartBatch;
    return DragSelectionRegion(
      key: ValueKey('favorite-video-drag-$epoch'),
      controller: _scrollController,
      itemCount: eligibleIds.length,
      enabled: _batchSelection.active && !_batchBusy,
      checkedAt: (index) => _batchSelection.ids.contains(eligibleIds[index]),
      onDragUpdate: (update) {
        if (epoch == _batchSelection.epoch) {
          setState(() => _batchSelection.range(update, eligibleIds));
        }
      },
      builder: (context, dragging) => RefreshIndicator(
        notificationPredicate: (notification) =>
            !_batchSelection.active && notification.depth == 0,
        // 下拉刷新函数只重新读取第 1 页，不会写入收藏夹或账号数据。
        onRefresh: _loadFirstPage,
        child: AdaptiveTwoColumnList(
          key: const Key('favorite-videos-list'),
          controller: _scrollController,
          physics: dragging
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: visibleVideos.length,
          footer: footer,
          mainAxisSpacing: 8,
          itemBuilder: (BuildContext context, int index) {
            final FavoriteVideo video = visibleVideos[index];
            final selectionIndex = video.isAvailable
                ? indices[video.bvid]
                : null;
            Widget card(Key? handleKey) => _buildVideoCard(
              video,
              handleKey: handleKey,
              canSelect: selectionIndex != null && canStart,
            );
            if (!_batchSelection.active || selectionIndex == null) {
              return card(null);
            }
            return DragSelectionTarget(
              key: ValueKey('favorite-selection-${video.bvid}'),
              index: selectionIndex,
              builder: (context, handleKey) => card(handleKey),
            );
          },
        ),
      ),
    );
  }

  Widget _buildVideoCard(
    FavoriteVideo video, {
    Key? handleKey,
    required bool canSelect,
  }) {
    final isOpening = _openingBvid == video.bvid;
    final selecting = _batchSelection.active;
    final selected = selecting && _batchSelection.ids.contains(video.bvid);
    final toggle = selecting && handleKey != null && !_batchBusy
        ? () => setState(() => _batchSelection.toggle(video.bvid))
        : null;
    return Card(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      key: Key('favorite-video-${video.bvid}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 视频点击函数仅在条目可播放时补齐详情并进入播放器。
        onTap: selecting
            ? toggle
            : !video.isAvailable || isOpening || _batchBusy
            ? null
            : () => _openVideo(video),
        onLongPress: !selecting && canSelect
            ? () => _startBatch(video.bvid)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              _buildThumbnail(video),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      video.isAvailable
                          ? video.ownerName
                          : '${video.ownerName} · 视频已失效，暂不可播放',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (handleKey != null)
                Checkbox(
                  key: handleKey,
                  value: selected,
                  semanticLabel: video.title,
                  onChanged: toggle == null ? null : (_) => toggle(),
                )
              else if (isOpening)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Icon(
                  video.isAvailable
                      ? Icons.play_circle_outline_rounded
                      : Icons.block_rounded,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 根据首次加载、失败、空和正常列表状态选择收藏视频页主体。
  Widget _buildBody() {
    if (!_sourceCurrent) {
      return const Center(child: Text('账号已变化，请返回后重新打开收藏夹。'));
    }
    if (_isLoading && _page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final AccountDataPage<FavoriteVideo>? page = _page;
    if (page == null) {
      return _buildStatusState(AccountDataPage<FavoriteVideo>.unavailable());
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
    return PopScope(
      canPop: !_batchSelection.active,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && !_batchBusy && _batchSelection.active) {
          setState(_batchSelection.close);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_folder.title),
          actions: <Widget>[
            if (!_batchSelection.active &&
                _sourceCurrent &&
                _folder.isAvailable &&
                (widget.editableOwnerMid ?? 0) > 0)
              IconButton(
                key: const Key('edit-bilibili-favorite-folder'),
                tooltip: '编辑收藏夹',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => unawaited(_editFolder()),
              ),
            if (!_batchSelection.active && _canStartBatch)
              IconButton(
                tooltip: '多选视频',
                icon: const Icon(Icons.checklist),
                onPressed: _startBatch,
              ),
            IconButton(
              // 刷新按钮函数只读取当前收藏夹第 1 页，不写入任何 B 站数据。
              onPressed: _isLoading || _batchSelection.active || !_sourceCurrent
                  ? null
                  : () => unawaited(_loadFirstPage()),
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新收藏内容',
            ),
          ],
        ),
        body: AdaptivePageFrame(
          maxWidth: 1180,
          child: Column(
            children: <Widget>[
              _buildSearchField(),
              if (_batchSelection.active)
                DiscoveryBatchSelectionBar(
                  count: _batchSelection.ids.length,
                  onClose: _batchBusy
                      ? null
                      : () => setState(_batchSelection.close),
                  onSave: _batchBusy || _batchSelection.ids.isEmpty
                      ? null
                      : _saveSelectedFavorites,
                ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }
}
