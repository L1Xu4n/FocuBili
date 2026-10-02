import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../core/router/app_router.dart';
import '../../models/app_favorite.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/bilibili_service.dart';
import 'app_favorite_detail_page.dart';
import 'app_favorite_import_page.dart';
import 'favorite_folder_card.dart';
import 'app_favorite_video_tile.dart';

/// 保存收藏夹管理菜单的两个明确动作。
enum _FolderMenuAction { rename, delete }

/// 展示本机软件收藏夹列表，支持新建、重命名、删除和进入详情。
class AppFavoriteFoldersPage extends StatefulWidget {
  /// 创建软件收藏夹列表页；服务可注入以支持测试。
  const AppFavoriteFoldersPage({
    super.key,
    this.favoritesService,
    this.bilibiliService,
    this.accountService,
  });
  final BilibiliService? bilibiliService;
  final BilibiliAccountDataService? accountService;

  /// 可选的软件收藏夹服务，未传入时使用设备默认实现。
  final AppFavoritesService? favoritesService;

  /// 创建管理文件夹加载与新建弹窗的状态对象。
  @override
  State<AppFavoriteFoldersPage> createState() => _AppFavoriteFoldersPageState();
}

/// 管理软件收藏夹列表的读取、新建和删除行为。
class _AppFavoriteFoldersPageState extends State<AppFavoriteFoldersPage> {
  late final AppFavoritesService _favoritesService;
  List<AppFavoriteFolder> _folders = const <AppFavoriteFolder>[];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  Map<String, List<AppFavoriteItem>> _items = {};

  /// 初始化服务并在首次进入时读取一次软件收藏夹。
  @override
  void initState() {
    super.initState();
    _favoritesService = widget.favoritesService ?? AppFavoritesService();
    unawaited(_loadFolders());
  }

  /// 读取全部软件收藏夹；失败时保留上一次成功显示的数据。
  Future<void> _loadFolders() async {
    try {
      final List<AppFavoriteFolder> folders = await _favoritesService
          .loadFolders();
      final items = <String, List<AppFavoriteItem>>{};
      for (final folder in folders) {
        items[folder.id] = await _favoritesService.loadItems(folder.id);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _folders = folders;
        _items = items;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// Releases the favorite-video search controller when leaving the page.
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 打开软件收藏夹详情页，返回后刷新列表中的数量展示。
  Future<void> _openFolder(AppFavoriteFolder folder) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AppFavoriteDetailPage(
          folder: folder,
          favoritesService: _favoritesService,
          bilibiliService: widget.bilibiliService,
        ),
      ),
    );
    if (mounted) {
      unawaited(_loadFolders());
    }
  }

