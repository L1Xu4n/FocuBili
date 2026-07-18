import 'dart:async';
import 'dart:collection';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/router/app_router.dart';
import '../../features/common/watch_history_badge.dart';
import '../../models/public_profile.dart';
import '../../models/video_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/watch_history_service.dart';
import 'collection_detail_page.dart';

/// 用户主页只展示公开资料、投稿、专栏和 UGC 合集，不提供私信入口。
class UserProfilePage extends StatefulWidget {
  /// 创建公开用户主页，并允许从已有视频资料预填昵称和头像。
  const UserProfilePage({
    super.key,
    required this.mid,
    this.initialName = '',
    this.initialAvatarUrl = '',
    this.publicContentService,
    this.videoService,
    this.watchHistoryService,
  });

  final int mid;
  final String initialName;
  final String initialAvatarUrl;
  final BilibiliPublicContentService? publicContentService;
  final BilibiliService? videoService;
  final WatchHistoryService? watchHistoryService;

  /// 创建管理公开主页资料、标签和分页内容的状态。
  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

/// 标识用户主页下方三类公开内容。
enum _CreatorTab { videos, articles, collections }

/// 管理用户主页资料读取、标签切换、分页以及内容导航。
class _UserProfilePageState extends State<UserProfilePage>
    with SingleTickerProviderStateMixin {
  static const int _maximumPartCountLookupConcurrency = 2;
  late final BilibiliPublicContentService _publicContentService;
  late final BilibiliService _videoService;
  late final WatchHistoryService _watchHistoryService;
  late final TabController _tabController;
  final TextEditingController _videoSearchController = TextEditingController();
  CreatorProfile? _profile;
  List<Object> _items = const <Object>[];
  _CreatorTab _selectedTab = _CreatorTab.videos;
  int _page = 0;
  bool _hasMore = true;
  bool _loadingProfile = true;
  bool _loadingContent = true;
  bool _loadingMore = false;
  String? _profileError;
  String? _contentError;
  String? _openingBvid;
  String _videoKeyword = '';
  CreatorVideoOrder _videoOrder = CreatorVideoOrder.latest;
  int _totalCount = 0;
  bool _videoSearchExpanded = false;
  Map<String, WatchHistoryEntry> _watchHistoryByBvid =
      const <String, WatchHistoryEntry>{};
  final Queue<CreatorVideo> _partCountLookupQueue = Queue<CreatorVideo>();
  final Set<String> _partCountLookupAttemptedBvids = <String>{};
  final Map<String, int> _resolvedPartCounts = <String, int>{};
  int _activePartCountLookups = 0;

  /// 初始化公开服务、标签控制器和滚动分页监听。
  @override
  void initState() {
    super.initState();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _watchHistoryService = widget.watchHistoryService ?? WatchHistoryService();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(_handleTabChanged);
    unawaited(_loadProfile());
    unawaited(_loadFirstContentPage());
    unawaited(_loadWatchHistory());
  }

  /// 读取本机观看记录并按 BV 号建立索引，让投稿封面能快速判断是否看过。
  Future<void> _loadWatchHistory() async {
    final List<WatchHistoryEntry> entries = await _watchHistoryService
        .loadHistory();
    if (!mounted) {
      return;
    }
    setState(() {
      _watchHistoryByBvid = <String, WatchHistoryEntry>{
        for (final WatchHistoryEntry entry in entries) entry.bvid: entry,
      };
    });
  }

  /// 移除监听并释放标签与滚动控制器。
  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    _videoSearchController.dispose();
    super.dispose();
  }

  /// 标签动画完成后切换内容类型，并从第一页重新读取。
  void _handleTabChanged() {
    if (_tabController.indexIsChanging) {
      return;
    }
    final _CreatorTab nextTab = _CreatorTab.values[_tabController.index];
    if (nextTab == _selectedTab) {
      return;
    }
    _selectedTab = nextTab;
    unawaited(_loadFirstContentPage());
  }

