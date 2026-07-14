import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/account_collection.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';
import 'user_profile_page.dart';

/// “我的关注”只展示当前账号已关注的 UP 主，不与订阅合集混用。
class FollowedCreatorsPage extends StatefulWidget {
  /// 创建可注入只读账号数据服务的已关注 UP 主页面。
  const FollowedCreatorsPage({
    super.key,
    this.accountDataService,
    this.publicContentService,
    this.videoService,
  });

  /// 可选的只读账号服务，未传入时使用默认的当前 WebView 会话服务。
  final BilibiliAccountDataService? accountDataService;
  final BilibiliPublicContentService? publicContentService;
  final BilibiliService? videoService;

  /// 创建管理首次加载、翻页和刷新状态的页面状态对象。
  @override
  State<FollowedCreatorsPage> createState() => _FollowedCreatorsPageState();
}

/// 管理已关注 UP 主的只读分页加载，页面不提供关注、取关或分组操作。
class _FollowedCreatorsPageState extends State<FollowedCreatorsPage> {
  late final BilibiliAccountDataService _accountDataService;
  late final BilibiliPublicContentService _publicContentService;
  late final BilibiliService _videoService;
  final TextEditingController _searchController = TextEditingController();
  List<FollowedCreator> _creators = const <FollowedCreator>[];
  AccountDataPage<FollowedCreator>? _page;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String _searchQuery = '';

  /// 初始化服务并在进入页面时读取已关注 UP 主的第 1 页。
  @override
  void initState() {
    super.initState();
    _accountDataService =
        widget.accountDataService ?? BilibiliAccountDataService();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    unawaited(_loadFirstPage());
  }

