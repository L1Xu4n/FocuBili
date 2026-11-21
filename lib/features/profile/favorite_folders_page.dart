import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../models/account_collection.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_interaction_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/cache_lifecycle.dart';
import 'favorite_videos_page.dart';
import 'favorite_folder_card.dart';

/// 展示当前登录账号创建的收藏夹，并在详情中按权限提供编辑入口。
class FavoriteFoldersPage extends StatefulWidget {
  /// 创建可注入只读账号服务的收藏夹页面，便于测试和安全替换实现。
  const FavoriteFoldersPage({
    super.key,
    this.accountDataService,
    this.interactionService,
    this.onFolderEdited,
    this.bilibiliService,
  });

  /// 可选的账号数据服务，未传入时复用当前 WebView 会话的默认服务。
  final BilibiliAccountDataService? accountDataService;
  final BilibiliInteractionService? interactionService;
  final ValueChanged<FavoriteFolder>? onFolderEdited;

  /// 可选的公开视频详情服务，会传给收藏内容页用于打开可播放视频。
  final BilibiliService? bilibiliService;

  /// 创建管理收藏夹首次读取、刷新、状态和页面跳转的状态对象。
  @override
  State<FavoriteFoldersPage> createState() => _FavoriteFoldersPageState();
}

/// Route-local cache keys use the same process account revision as image bytes.
class _FavoriteFolderSnapshot {
  int _revision = -1;
  AccountDataPage<FavoriteFolder>? page;
  DateTime? fetchedAt;
  final covers = <int, ({String url, int count, DateTime readAt})>{};

  void forRevision(int revision) {
    if (_revision == revision) return;
    _revision = revision;
    page = null;
    fetchedAt = null;
    covers.clear();
  }
}

/// 管理收藏夹列表的只读加载、失败重试和打开内容页行为。
class _FavoriteFoldersPageState extends State<FavoriteFoldersPage> {
  late final BilibiliAccountDataService _accountDataService;
  late final BilibiliService _bilibiliService;
  final TextEditingController _searchController = TextEditingController();
  static const _freshList = Duration(seconds: 30);
  static const _keepList = Duration(minutes: 5);
  static const _freshCover = Duration(minutes: 2);
  static final _defaultSnapshot = _FavoriteFolderSnapshot();
  static final _injectedSnapshots = Expando<_FavoriteFolderSnapshot>(
    'favorite folder snapshots',
  );
  late final _FavoriteFolderSnapshot _snapshot;
  int _request = 0;

  bool _fresh(DateTime? time, Duration duration) {
    if (time == null) return false;
    final age = DateTime.now().difference(time);
    return !age.isNegative && age < duration;
  }

  bool _needsFallback(FavoriteFolder folder) =>
      folder.isAvailable &&
      folder.coverUrl.trim().isEmpty &&
      folder.mediaCount > 0;
  AccountDataPage<FavoriteFolder>? _page;
  bool _isLoading = true;
  String _searchQuery = '';

  /// 初始化注入服务并在用户进入本页时读取一次自己的收藏夹列表。
  @override
  void initState() {
    super.initState();
    _accountDataService =
        widget.accountDataService ?? BilibiliAccountDataService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    final injected = widget.accountDataService;
    _snapshot = injected == null
        ? _defaultSnapshot
        : (_injectedSnapshots[injected] ??= _FavoriteFolderSnapshot());
    final revision = CacheLifecycle.account.value;
    _snapshot.forRevision(revision);
    if (_fresh(_snapshot.fetchedAt, _keepList)) {
      _page = _snapshot.page;
      _isLoading = !_fresh(_snapshot.fetchedAt, _freshList);
    }
    CacheLifecycle.account.addListener(_accountChanged);
    if (_isLoading) {
      unawaited(_loadFolders(force: false));
    } else if (_page case final cached?) {
      final request = _request;
      unawaited(
        _backfillMissingFolderCovers(
          cached.items,
          () =>
              mounted &&
              request == _request &&
              revision == CacheLifecycle.account.value,
          false,
        ),
      );
    }
  }

  void _accountChanged() {
    _request++;
    _snapshot.forRevision(CacheLifecycle.account.value);
    setState(() {
      _isLoading = true;
      _page = null;
    });
    final request = _request;
    scheduleMicrotask(() {
      if (mounted && _request == request) {
        unawaited(_loadFolders(force: false));
      }
    });
  }

