import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/account_collection.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_service.dart';
import 'favorite_videos_page.dart';

/// 展示当前登录账号创建的收藏夹，并只允许用户进入查看其内容。
class FavoriteFoldersPage extends StatefulWidget {
  /// 创建可注入只读账号服务的收藏夹页面，便于测试和安全替换实现。
  const FavoriteFoldersPage({
    super.key,
    this.accountDataService,
    this.bilibiliService,
  });

  /// 可选的账号数据服务，未传入时复用当前 WebView 会话的默认服务。
  final BilibiliAccountDataService? accountDataService;

  /// 可选的公开视频详情服务，会传给收藏内容页用于打开可播放视频。
  final BilibiliService? bilibiliService;

  /// 创建管理收藏夹首次读取、刷新、状态和页面跳转的状态对象。
  @override
  State<FavoriteFoldersPage> createState() => _FavoriteFoldersPageState();
}

/// 管理收藏夹列表的只读加载、失败重试和打开内容页行为。
class _FavoriteFoldersPageState extends State<FavoriteFoldersPage> {
  late final BilibiliAccountDataService _accountDataService;
  late final BilibiliService _bilibiliService;
  AccountDataPage<FavoriteFolder>? _page;
  bool _isLoading = true;

  /// 初始化注入服务并在用户进入本页时读取一次自己的收藏夹列表。
  @override
  void initState() {
    super.initState();
    _accountDataService =
        widget.accountDataService ?? BilibiliAccountDataService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    unawaited(_loadFolders());
  }

  /// 读取当前账号收藏夹列表；刷新失败时保留已成功显示的收藏夹。
  Future<void> _loadFolders() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }
    final AccountDataPage<FavoriteFolder> result =
        await _accountDataService.loadFavoriteFolders();
    if (!mounted) {
      return;
    }
    final bool keepPreviousList = !result.isSuccess && _page?.isSuccess == true;
    setState(() {
      _isLoading = false;
      if (result.isSuccess || !keepPreviousList) {
        _page = result;
      }
    });
    if (keepPreviousList) {
      _showMessage(result.message ?? '刷新收藏夹失败，请稍后重试。');
    }
  }

  /// 打开可用收藏夹的只读内容页；失效收藏夹只提示原因，不执行任何请求或写操作。
  Future<void> _openFolder(FavoriteFolder folder) async {
    if (!folder.isAvailable) {
      _showMessage('该收藏夹已失效，暂时无法读取内容。');
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 内容页构建函数复用同一只读账号服务和公开视频详情服务。
        builder: (BuildContext context) => FavoriteVideosPage(
          folder: folder,
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
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// 创建收藏夹封面、加载失败占位图和内容数量角标。
  Widget _buildFolderCover(FavoriteFolder folder) {
    return SizedBox(
      width: 112,
      height: 70,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (folder.coverUrl.isEmpty)
              _buildCoverPlaceholder()
            else
              CachedNetworkImage(
                imageUrl: folder.coverUrl,
                httpHeaders: const <String, String>{
                  'Referer': 'https://www.bilibili.com/',
                },
                fit: BoxFit.cover,
                memCacheWidth: 256,
                maxWidthDiskCache: 512,
                fadeInDuration: const Duration(milliseconds: 120),
                placeholder: (BuildContext context, String url) =>
                    _buildCoverPlaceholder(),
                errorWidget: (
                  BuildContext context,
                  String url,
                  Object error,
                ) =>
                    _buildCoverPlaceholder(),
              ),
            Positioned(
              right: 5,
              bottom: 5,
              child: _buildCountBadge('${folder.mediaCount} 个视频'),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建收藏夹没有封面或封面加载失败时的本地占位图。
  Widget _buildCoverPlaceholder() {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: const Center(
        child: Icon(Icons.star_outline_rounded, color: Colors.black45),
      ),
    );
  }

  /// 创建覆盖在收藏夹封面右下角的半透明内容数量角标。
  Widget _buildCountBadge(String text) {
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

  /// 创建收藏夹卡片列表；点击一个正常收藏夹将进入其内容页。
  Widget _buildFolderList(List<FavoriteFolder> folders) {
    return RefreshIndicator(
      // 下拉刷新函数只重新读取收藏夹列表，不新增、删除或修改收藏夹。
      onRefresh: _loadFolders,
      child: ListView.separated(
        key: const Key('favorite-folders-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: folders.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) {
          final FavoriteFolder folder = folders[index];
          return Card(
            key: Key('favorite-folder-${folder.mediaId}'),
            child: ListTile(
              enabled: folder.isAvailable,
              leading: _buildFolderCover(folder),
              title: Text(
                folder.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                folder.isAvailable ? '${folder.mediaCount} 个视频' : '收藏夹已失效',
              ),
              trailing: Icon(
                folder.isAvailable
                    ? Icons.chevron_right_rounded
                    : Icons.block_rounded,
              ),
              // 收藏夹点击函数只打开内容页，不会改变任何收藏夹数据。
              onTap: () => _openFolder(folder),
            ),
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
      return _buildStatusState(
        AccountDataPage<FavoriteFolder>.unavailable(),
      );
    }
    if (!page.isSuccess) {
      return _buildStatusState(page);
    }
    if (page.isEmpty) {
      return _buildEmptyState();
    }
    return _buildFolderList(page.items);
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
      body: _buildBody(),
    );
  }
}