  /// 释放我的关注搜索输入控制器。
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 打开已关注 UP 主的公开主页，不执行关注或取关操作。
  Future<void> _openCreator(FollowedCreator creator) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 用户主页构建函数复用当前公开内容与视频详情服务。
        builder: (BuildContext context) => UserProfilePage(
          mid: creator.mid,
          initialName: creator.name,
          initialAvatarUrl: creator.avatarUrl,
          publicContentService: _publicContentService,
          videoService: _videoService,
        ),
      ),
    );
  }

  /// 读取第 1 页已关注 UP 主；刷新失败时不清空已有成功结果。
  Future<void> _loadFirstPage() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }
    final AccountDataPage<FollowedCreator> result =
        await _accountDataService.loadFollowedCreators();
    if (!mounted) {
      return;
    }
    final bool keepPreviousList = !result.isSuccess && _creators.isNotEmpty;
    setState(() {
      _isLoading = false;
      if (result.isSuccess) {
        _creators = result.items;
        _page = result;
      } else if (!keepPreviousList) {
        _creators = const <FollowedCreator>[];
        _page = result;
      }
    });
    if (keepPreviousList) {
      _showMessage(result.message ?? '刷新已关注 UP 主失败，请稍后重试。');
    }
  }

  /// 请求下一页已关注 UP 主，失败时保留已显示创作者并允许再次点击加载更多。
  Future<void> _loadMore() async {
    final AccountDataPage<FollowedCreator>? currentPage = _page;
    if (_isLoadingMore ||
        currentPage == null ||
        !currentPage.isSuccess ||
        !currentPage.hasMore) {
      return;
    }
    setState(() => _isLoadingMore = true);
    final AccountDataPage<FollowedCreator> result =
        await _accountDataService.loadFollowedCreators(
      page: currentPage.page + 1,
    );
    if (!mounted) {
      return;
    }
    setState(() => _isLoadingMore = false);
    if (!result.isSuccess) {
      _showMessage(result.message ?? '加载更多已关注 UP 主失败，请稍后重试。');
      return;
    }
    setState(() {
      _creators = _mergeCreators(_creators, result.items);
      _page = result;
    });
  }

  /// 按 mid 去重合并分页结果，避免服务端页边界重复造成重复 UP 主卡片。
  List<FollowedCreator> _mergeCreators(
    List<FollowedCreator> current,
    List<FollowedCreator> incoming,
  ) {
    final Set<int> mids =
        current.map((FollowedCreator creator) => creator.mid).toSet();
    final List<FollowedCreator> merged = <FollowedCreator>[...current];
    for (final FollowedCreator creator in incoming) {
      if (mids.add(creator.mid)) {
        merged.add(creator);
      }
    }
    return List<FollowedCreator>.unmodifiable(merged);
  }

  /// 显示统一持续三秒的轻量提示，不会替换当前已成功读取的关注列表。
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

  /// 创建 UP 主头像、网络失败占位图和固定尺寸裁切效果。
  Widget _buildAvatar(FollowedCreator creator) {
    if (creator.avatarUrl.isEmpty) {
      return const CircleAvatar(
        radius: 26,
        child: Icon(Icons.person_rounded),
      );
    }
    return CircleAvatar(
      radius: 26,
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: creator.avatarUrl,
          httpHeaders: const <String, String>{
            'Referer': 'https://www.bilibili.com/',
          },
          width: 52,
          height: 52,
          fit: BoxFit.cover,
          memCacheWidth: 160,
          maxWidthDiskCache: 320,
          fadeInDuration: const Duration(milliseconds: 120),
          placeholder: (BuildContext context, String url) =>
              _buildAvatarPlaceholder(),
          errorWidget: (BuildContext context, String url, Object error) =>
              _buildAvatarPlaceholder(),
        ),
      ),
    );
  }

  /// 创建头像加载中或失败时使用的固定尺寸本地占位图。
  Widget _buildAvatarPlaceholder() {
    return const SizedBox.square(
      dimension: 52,
      child: Icon(Icons.person_rounded),
    );
  }

  /// 按昵称、UID、认证或签名筛选当前已加载的关注列表。
  List<FollowedCreator> _filteredCreators() {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return _creators;
    }
    return _creators
        .where(
          (FollowedCreator creator) =>
              creator.name.toLowerCase().contains(query) ||
              creator.mid.toString().contains(query) ||
              creator.officialDescription.toLowerCase().contains(query) ||
              creator.sign.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  /// 创建关注列表搜索框，输入时只筛选已加载资料。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: TextField(
        key: const Key('followed-creators-search'),
        controller: _searchController,
        onChanged: (String value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          hintText: '搜索昵称、UID、认证或签名',
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  /// 创建信息层级更清晰的关注卡片，分别展示昵称、UID、认证和签名。
  Widget _buildCreatorCard(FollowedCreator creator) {
    return Card(
      key: Key('followed-creator-${creator.mid}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // UP 主卡点击函数打开只读公开主页。
        onTap: () => unawaited(_openCreator(creator)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _buildAvatar(creator),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            creator.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (creator.officialDescription.isNotEmpty) ...<Widget>[
                          const SizedBox(width: 5),
                          Icon(
                            Icons.verified_rounded,
                            size: 17,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'UID：${creator.mid}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (creator.officialDescription.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        creator.officialDescription,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (creator.sign.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        creator.sign,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建所有账号数据失败状态的说明和重试入口，避免以空关注列表掩盖错误。
  Widget _buildStatusState(AccountDataPage<FollowedCreator> page) {
    final IconData icon;
    switch (page.status) {
      case AccountDataLoadStatus.success:
        icon = Icons.people_outline_rounded;
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
      key: Key('followed-creators-status-${page.status.name}'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44),
            const SizedBox(height: 12),
            Text(
              page.message ?? '暂时无法读取已关注 UP 主，请稍后重试。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('followed-creators-retry'),
              // 重试按钮函数只重新读取已关注 UP 主的第 1 页。
              onPressed: _isLoading ? null : _loadFirstPage,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建服务成功但当前账号尚未关注任何 UP 主时的空状态。
  Widget _buildEmptyState() {
    return const Center(
      key: Key('followed-creators-empty'),
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.people_outline_rounded, size: 44),
            SizedBox(height: 12),
            Text('还没有已关注的 UP 主'),
          ],
        ),
      ),
    );
  }

  /// 创建底部的下一页加载器、加载更多按钮或已到列表末尾说明。
  Widget _buildLoadMoreFooter() {
    final AccountDataPage<FollowedCreator>? page = _page;
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
          key: const Key('followed-creators-load-more'),
          // 加载更多按钮函数只读取下一页关注名单，不执行关注或取关。
          onPressed: _loadMore,
          child: const Text('加载更多'),
        ),
      ),
    );
  }

  /// 创建已关注 UP 主卡片列表和分页底部入口，不提供任何写关系控件。
  Widget _buildCreatorList() {
    final List<FollowedCreator> visibleCreators = _filteredCreators();
    return RefreshIndicator(
      // 下拉刷新函数只重新读取第 1 页关注数据，不改变账号关注关系。
      onRefresh: _loadFirstPage,
      child: ListView.separated(
        key: const Key('followed-creators-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: visibleCreators.length + 1,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) {
          if (index == visibleCreators.length) {
            if (visibleCreators.isEmpty && _searchQuery.trim().isNotEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text('没有匹配的已关注 UP 主')),
              );
            }
            return _buildLoadMoreFooter();
          }
          return _buildCreatorCard(visibleCreators[index]);
        },
      ),
    );
  }

  /// 根据首次加载、失败、空和正常关注列表状态选择页面主体。
  Widget _buildBody() {
    if (_isLoading && _page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final AccountDataPage<FollowedCreator>? page = _page;
    if (page == null) {
      return _buildStatusState(
        AccountDataPage<FollowedCreator>.unavailable(),
      );
    }
    if (!page.isSuccess) {
      return _buildStatusState(page);
    }
    if (_creators.isEmpty) {
      return _buildEmptyState();
    }
    return _buildCreatorList();
  }

  /// 创建明确的“我的关注”标题、刷新入口和 UP 主列表。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的关注'),
        actions: <Widget>[
          IconButton(
            // 刷新按钮函数只读取已关注 UP 主，不会执行任何关系写操作。
            onPressed: _isLoading ? null : () => unawaited(_loadFirstPage()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新已关注 UP 主',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildSearchField(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }
}