  /// 释放收藏夹搜索输入控制器。
  @override
  void dispose() {
    CacheLifecycle.account.removeListener(_accountChanged);
    _searchController.dispose();
    super.dispose();
  }

  /// 读取当前账号收藏夹列表；刷新失败时保留已成功显示的收藏夹。
  Future<void> _loadFolders({bool force = true}) async {
    final int request = ++_request;
    final int revision = CacheLifecycle.account.value;
    bool current() =>
        mounted &&
        request == _request &&
        revision == CacheLifecycle.account.value;

    if (!_isLoading) setState(() => _isLoading = true);
    final AccountDataPage<FavoriteFolder> result = await _accountDataService
        .loadFavoriteFolders();
    if (!current()) return;

    final sessionRejected =
        result.status == AccountDataLoadStatus.signedOut ||
        result.status == AccountDataLoadStatus.expired;
    final keepPreviousList =
        !result.isSuccess && !sessionRejected && _page?.isSuccess == true;
    setState(() {
      _isLoading = false;
      if (!keepPreviousList) _page = result;
      if (result.isSuccess) {
        _snapshot.page = result;
        _snapshot.fetchedAt = DateTime.now();
        final eligible = result.items
            .where(_needsFallback)
            .map((folder) => folder.mediaId)
            .toSet();
        _snapshot.covers.removeWhere((id, _) => !eligible.contains(id));
      } else if (sessionRejected) {
        _snapshot.page = null;
        _snapshot.fetchedAt = null;
        _snapshot.covers.clear();
      }
    });
    if (keepPreviousList) {
      if (force) _showMessage(result.message ?? '刷新收藏夹失败，请稍后重试。');
    } else if (result.isSuccess) {
      unawaited(_backfillMissingFolderCovers(result.items, current, force));
    }
  }

  /// Reuse fallback URLs until expiry or a changed folder count. A transient
  /// failure leaves the last cover visible; an authoritative empty result clears it.
  Future<void> _backfillMissingFolderCovers(
    List<FavoriteFolder> folders,
    bool Function() current,
    bool force,
  ) async {
    final missing = folders
        .where((folder) {
          if (!_needsFallback(folder)) return false;
          final cover = _snapshot.covers[folder.mediaId];
          return force ||
              cover?.count != folder.mediaCount ||
              !_fresh(cover?.readAt, _freshCover);
        })
        .toList(growable: false);

    for (int offset = 0; offset < missing.length && current(); offset += 3) {
      final int end = (offset + 3).clamp(0, missing.length).toInt();
      final results = await Future.wait(
        missing.sublist(offset, end).map((folder) async {
          final page = await _accountDataService.loadFavoriteVideos(
            folder.mediaId,
          );
          if (!page.isSuccess) return null;
          final cover =
              page.items
                  .where(
                    (video) =>
                        video.isAvailable && video.coverUrl.trim().isNotEmpty,
                  )
                  .firstOrNull
                  ?.coverUrl ??
              '';
          return (id: folder.mediaId, count: folder.mediaCount, url: cover);
        }),
      );
      if (!current()) return;
      setState(() {
        for (final result in results.nonNulls) {
          _snapshot.covers[result.id] = (
            url: result.url,
            count: result.count,
            readAt: DateTime.now(),
          );
        }
      });
    }
  }

