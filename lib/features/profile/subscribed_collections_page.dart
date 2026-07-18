import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/account_collection.dart';
import '../../models/public_profile.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';
import 'collection_detail_page.dart';

/// “我的订阅”只展示当前账号订阅的 UGC 合集，不展示关注的 UP 主。
class SubscribedCollectionsPage extends StatefulWidget {
  /// 创建订阅合集页，并允许测试注入账号与公开内容服务。
  const SubscribedCollectionsPage({
    super.key,
    this.accountDataService,
    this.publicContentService,
    this.videoService,
  });

  final BilibiliAccountDataService? accountDataService;
  final BilibiliPublicContentService? publicContentService;
  final BilibiliService? videoService;

  /// 创建管理订阅合集分页和导航的状态。
  @override
  State<SubscribedCollectionsPage> createState() =>
      _SubscribedCollectionsPageState();
}

/// 管理订阅合集的只读加载、分页和详情导航。
class _SubscribedCollectionsPageState extends State<SubscribedCollectionsPage> {
  late final BilibiliAccountDataService _accountDataService;
  late final BilibiliPublicContentService _publicContentService;
  late final BilibiliService _videoService;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  List<SubscribedCollection> _collections = const <SubscribedCollection>[];
  AccountDataPage<SubscribedCollection>? _page;
  bool _loading = true;
  bool _loadingMore = false;
  String _searchQuery = '';

  /// 初始化服务、滚动监听，并读取订阅合集第一页。
  @override
  void initState() {
    super.initState();
    _accountDataService =
        widget.accountDataService ?? BilibiliAccountDataService();
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
    _searchController.dispose();
    super.dispose();
  }

