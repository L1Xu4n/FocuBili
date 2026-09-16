import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../models/app_favorite.dart';
import '../../services/app_favorites_service.dart';
import 'app_favorite_detail_page.dart';

/// 展示本机软件收藏夹列表，支持新建、重命名、删除和进入详情。
class AppFavoriteFoldersPage extends StatefulWidget {
  /// 创建软件收藏夹列表页；服务可注入以支持测试。
  const AppFavoriteFoldersPage({super.key, this.favoritesService});

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

  /// 初始化服务并在首次进入时读取一次软件收藏夹。
  @override
  void initState() {
    super.initState();
    _favoritesService = widget.favoritesService ?? AppFavoritesService();
    unawaited(_loadFolders());
  }

  /// 读取全部软件收藏夹；失败时保留上一次成功显示的数据。
  Future<void> _loadFolders() async {
    final List<AppFavoriteFolder> folders = await _favoritesService
        .loadFolders();
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      _folders = folders;
    });
  }

  /// 打开软件收藏夹详情页，返回后刷新列表中的数量展示。
  Future<void> _openFolder(AppFavoriteFolder folder) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            AppFavoriteDetailPage(folder: folder),
      ),
    );
    if (mounted) {
      unawaited(_loadFolders());
    }
  }

  /// 请求输入新软件收藏夹名称并创建，成功后刷新列表。
  Future<void> _createFolder() async {
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
  }

  /// 请求输入新名称并重命名指定软件收藏夹。
  Future<void> _renameFolder(AppFavoriteFolder folder) async {
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
  }

  /// 确认后删除软件收藏夹及其中的全部视频。
  Future<void> _deleteFolder(AppFavoriteFolder folder) async {
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
            content: TextField(
              key: const Key('app-favorite-folder-name-input'),
              autofocus: true,
              maxLength: 20,
              controller: TextEditingController(text: initialValue),
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 构建收藏夹列表主体，空列表时给出创建引导。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('软件收藏夹'),
        actions: <Widget>[
          IconButton(
            key: const Key('create-app-favorite-folder'),
            tooltip: '新建软件收藏夹',
            onPressed: _createFolder,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: AdaptivePageFrame(maxWidth: 1180, child: _buildBody()),
    );
  }

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
            const SizedBox(height: 4),
            const Text('在看视频时收藏，离线保存在本机。'),
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
    return ListView.separated(
      itemCount: _folders.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final AppFavoriteFolder folder = _folders[index];
        return ListTile(
          key: Key('app-favorite-folder-${folder.id}'),
          leading: const Icon(Icons.folder_rounded),
          title: Text(folder.name),
          trailing: PopupMenuButton<_FolderAction>(
            onSelected: (_FolderAction action) {
              switch (action) {
                case _FolderAction.rename:
                  unawaited(_renameFolder(folder));
                case _FolderAction.delete:
                  unawaited(_deleteFolder(folder));
              }
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<_FolderAction>>[
                  PopupMenuItem<_FolderAction>(
                    value: _FolderAction.rename,
                    child: Text('重命名'),
                  ),
                  PopupMenuItem<_FolderAction>(
                    value: _FolderAction.delete,
                    child: Text('删除'),
                  ),
                ],
          ),
          onTap: () => unawaited(_openFolder(folder)),
        );
      },
    );
  }
}

/// 收藏夹长按菜单里可执行的本机操作。
enum _FolderAction { rename, delete }