  /// 打开可用收藏夹内容页；失效收藏夹只提示原因。
  Future<void> _openFolder(FavoriteFolder folder) async {
    if (!folder.isAvailable) {
      _showMessage('该收藏夹已失效，暂时无法读取内容。');
      return;
    }
    final revision = CacheLifecycle.account.value;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 详情页复用只读列表；明确保存时才进入独立互动服务。
        builder: (BuildContext context) => FavoriteVideosPage(
          folder: folder,
          editableOwnerMid: folder.ownerMid,
          interactionService: widget.interactionService,
          onFolderEdited: (updated) {
            final page = _page;
            if (!mounted ||
                revision != CacheLifecycle.account.value ||
                page == null ||
                !page.isSuccess) {
              return;
            }
            _request++;
            setState(() {
              _isLoading = false;
              _page = _snapshot.page = AccountDataPage.success(
                items: [
                  for (final item in page.items)
                    if (item.mediaId == updated.mediaId) updated else item,
                ],
                page: page.page,
                hasMore: page.hasMore,
                totalCount: page.totalCount,
              );
            });
            widget.onFolderEdited?.call(updated);
          },
          accountDataService: _accountDataService,
          bilibiliService: _bilibiliService,
        ),
      ),
    );
  }

  /// 显示统一持续三秒的轻量提示，不影响当前已加载的收藏夹状态。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 按收藏夹名称筛选当前已加载列表，搜索不触发额外账号请求。
  List<FavoriteFolder> _filteredFolders(List<FavoriteFolder> folders) {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return folders;
    }
    return folders
        .where(
          (FavoriteFolder folder) => folder.title.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  /// 创建收藏夹名称搜索框，并在输入时即时刷新本地筛选结果。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: TextField(
        key: const Key('favorite-folders-search'),
        controller: _searchController,
        onChanged: (String value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          hintText: '搜索收藏夹',
          prefixIcon: const Icon(Icons.search_rounded),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  /// 创建所有账号数据失败状态的说明和重试入口，避免将失败显示为空收藏夹。
  Widget _buildStatusState(AccountDataPage<FavoriteFolder> page) {
    final IconData icon;
    switch (page.status) {
      case AccountDataLoadStatus.success:
        icon = Icons.star_outline_rounded;
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
      key: Key('favorite-folders-status-${page.status.name}'),
      child: SingleChildScrollView(
        key: const Key('favorite-folders-status-scroll'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 44),
              const SizedBox(height: 12),
              Text(
                page.message ?? '暂时无法读取收藏夹，请稍后重试。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('favorite-folders-retry'),
                // 重试按钮函数只重新读取当前账号的收藏夹列表。
                onPressed: _isLoading ? null : _loadFolders,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建服务已成功返回但账号没有任何收藏夹时的空状态。
  Widget _buildEmptyState() {
    return const Center(
      key: Key('favorite-folders-empty'),
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.star_outline_rounded, size: 44),
            SizedBox(height: 12),
            Text('还没有收藏夹'),
          ],
        ),
      ),
    );
  }

  /// 创建自适应收藏夹卡片列表，固定封面比例并为窄屏标题保留完整弹性空间。
  Widget _buildFolderList(List<FavoriteFolder> folders) {
    return RefreshIndicator(
      // 下拉刷新函数只重新读取收藏夹列表，不新增、删除或修改收藏夹。
      onRefresh: _loadFolders,
      child: AdaptiveTwoColumnList(
        key: const Key('favorite-folders-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: folders.length,
        mainAxisSpacing: 8,
        itemBuilder: (BuildContext context, int index) {
          final FavoriteFolder folder = folders[index];
          return FavoriteFolderCard(
            key: Key('favorite-folder-${folder.mediaId}'),
            title: folder.title,
            count: folder.mediaCount,
            available: folder.isAvailable,
            isPrivate: folder.isPrivate,
            coverUrl: folder.coverUrl.isNotEmpty
                ? folder.coverUrl
                : (_snapshot.covers[folder.mediaId]?.url ?? ''),
            onTap: () => _openFolder(folder),
          );
        },
      ),
    );
  }

  /// 根据首次加载、错误、空和正常收藏夹列表选择页面主体。
  Widget _buildBody() {
    if (_isLoading && _page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final AccountDataPage<FavoriteFolder>? page = _page;
    if (page == null) {
      return _buildStatusState(AccountDataPage<FavoriteFolder>.unavailable());
    }
    if (!page.isSuccess) {
      return _buildStatusState(page);
    }
    if (page.isEmpty) {
      return _buildEmptyState();
    }
    final List<FavoriteFolder> folders = _filteredFolders(page.items);
    if (folders.isEmpty && _searchQuery.trim().isNotEmpty) {
      return const Center(child: Text('没有匹配的收藏夹'));
    }
    return _buildFolderList(folders);
  }

  /// 创建收藏夹页标题、刷新入口和随加载状态变化的内容区域。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
        actions: <Widget>[
          IconButton(
            // 刷新按钮函数只请求只读收藏夹列表，不会执行收藏或取消收藏。
            onPressed: _isLoading ? null : () => unawaited(_loadFolders()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新收藏夹',
          ),
        ],
      ),
      body: AdaptivePageFrame(
        maxWidth: 1180,
        child: Column(
          children: <Widget>[
            _buildSearchField(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }
}