  /// 打开 B 站收藏导入页，返回后刷新文件夹及其中的已导入数量。
  Future<void> _openImport() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => AppFavoriteImportPage(
          favoritesService: _favoritesService,
          accountService: widget.accountService,
        ),
      ),
    );
    if (mounted) await _loadFolders();
  }

  /// Opens a matched video directly with complete online metadata when available.
  Future<void> _openVideo(AppFavoriteItem item) async {
    try {
      final preview =
          await (widget.bilibiliService ?? BilibiliVideoInfoService())
              .lookupVideo(item.bvid);
      if (!mounted) return;
      await Navigator.of(
        context,
      ).pushNamed(AppRoutes.player, arguments: preview);
      if (mounted) await _loadFolders();
    } catch (_) {
      if (mounted) _showMessage('无法打开视频，请检查网络后重试。');
    }
  }

  /// Searches all folders by video metadata, deduplicating videos shared by folders.
  Widget _buildVideoResults(String query) {
    final matches = <String, AppFavoriteItem>{};
    final folders = <String, List<String>>{};
    for (final folder in _folders) {
      for (final item in _items[folder.id] ?? <AppFavoriteItem>[]) {
        if (!item.matchesQuery(query)) continue;
        matches.putIfAbsent(item.bvid, () => item);
        folders.putIfAbsent(item.bvid, () => []).add(folder.name);
      }
    }
    final items = matches.values.toList();
    if (items.isEmpty) return const Center(child: Text('没有匹配的收藏视频'));
    return RefreshIndicator(
      onRefresh: _loadFolders,
      child: AdaptiveTwoColumnList(
        key: const Key('app-favorite-search-results'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: items.length,
        mainAxisSpacing: 8,
        itemBuilder: (context, index) {
          final item = items[index];
          return AppFavoriteVideoTile(
            key: Key('app-favorite-result-${item.bvid}'),
            item: item,
            loadPartCount: () => _favoritesService.resolvePartCount(
              item,
              (widget.bilibiliService ?? BilibiliVideoInfoService())
                  .lookupVideo,
            ),
            folderNames: folders[item.bvid]!.join(' / '),
            onTap: () => unawaited(_openVideo(item)),
          );
        },
      ),
    );
  }

  /// 请求输入新软件收藏夹名称并创建，成功后刷新列表。
  Future<void> _createFolder() async {
    try {
      final String? name = await _showNameDialog(title: '新建软件收藏夹');
      if (name == null || !mounted) {
        return;
      }
      final AppFavoriteFolder? folder = await _favoritesService.createFolder(
        name,
      );
      if (!mounted) {
        return;
      }
      if (folder == null) {
        _showMessage('创建失败，请稍后重试。');
        return;
      }
      unawaited(_loadFolders());
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// 请求输入新名称并重命名指定软件收藏夹。
  Future<void> _renameFolder(AppFavoriteFolder folder) async {
    try {
      final String? name = await _showNameDialog(
        title: '重命名软件收藏夹',
        initialValue: folder.name,
      );
      if (name == null || !mounted) {
        return;
      }
      final bool saved = await _favoritesService.renameFolder(folder.id, name);
      if (!mounted) {
        return;
      }
      if (!saved) {
        _showMessage('重命名失败，请稍后重试。');
        return;
      }
      unawaited(_loadFolders());
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// 确认后删除软件收藏夹及其中的全部视频。
  Future<void> _deleteFolder(AppFavoriteFolder folder) async {
    try {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('删除软件收藏夹'),
          content: Text('将删除“${folder.name}”及其中收藏的全部视频，且无法恢复。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
      final bool deleted = await _favoritesService.deleteFolder(folder.id);
      if (!mounted) {
        return;
      }
      if (!deleted) {
        _showMessage('删除失败，请稍后重试。');
        return;
      }
      unawaited(_loadFolders());
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('本机数据操作失败，请重试；未覆盖损坏的记录。');
      }
    }
  }

  /// 弹出统一的新建或重命名输入框，空名称时禁用确认按钮。
  Future<String?> _showNameDialog({
    required String title,
    String initialValue = '',
  }) {
    String value = initialValue.trim();
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          return AlertDialog(
            title: Text(title),
            // TextFormField owns a stable controller for this dialog.
            content: TextFormField(
              key: const Key('app-favorite-folder-name-input'),
              autofocus: true,
              maxLength: 20,
              initialValue: initialValue,
              decoration: const InputDecoration(hintText: '输入收藏夹名称'),
              onChanged: (String input) {
                setDialogState(() => value = input.trim());
              },
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('confirm-app-favorite-folder-name'),
                onPressed: value.isEmpty
                    ? null
                    : () => Navigator.of(dialogContext).pop(value),
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Shows recoverable local-storage errors without discarding existing data.
  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 构建收藏夹列表主体，空列表时给出创建引导。
  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < 520 ||
        MediaQuery.textScalerOf(context).scale(14) > 18;
    return Scaffold(
      appBar: AppBar(
        title: const Text('软件收藏夹'),
        actions: <Widget>[
          if (!compact) _buildImportAction(),
          IconButton(
            key: const Key('create-app-favorite-folder'),
            tooltip: '新建软件收藏夹',
            onPressed: _createFolder,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: AdaptivePageFrame(
        maxWidth: 1180,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
              child: TextField(
                key: const Key('app-favorite-folders-search'),
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '搜索收藏视频、UP 主或 BV 号',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(_searchController.clear),
                        ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            if (compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    Text(
                      '共 ${_folders.length} 个收藏夹',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    _buildImportAction(),
                  ],
                ),
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  /// 在顶栏或手机工具区提供相同的文字导入入口，避免挤压页面标题。
  Widget _buildImportAction() => TextButton.icon(
    key: const Key('import-bilibili-favorites'),
    onPressed: _openImport,
    icon: const Icon(Icons.download_outlined),
    label: const Text('从 B 站导入'),
  );

  /// 将偶尔使用的管理动作放入具有完整触摸面积的菜单，给收藏夹名称留出空间。
  Widget _buildFolderActions(AppFavoriteFolder folder) =>
      PopupMenuButton<_FolderMenuAction>(
        key: Key('app-favorite-actions-${folder.id}'),
        tooltip: '管理收藏夹',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (action) {
          switch (action) {
            case _FolderMenuAction.rename:
              unawaited(_renameFolder(folder));
            case _FolderMenuAction.delete:
              unawaited(_deleteFolder(folder));
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            key: Key('rename-app-favorite-${folder.id}'),
            value: _FolderMenuAction.rename,
            child: const Text('重命名'),
          ),
          PopupMenuItem(
            key: Key('delete-app-favorite-${folder.id}'),
            value: _FolderMenuAction.delete,
            child: const Text('删除收藏夹'),
          ),
        ],
      );

  /// Displays the current folder collection or its empty state.
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.bookmark_add_outlined, size: 56),
            const SizedBox(height: 12),
            const Text('还没有软件收藏夹'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _createFolder,
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建收藏夹'),
            ),
          ],
        ),
      );
    }
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) return _buildVideoResults(query);
    final folders = _folders;
    return RefreshIndicator(
      onRefresh: _loadFolders,
      child: AdaptiveTwoColumnList(
        key: const Key('app-favorite-folders-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: folders.length,
        mainAxisSpacing: 8,
        itemBuilder: (BuildContext context, int index) {
          final AppFavoriteFolder folder = folders[index];
          final items = _items[folder.id] ?? const <AppFavoriteItem>[];
          final covers = items.where((item) => item.coverUrl.isNotEmpty);
          return FavoriteFolderCard(
            key: Key('app-favorite-folder-${folder.id}'),
            title: folder.name,
            count: items.length,
            coverUrl: covers.isEmpty ? '' : covers.first.coverUrl,
            actions: _buildFolderActions(folder),
            onTap: () => unawaited(_openFolder(folder)),
          );
        },
      ),
    );
  }
}
