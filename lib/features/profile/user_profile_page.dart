import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/router/app_router.dart';
import '../../models/public_profile.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';
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
  });

  final int mid;
  final String initialName;
  final String initialAvatarUrl;
  final BilibiliPublicContentService? publicContentService;
  final BilibiliService? videoService;

  /// 创建管理公开主页资料、标签和分页内容的状态。
  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

/// 标识用户主页下方三类公开内容。
enum _CreatorTab { videos, articles, collections }

/// 管理用户主页资料读取、标签切换、分页以及内容导航。
class _UserProfilePageState extends State<UserProfilePage>
    with SingleTickerProviderStateMixin {
  late final BilibiliPublicContentService _publicContentService;
  late final BilibiliService _videoService;
  late final TabController _tabController;
  final ScrollController _contentScrollController = ScrollController();
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

  /// 初始化公开服务、标签控制器和滚动分页监听。
  @override
  void initState() {
    super.initState();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(_handleTabChanged);
    _contentScrollController.addListener(_loadMoreNearBottom);
    unawaited(_loadProfile());
    unawaited(_loadFirstContentPage());
  }

  /// 移除监听并释放标签与滚动控制器。
  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    _contentScrollController
      ..removeListener(_loadMoreNearBottom)
      ..dispose();
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

  /// 内容滚动接近底部时自动读取下一页。
  void _loadMoreNearBottom() {
    if (_contentScrollController.position.extentAfter < 420) {
      unawaited(_loadMore());
    }
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
      final CreatorProfile profile =
          await _publicContentService.loadProfile(widget.mid);
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
      final CreatorContentPage<Object> result =
          await _loadContentPage(requestedTab, 1);
      if (!mounted || requestedTab != _selectedTab) {
        return;
      }
      setState(() {
        _items = result.items;
        _page = result.page;
        _hasMore = result.hasMore;
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
            await _publicContentService.loadVideos(widget.mid, page: page);
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

  /// 读取当前标签下一页并按业务主键去重合并。
  Future<void> _loadMore() async {
    if (_loadingContent || _loadingMore || !_hasMore) {
      return;
    }
    final _CreatorTab requestedTab = _selectedTab;
    setState(() => _loadingMore = true);
    try {
      final CreatorContentPage<Object> result =
          await _loadContentPage(requestedTab, _page + 1);
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
    final Set<String> keys =
        current.map((Object item) => _contentKey(item, tab)).toSet();
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
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
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
  Widget _buildImagePlaceholder(
    double width,
    double height,
    IconData icon,
  ) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceVariant,
        child: Icon(icon),
      ),
    );
  }

  /// 创建关注、粉丝、获赞三列只读统计。
  Widget _buildStats(CreatorProfile profile) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        _buildStatItem(_formatCount(profile.followingCount), '关注'),
        _buildStatItem(_formatCount(profile.followerCount), '粉丝'),
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

  /// 创建接近参考图的头像、统计、昵称、认证、UID 和签名头部，不放私信按钮。
  Widget _buildProfileHeader() {
    final CreatorProfile? profile = _profile;
    final String name = profile?.name.isNotEmpty == true
        ? profile!.name
        : (widget.initialName.isEmpty ? 'UP 主主页' : widget.initialName);
    final String avatarUrl = profile?.avatarUrl.isNotEmpty == true
        ? profile!.avatarUrl
        : widget.initialAvatarUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ClipOval(
                child: _buildImage(
                  avatarUrl,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  placeholderIcon: Icons.person_rounded,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: profile == null && _loadingProfile
                    ? const Center(child: CircularProgressIndicator())
                    : _buildStats(
                        profile ??
                            CreatorProfile(
                              mid: widget.mid,
                              name: name,
                              avatarUrl: avatarUrl,
                              sign: '',
                              officialDescription: '',
                            ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            name,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          if (profile?.officialDescription.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              profile!.officialDescription,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text('UID：${widget.mid}'),
            ),
          ),
          if (profile?.sign.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 12),
            Text(profile!.sign),
          ],
          if (_profileError != null) ...<Widget>[
            const SizedBox(height: 10),
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

  /// 创建投稿的双列封面卡片。
  Widget _buildVideoCard(CreatorVideo item) {
    final bool opening = _openingBvid == item.bvid;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        // 投稿卡点击函数查询完整详情后进入播放器。
        onTap: opening ? null : () => unawaited(_openVideo(item)),
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
                    placeholderIcon: Icons.video_library_outlined,
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      color: Colors.black54,
                      child: Text(
                        _formatDuration(item.duration),
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                  ),
                  if (opening)
                    const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
              child: Text(
                '${_formatCount(item.stats.viewCount)}播放  ${_formatDate(item.publishedAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
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
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11),
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
        child: Text(
          switch (_selectedTab) {
            _CreatorTab.videos => '暂无公开投稿',
            _CreatorTab.articles => '暂无公开专栏',
            _CreatorTab.collections => '暂无公开合集',
          },
        ),
      );
    }
    if (_selectedTab == _CreatorTab.articles) {
      return RefreshIndicator(
        // 专栏下拉刷新函数重新读取当前标签第一页。
        onRefresh: _loadFirstContentPage,
        child: ListView.separated(
          controller: _contentScrollController,
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
    return RefreshIndicator(
      // 网格下拉刷新函数重新读取当前标签第一页。
      onRefresh: _loadFirstContentPage,
      child: GridView.builder(
        controller: _contentScrollController,
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
          return _selectedTab == _CreatorTab.videos
              ? _buildVideoCard(_items[index] as CreatorVideo)
              : _buildCollectionCard(_items[index] as CreatorCollection);
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

  /// 创建接近参考图的公开主页：资料头部加投稿、专栏、合集三个标签。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _profile?.name ??
              (widget.initialName.isEmpty ? '用户主页' : widget.initialName),
        ),
        actions: <Widget>[
          IconButton(
            // 刷新按钮函数同时刷新主页头部和当前内容标签。
            onPressed: () {
              unawaited(_loadProfile());
              unawaited(_loadFirstContentPage());
            },
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新主页',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildProfileHeader(),
          TabBar(
            controller: _tabController,
            tabs: const <Tab>[
              Tab(text: '投稿'),
              Tab(text: '专栏'),
              Tab(text: '合集'),
            ],
          ),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }
}