  /// 读取第 1 页订阅合集；刷新失败时保留已有成功列表。
  Future<void> _loadFirstPage() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    final AccountDataPage<SubscribedCollection> result =
        await _accountDataService.loadSubscribedCollections();
    if (!mounted) {
      return;
    }
    final bool keepPrevious = !result.isSuccess && _collections.isNotEmpty;
    setState(() {
      _loading = false;
      if (result.isSuccess) {
        _collections = result.items;
        _page = result;
      } else if (!keepPrevious) {
        _collections = const <SubscribedCollection>[];
        _page = result;
      }
    });
    if (keepPrevious) {
      _showMessage(result.message ?? '刷新订阅合集失败，请稍后重试。');
    }
  }

  /// 滚动接近底部时自动读取下一页订阅合集。
  void _loadMoreNearBottom() {
    if (_scrollController.position.extentAfter < 360) {
      unawaited(_loadMore());
    }
  }

  /// 读取下一页订阅合集并按合集编号去重合并。
  Future<void> _loadMore() async {
    final AccountDataPage<SubscribedCollection>? current = _page;
    if (_loadingMore ||
        current == null ||
        !current.isSuccess ||
        !current.hasMore) {
      return;
    }
    setState(() => _loadingMore = true);
    final AccountDataPage<SubscribedCollection> result =
        await _accountDataService.loadSubscribedCollections(
          page: current.page + 1,
        );
    if (!mounted) {
      return;
    }
    setState(() => _loadingMore = false);
    if (!result.isSuccess) {
      _showMessage(result.message ?? '加载更多订阅合集失败，请稍后重试。');
      return;
    }
    setState(() {
      _collections = _mergeCollections(_collections, result.items);
      _page = result;
    });
  }

  /// 按合集编号去重合并分页内容。
  List<SubscribedCollection> _mergeCollections(
    List<SubscribedCollection> current,
    List<SubscribedCollection> incoming,
  ) {
    final Set<int> ids = current
        .map((SubscribedCollection item) => item.id)
        .toSet();
    return List<SubscribedCollection>.unmodifiable(<SubscribedCollection>[
      ...current,
      ...incoming.where((SubscribedCollection item) => ids.add(item.id)),
    ]);
  }

  /// 将账号订阅资料转换成公开合集资料并打开详情页。
  Future<void> _openCollection(SubscribedCollection item) async {
    if (item.ownerMid <= 0) {
      _showMessage('这个合集缺少 UP 主编号，暂时无法读取详情。');
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 合集详情构建函数只读取公开视频列表，不执行取消订阅等写操作。
        builder: (BuildContext context) => CollectionDetailPage(
          collection: CreatorCollection(
            id: item.id,
            ownerMid: item.ownerMid,
            ownerName: item.ownerName,
            ownerAvatarUrl: item.ownerAvatarUrl,
            title: item.title,
            coverUrl: item.coverUrl,
            description: item.description,
            totalCount: item.videoCount,
            previewVideos: const <CreatorVideo>[],
          ),
          publicContentService: _publicContentService,
          videoService: _videoService,
        ),
      ),
    );
  }

  /// 显示统一三秒提示，不更改订阅关系。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 创建订阅合集封面并限制缓存尺寸，失败时显示本地图标。
  Widget _buildCover(SubscribedCollection item) {
    if (item.coverUrl.isEmpty) {
      return _buildCoverPlaceholder();
    }
    return CachedNetworkImage(
      imageUrl: item.coverUrl,
      httpHeaders: const <String, String>{
        'Referer': 'https://www.bilibili.com/',
      },
      width: 152,
      height: 94,
      fit: BoxFit.cover,
      memCacheWidth: 480,
      maxWidthDiskCache: 720,
      placeholder: (BuildContext context, String value) =>
          _buildCoverPlaceholder(),
      errorWidget: (BuildContext context, String value, Object error) =>
          _buildCoverPlaceholder(),
    );
  }

  /// 创建封面加载中或失败时的固定尺寸占位。
  Widget _buildCoverPlaceholder() {
    return const SizedBox(
      width: 152,
      height: 94,
      child: ColoredBox(
        color: Colors.black12,
        child: Icon(Icons.collections_bookmark_outlined),
      ),
    );
  }

  /// 根据账号服务失败类型选择状态图标与重试入口。
  Widget _buildStatus(AccountDataPage<SubscribedCollection> page) {
    final IconData icon = switch (page.status) {
      AccountDataLoadStatus.signedOut ||
      AccountDataLoadStatus.expired => Icons.login_rounded,
      AccountDataLoadStatus.networkError => Icons.wifi_off_rounded,
      AccountDataLoadStatus.permissionDenied => Icons.lock_outline_rounded,
      _ => Icons.error_outline_rounded,
    };
    return Center(
      key: Key('subscribed-collections-status-${page.status.name}'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 46),
            const SizedBox(height: 12),
            Text(
              page.message ?? '暂时无法读取订阅合集，请稍后重试。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              // 状态重试按钮函数重新读取第 1 页订阅合集。
              onPressed: _loading ? null : _loadFirstPage,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建服务成功但当前账号没有订阅合集时的空状态。
  Widget _buildEmpty(AccountDataPage<SubscribedCollection> page) {
    return Center(
      key: const Key('subscribed-collections-empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.collections_bookmark_outlined, size: 46),
            const SizedBox(height: 12),
            const Text('当前页没有 UGC 合集'),
            if (page.hasMore) ...<Widget>[
              const SizedBox(height: 12),
              OutlinedButton(
                // 继续查找按钮函数跳过普通收藏夹并读取下一页订阅数据。
                onPressed: _loadingMore ? null : _loadMore,
                child: Text(_loadingMore ? '正在查找…' : '继续查找订阅合集'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 按合集标题、UP 主昵称或简介筛选当前已加载的订阅合集。
  List<SubscribedCollection> _filteredCollections() {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return _collections;
    }
    return _collections
        .where(
          (SubscribedCollection item) =>
              item.title.toLowerCase().contains(query) ||
              item.ownerName.toLowerCase().contains(query) ||
              item.description.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  /// 创建订阅合集搜索框，输入变化不会触发订阅关系写操作。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: TextField(
        key: const Key('subscribed-collections-search'),
        controller: _searchController,
        onChanged: (String value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          hintText: '搜索合集或 UP 主',
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  /// 创建订阅合集卡片列表和自动分页底部加载器。
  Widget _buildList() {
    final List<SubscribedCollection> visibleCollections =
        _filteredCollections();
    return RefreshIndicator(
      // 下拉刷新函数重新读取第 1 页订阅合集。
      onRefresh: _loadFirstPage,
      child: ListView.separated(
        key: const Key('subscribed-collections-list'),
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: visibleCollections.length + 1,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 10),
        itemBuilder: (BuildContext context, int index) {
          if (index == visibleCollections.length) {
            if (visibleCollections.isEmpty && _searchQuery.trim().isNotEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text('没有匹配的订阅合集')),
              );
            }
            return _loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const SizedBox(height: 8);
          }
          final SubscribedCollection item = visibleCollections[index];
          return Card(
            key: Key('subscribed-collection-${item.id}'),
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              // 订阅合集卡点击函数进入只读合集详情。
              onTap: () => unawaited(_openCollection(item)),
              child: Row(
                children: <Widget>[
                  _buildCover(item),
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
                          '${item.videoCount} 支视频 · ${item.ownerName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 根据首次加载、失败、空列表和成功状态选择页面主体。
  Widget _buildBody() {
    if (_loading && _page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final AccountDataPage<SubscribedCollection>? page = _page;
    if (page == null) {
      return _buildStatus(AccountDataPage<SubscribedCollection>.unavailable());
    }
    if (!page.isSuccess) {
      return _buildStatus(page);
    }
    if (_collections.isEmpty) {
      return _buildEmpty(page);
    }
    return _buildList();
  }

  /// 创建标题明确的“我的订阅”页面，内容只包含 UGC 合集。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的订阅'),
        actions: <Widget>[
          IconButton(
            // 顶部刷新函数只重新读取订阅合集，不执行取消订阅。
            onPressed: _loading ? null : () => unawaited(_loadFirstPage()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新订阅合集',
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