  /// 接收嵌套列表滚动通知，在距离底部较近时自动读取下一页。
  bool _handleContentScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical &&
        notification.metrics.extentAfter < 420) {
      unawaited(_loadMore());
    }
    return false;
  }

  /// 读取 UP 主公开名片；失败时保留从视频页带来的昵称和头像。
  Future<void> _loadProfile() async {
    if (mounted) {
      setState(() {
        _loadingProfile = true;
        _profileError = null;
      });
    }
    try {
      final CreatorProfile profile = await _publicContentService.loadProfile(
        widget.mid,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _loadingProfile = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _profileError = error.toString();
        _loadingProfile = false;
      });
    }
  }

  /// 读取当前标签第 1 页，并清除上一标签留下的内容和错误。
  Future<void> _loadFirstContentPage() async {
    final _CreatorTab requestedTab = _selectedTab;
    if (mounted) {
      setState(() {
        _items = const <Object>[];
        _page = 0;
        _hasMore = true;
        _loadingContent = true;
        _contentError = null;
      });
    }
    try {
      final CreatorContentPage<Object> result = await _loadContentPage(
        requestedTab,
        1,
      );
      if (!mounted || requestedTab != _selectedTab) {
        return;
      }
      setState(() {
        _items = result.items;
        _page = result.page;
        _hasMore = result.hasMore;
        _totalCount = result.totalCount ?? result.items.length;
        _loadingContent = false;
      });
    } catch (error) {
      if (!mounted || requestedTab != _selectedTab) {
        return;
      }
      setState(() {
        _contentError = error.toString();
        _loadingContent = false;
      });
    }
  }

  /// 根据标签调用对应公开接口，并统一转换为 Object 分页供页面渲染。
  Future<CreatorContentPage<Object>> _loadContentPage(
    _CreatorTab tab,
    int page,
  ) async {
    switch (tab) {
      case _CreatorTab.videos:
        final CreatorContentPage<CreatorVideo> result =
            await _publicContentService.loadVideos(
              widget.mid,
              page: page,
              keyword: _videoKeyword,
              order: _videoOrder,
            );
        return CreatorContentPage<Object>(
          items: result.items,
          page: result.page,
          hasMore: result.hasMore,
          totalCount: result.totalCount,
        );
      case _CreatorTab.articles:
        final CreatorContentPage<CreatorArticle> result =
            await _publicContentService.loadArticles(widget.mid, page: page);
        return CreatorContentPage<Object>(
          items: result.items,
          page: result.page,
          hasMore: result.hasMore,
          totalCount: result.totalCount,
        );
      case _CreatorTab.collections:
        final CreatorContentPage<CreatorCollection> result =
            await _publicContentService.loadCollections(widget.mid, page: page);
        return CreatorContentPage<Object>(
          items: result.items,
          page: result.page,
          hasMore: result.hasMore,
          totalCount: result.totalCount,
        );
    }
  }

  /// 提交投稿关键词并从第一页重新查询，空关键词表示恢复全部投稿。
  void _submitVideoSearch([String? value]) {
    final String keyword = (value ?? _videoSearchController.text).trim();
    if (keyword == _videoKeyword && !_loadingContent) {
      return;
    }
    _videoKeyword = keyword;
    _videoSearchController.value = TextEditingValue(
      text: keyword,
      selection: TextSelection.collapsed(offset: keyword.length),
    );
    FocusScope.of(context).unfocus();
    unawaited(_loadFirstContentPage());
  }

  /// 切换投稿排序后重新请求第一页，保证“最多播放/最多收藏”由服务端完整排序。
  void _selectVideoOrder(CreatorVideoOrder order) {
    if (order == _videoOrder) {
      return;
    }
    setState(() => _videoOrder = order);
    unawaited(_loadFirstContentPage());
  }

  /// 展开或收起投稿搜索框，收起时保留已经提交的关键词结果。
  void _toggleVideoSearch() {
    setState(() => _videoSearchExpanded = !_videoSearchExpanded);
    if (!_videoSearchExpanded) {
      FocusScope.of(context).unfocus();
    }
  }

  /// 将投稿排序枚举转换为工具栏中容易理解的中文名称。
  String _videoOrderLabel(CreatorVideoOrder order) {
    switch (order) {
      case CreatorVideoOrder.latest:
        return '最新发布';
      case CreatorVideoOrder.mostPlayed:
        return '最多播放';
      case CreatorVideoOrder.mostFavorited:
        return '最多收藏';
    }
  }

  /// 创建投稿专用的紧凑数量、搜索框和排序菜单，给视频列表留出更多首屏空间。
  Widget _buildVideoToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '共${_totalCount > 0 ? _totalCount : _items.length}投稿',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              PopupMenuButton<CreatorVideoOrder>(
                key: const Key('creator-video-order'),
                initialValue: _videoOrder,
                tooltip: '投稿排序',
                // 排序菜单选择函数交给服务端重新读取完整排序结果。
                onSelected: _selectVideoOrder,
                // 排序菜单构建函数提供最新、最多播放和最多收藏三种真实选项。
                itemBuilder: (BuildContext context) {
                  return CreatorVideoOrder.values
                      .map(
                        (CreatorVideoOrder order) =>
                            PopupMenuItem<CreatorVideoOrder>(
                              value: order,
                              child: Text(_videoOrderLabel(order)),
                            ),
                      )
                      .toList(growable: false);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.sort_rounded, size: 19),
                      const SizedBox(width: 5),
                      Text(_videoOrderLabel(_videoOrder)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _videoSearchExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: TextField(
                key: const Key('creator-video-search'),
                controller: _videoSearchController,
                textInputAction: TextInputAction.search,
                onSubmitted: _submitVideoSearch,
                decoration: InputDecoration(
                  hintText: '搜索该 UP 主的投稿',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    // 搜索按钮函数提交输入框中的投稿关键词。
                    onPressed: _submitVideoSearch,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    tooltip: '搜索投稿',
                  ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 读取当前标签下一页并按业务主键去重合并。
  Future<void> _loadMore() async {
    if (_loadingContent || _loadingMore || !_hasMore) {
      return;
    }
    final _CreatorTab requestedTab = _selectedTab;
    setState(() => _loadingMore = true);
    try {
      final CreatorContentPage<Object> result = await _loadContentPage(
        requestedTab,
        _page + 1,
      );
      if (!mounted || requestedTab != _selectedTab) {
        return;
      }
      setState(() {
        _items = _mergeContent(_items, result.items, requestedTab);
        _page = result.page;
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || requestedTab != _selectedTab) {
        return;
      }
      setState(() => _loadingMore = false);
      _showMessage('加载更多失败：$error');
    }
  }

  /// 按 BV、文章编号或合集编号合并分页内容，避免重复卡片。
  List<Object> _mergeContent(
    List<Object> current,
    List<Object> incoming,
    _CreatorTab tab,
  ) {
    final Set<String> keys = current
        .map((Object item) => _contentKey(item, tab))
        .toSet();
    return List<Object>.unmodifiable(<Object>[
      ...current,
      ...incoming.where((Object item) => keys.add(_contentKey(item, tab))),
    ]);
  }

  /// 返回不同内容类型的稳定主键，用于分页去重。
  String _contentKey(Object item, _CreatorTab tab) {
    switch (tab) {
      case _CreatorTab.videos:
        return (item as CreatorVideo).bvid;
      case _CreatorTab.articles:
        return (item as CreatorArticle).id.toString();
      case _CreatorTab.collections:
        return (item as CreatorCollection).id.toString();
    }
  }

  /// 为当前已经显示、但列表接口没有集数的投稿安排一次视频详情补查。
  void _schedulePartCountFallback(CreatorVideo item) {
    if (item.partCount > 1 || _resolvedPartCounts.containsKey(item.bvid)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isVideoDisplayed(item.bvid)) {
        return;
      }
      if (!_partCountLookupAttemptedBvids.add(item.bvid)) {
        return;
      }
      _partCountLookupQueue.addLast(item);
      _pumpPartCountLookups();
    });
  }

  /// 判断 BV 号是否仍属于当前投稿结果，防止搜索或切页后更新旧列表。
  bool _isVideoDisplayed(String bvid) {
    return _selectedTab == _CreatorTab.videos &&
        _items.whereType<CreatorVideo>().any(
          (CreatorVideo item) => item.bvid == bvid,
        );
  }

  /// 在最多两个并发请求的限制内依次补查投稿详情，避免同时请求整屏视频。
  void _pumpPartCountLookups() {
    while (_activePartCountLookups < _maximumPartCountLookupConcurrency &&
        _partCountLookupQueue.isNotEmpty) {
      final CreatorVideo item = _partCountLookupQueue.removeFirst();
      if (!_isVideoDisplayed(item.bvid)) {
        continue;
      }
      _activePartCountLookups += 1;
      unawaited(_resolvePartCountFallback(item));
    }
  }

  /// 查询完整视频详情，并把真实分P数量缓存到对应投稿卡片。
  Future<void> _resolvePartCountFallback(CreatorVideo item) async {
    try {
      final VideoPreview video = await _videoService.lookupVideo(item.bvid);
      final int partCount = video.parts.length;
      if (mounted && partCount > 1 && _isVideoDisplayed(item.bvid)) {
        setState(() => _resolvedPartCounts[item.bvid] = partCount);
      }
    } catch (_) {
      // 集数补查失败不影响投稿列表和点击播放，同一 BV 本次页面只尝试一次。
    } finally {
      _activePartCountLookups -= 1;
      if (mounted) {
        _pumpPartCountLookups();
      }
    }
  }

  /// 返回列表接口或详情补查得到的较可靠集数，单P始终保持为 1。
  int _partCountFor(CreatorVideo item) {
    return _resolvedPartCounts[item.bvid] ?? item.partCount;
  }

  /// 查询投稿的完整详情并进入播放器。
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
      await Navigator.of(context).pushNamed(AppRoutes.player, arguments: video);
      await _loadWatchHistory();
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

  /// 复制投稿 BV 号并显示轻量确认，作为列表右侧更多操作的首个真实能力。
  Future<void> _copyVideoBvid(CreatorVideo item) async {
    await Clipboard.setData(ClipboardData(text: item.bvid));
    if (mounted) {
      _showMessage('已复制 ${item.bvid}');
    }
  }

  /// 打开 UGC 合集详情，合集中的每一项仍会作为独立视频查询和播放。
  Future<void> _openCollection(CreatorCollection collection) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 合集详情构建函数复用当前公开服务与视频详情服务。
        builder: (BuildContext context) => CollectionDetailPage(
          collection: collection,
          publicContentService: _publicContentService,
          videoService: _videoService,
        ),
      ),
    );
  }

  /// 显示统一三秒轻量提示，不改变主页已加载内容。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 将大数字格式化为万单位，保持主页统计紧凑。
  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }

  /// 将日期格式化为年月日，未知日期不占用额外空间。
  String _formatDate(DateTime? value) {
    if (value == null) {
      return '';
    }
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }

  /// 将视频时长格式化为 mm:ss 或 h:mm:ss。
  String _formatDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 1 << 31).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 创建带磁盘缓存的头像或封面，失败时显示本地图标。
  Widget _buildImage(
    String url, {
    required double width,
    required double height,
    required BoxFit fit,
    IconData placeholderIcon = Icons.image_outlined,
  }) {
    if (url.isEmpty) {
      return _buildImagePlaceholder(width, height, placeholderIcon);
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: const <String, String>{
        'Referer': 'https://www.bilibili.com/',
      },
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: 480,
      maxWidthDiskCache: 720,
      placeholder: (BuildContext context, String value) =>
          _buildImagePlaceholder(width, height, placeholderIcon),
      errorWidget: (BuildContext context, String value, Object error) =>
          _buildImagePlaceholder(width, height, placeholderIcon),
    );
  }

  /// 创建远程图片加载中或失败时的固定尺寸占位。
  Widget _buildImagePlaceholder(double width, double height, IconData icon) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(icon),
      ),
    );
  }

  /// 创建关注、粉丝、获赞三列只读统计。
  Widget _buildStats(CreatorProfile profile) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        _buildStatItem(_formatCount(profile.followerCount), '粉丝'),
        _buildStatItem(_formatCount(profile.followingCount), '关注'),
        _buildStatItem(_formatCount(profile.likeCount), '获赞'),
      ],
    );
  }

  /// 创建单个主页统计数字和文字标签。
  Widget _buildStatItem(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  /// 创建可随 Sliver 收起的紧凑资料头，保留头像、统计、昵称、认证、UID 和签名。
  Widget _buildProfileHeader() {
    final CreatorProfile? profile = _profile;
    final String name = profile?.name.isNotEmpty == true
        ? profile!.name
        : (widget.initialName.isEmpty ? 'UP 主主页' : widget.initialName);
    final String avatarUrl = profile?.avatarUrl.isNotEmpty == true
        ? profile!.avatarUrl
        : widget.initialAvatarUrl;
    return Padding(
      key: const Key('creator-profile-header'),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ClipOval(
                child: _buildImage(
                  avatarUrl,
                  width: 82,
                  height: 82,
                  fit: BoxFit.cover,
                  placeholderIcon: Icons.person_rounded,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    _buildStats(
                      profile ??
                          CreatorProfile(
                            mid: widget.mid,
                            name: name,
                            avatarUrl: avatarUrl,
                            sign: '',
                            officialDescription: '',
                          ),
                    ),
                    if (profile == null && _loadingProfile)
                      const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'UID：${widget.mid}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (profile?.officialDescription.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              profile!.officialDescription,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
          if (profile?.sign.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              profile!.sign,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_profileError != null) ...<Widget>[
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _profileError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  // 资料重试按钮函数只重新读取主页头部。
                  onPressed: _loadProfile,
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 创建横向投稿列表项，左侧使用 16:9 封面，右侧显示标题、日期和公开统计。
  Widget _buildVideoCard(CreatorVideo item) {
    final bool opening = _openingBvid == item.bvid;
    final WatchHistoryEntry? watchHistory = _watchHistoryByBvid[item.bvid];
    _schedulePartCountFallback(item);
    final int partCount = _partCountFor(item);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double thumbnailWidth = (constraints.maxWidth * 0.42)
            .clamp(148, 196)
            .toDouble();
        final double thumbnailHeight = (thumbnailWidth * 9 / 16)
            .clamp(92, 112)
            .toDouble();
        final Color onSurfaceVariant = Theme.of(
          context,
        ).colorScheme.onSurfaceVariant;
        return Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('creator-video-${item.bvid}'),
            // 投稿行点击函数查询完整详情后进入播放器。
            onTap: opening ? null : () => unawaited(_openVideo(item)),
            child: SizedBox(
              height: thumbnailHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ClipRRect(
                    key: Key('creator-video-thumbnail-${item.bvid}'),
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(
                      children: <Widget>[
                        _buildImage(
                          item.coverUrl,
                          width: thumbnailWidth,
                          height: thumbnailHeight,
                          fit: BoxFit.cover,
                          placeholderIcon: Icons.video_library_outlined,
                        ),
                        if (watchHistory != null)
                          Positioned(
                            left: 5,
                            top: 5,
                            child: WatchHistoryBadge(entry: watchHistory),
                          ),
                        if (partCount > 1)
                          Positioned(
                            right: 5,
                            top: 5,
                            child: DecoratedBox(
                              key: Key('creator-video-parts-${item.bvid}'),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                child: Text(
                                  '$partCount集',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Positioned(
                          right: 5,
                          bottom: 5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              child: Text(
                                _formatDuration(item.duration),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (opening)
                          const Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black38,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          key: Key('creator-video-title-${item.bvid}'),
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _formatDate(item.publishedAt),
                          maxLines: 1,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: <Widget>[
                            Icon(
                              Icons.play_circle_outline_rounded,
                              size: 15,
                              color: onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _formatCount(item.stats.viewCount),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              Icons.subtitles_outlined,
                              size: 15,
                              color: onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _formatCount(item.stats.danmakuCount),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    // 投稿更多按钮函数当前提供复制 BV 号，不伪装点赞或收藏写操作。
                    onPressed: () => unawaited(_copyVideoBvid(item)),
                    icon: const Icon(Icons.more_vert_rounded, size: 20),
                    tooltip: '复制 BV 号',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 创建只读专栏摘要卡片；当前不伪装尚未实现的站内文章阅读器。
  Widget _buildArticleCard(CreatorArticle item) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (item.coverUrl.isNotEmpty) ...<Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _buildImage(
                  item.coverUrl,
                  width: 116,
                  height: 78,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
            ],
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
                  if (item.summary.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      item.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    '${_formatDate(item.publishedAt)} · ${_formatCount(item.viewCount)}阅读',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建 UGC 合集卡片，明确显示其中是多支独立视频。
  Widget _buildCollectionCard(CreatorCollection item) {
    return Card(
      key: Key('creator-collection-${item.id}'),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        // 合集卡点击函数进入独立合集详情页。
        onTap: () => unawaited(_openCollection(item)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildImage(
                    item.coverUrl,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.collections_bookmark_outlined,
                  ),
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Container(
                      margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${item.totalCount} 支视频',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建当前标签的加载、错误、空状态或内容列表。
  Widget _buildContent() {
    if (_loadingContent && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_contentError != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline_rounded, size: 44),
              const SizedBox(height: 12),
              Text(_contentError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                // 内容重试按钮函数重新读取当前标签第一页。
                onPressed: _loadFirstContentPage,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(switch (_selectedTab) {
          _CreatorTab.videos => '暂无公开投稿',
          _CreatorTab.articles => '暂无公开专栏',
          _CreatorTab.collections => '暂无公开合集',
        }),
      );
    }
    if (_selectedTab == _CreatorTab.articles) {
      return RefreshIndicator(
        // 专栏下拉刷新函数重新读取当前标签第一页。
        onRefresh: _loadFirstContentPage,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          itemCount: _items.length + 1,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 10),
          itemBuilder: (BuildContext context, int index) {
            if (index == _items.length) {
              return _buildLoadingFooter();
            }
            return _buildArticleCard(_items[index] as CreatorArticle);
          },
        ),
      );
    }
    if (_selectedTab == _CreatorTab.videos) {
      return RefreshIndicator(
        // 投稿列表下拉刷新函数重新读取当前筛选条件的第一页。
        onRefresh: _loadFirstContentPage,
        child: ListView.separated(
          key: const Key('creator-video-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: _items.length + 1,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(height: 12),
          itemBuilder: (BuildContext context, int index) {
            if (index == _items.length) {
              return _buildLoadingFooter();
            }
            return _buildVideoCard(_items[index] as CreatorVideo);
          },
        ),
      );
    }
    return RefreshIndicator(
      // 合集网格下拉刷新函数重新读取当前标签第一页。
      onRefresh: _loadFirstContentPage,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.9,
        ),
        itemCount: _items.length + 1,
        itemBuilder: (BuildContext context, int index) {
          if (index == _items.length) {
            return _buildLoadingFooter();
          }
          return _buildCollectionCard(_items[index] as CreatorCollection);
        },
      ),
    );
  }

  /// 创建分页加载状态，列表结束时保持少量底部留白。
  Widget _buildLoadingFooter() {
    return _loadingMore
        ? const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : const SizedBox.shrink();
  }

  /// 同时刷新主页资料和当前标签第一页，供折叠顶栏的刷新按钮复用。
  void _refreshProfilePage() {
    unawaited(_loadProfile());
    unawaited(_loadFirstContentPage());
  }

  /// 创建带可折叠资料头的公开主页，滚动后固定顶栏和内容标签并扩大视频区域。
  @override
  Widget build(BuildContext context) {
    final String title =
        _profile?.name ??
        (widget.initialName.isEmpty ? '用户主页' : widget.initialName);
    return Scaffold(
      body: NestedScrollView(
        key: const Key('creator-profile-scroll'),
        headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) {
          return <Widget>[
            SliverAppBar(
              key: const Key('creator-profile-app-bar'),
              pinned: true,
              expandedHeight: 285,
              forceElevated: innerBoxIsScrolled,
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: <Widget>[
                if (_selectedTab == _CreatorTab.videos)
                  IconButton(
                    // 搜索按钮函数展开或收起当前 UP 主的投稿搜索框。
                    onPressed: _toggleVideoSearch,
                    icon: Icon(
                      _videoSearchExpanded
                          ? Icons.search_off_rounded
                          : Icons.search_rounded,
                    ),
                    tooltip: _videoSearchExpanded ? '收起投稿搜索' : '搜索投稿',
                  ),
                IconButton(
                  // 刷新按钮函数同时刷新主页头部和当前内容标签。
                  onPressed: _refreshProfilePage,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: '刷新主页',
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.parallax,
                background: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: kToolbarHeight,
                        bottom: kTextTabBarHeight,
                      ),
                      child: _buildProfileHeader(),
                    ),
                  ),
                ),
              ),
              bottom: TabBar(
                controller: _tabController,
                tabs: const <Tab>[
                  Tab(text: '投稿'),
                  Tab(text: '专栏'),
                  Tab(text: '合集'),
                ],
              ),
            ),
          ];
        },
        body: Column(
          children: <Widget>[
            if (_selectedTab == _CreatorTab.videos) _buildVideoToolbar(),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                // 滚动通知函数协调折叠资料头，并在接近底部时触发分页。
                onNotification: _handleContentScrollNotification,
                child: _buildContent(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
