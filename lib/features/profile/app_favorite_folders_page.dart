import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../models/account_collection.dart';
import '../../models/app_favorite.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_account_data_service.dart';
import 'app_favorite_detail_page.dart';

/// 展示软件内独立收藏夹列表，并提供新建、导入导出和进入详情操作。
///
/// 本页数据只保存在当前设备，不写入 B 站账号；“从B站收藏夹导入”会把
/// 原账号收藏内容复制到本机收藏夹，不会修改或删除账号数据。
class AppFavoriteFoldersPage extends StatefulWidget {
  /// 创建软件收藏夹列表页；服务可注入以支持测试和安全替换。
  const AppFavoriteFoldersPage({
    super.key,
    this.favoritesService,
    this.accountDataService,
  });

  /// 可选的软件收藏夹服务，未传入时使用设备默认存储。
  final AppFavoritesService? favoritesService;

  /// 可选的 B 站账号数据服务，未传入时复用当前登录会话的默认服务。
  final BilibiliAccountDataService? accountDataService;

  /// 创建管理收藏夹读取、导入导出和进入详情行为的状态对象。
  @override
  State<AppFavoriteFoldersPage> createState() => _AppFavoriteFoldersPageState();
}

/// 标识收藏夹列表页“更多”菜单中可执行的操作。
enum _AppFavoriteMenuAction { importFromAccount, exportFile, importFile }

/// 管理软件收藏夹的读取、新建、导入导出和打开详情行为。
class _AppFavoriteFoldersPageState extends State<AppFavoriteFoldersPage> {
  late final AppFavoritesService _favoritesService;
  late final BilibiliAccountDataService _accountDataService;
  List<AppFavoriteFolder> _folders = const <AppFavoriteFolder>[];
  bool _isLoading = true;
  bool _busy = false;
  bool _importingAccountFolders = false;

  /// 创建页面服务并在首次进入时读取一次本机收藏夹。
  @override
  void initState() {
    super.initState();
    _favoritesService = widget.favoritesService ?? AppFavoritesService();
    _accountDataService =
        widget.accountDataService ?? BilibiliAccountDataService();
    unawaited(_loadFolders());
  }

  /// 读取本机收藏夹列表，失败时保留上一次成功显示的数据。
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

  /// 读取每个收藏夹的条目数量，并生成可展示的摘要文本。
  Future<Map<String, int>> _loadFolderItemCounts() async {
    final Map<String, int> counts = <String, int>{};
    for (final AppFavoriteFolder folder in _folders) {
      counts[folder.id] = (await _favoritesService.loadItems(folder.id)).length;
    }
    return counts;
  }

  /// 请求输入新收藏夹名称并创建；空名称时直接放弃。
  Future<void> _createFolder() async {
    final String? name = await _showFolderNameDialog(title: '新建收藏夹');
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
      _showMessage('收藏夹数量已达上限或名称无效。');
      return;
    }
    await _loadFolders();
    _showMessage('已创建收藏夹“${folder.name}”');
  }

  /// 请求输入新名称并重命名指定收藏夹。
  Future<void> _renameFolder(AppFavoriteFolder folder) async {
    final String? name = await _showFolderNameDialog(
      title: '重命名收藏夹',
      initialName: folder.name,
    );
    if (name == null || !mounted) {
      return;
    }
    final bool renamed = await _favoritesService.renameFolder(folder.id, name);
    if (!mounted) {
      return;
    }
    if (!renamed) {
      _showMessage('重命名失败，请稍后重试。');
      return;
    }
    await _loadFolders();
    _showMessage('已重命名为“${name.trim()}”');
  }

  /// 确认后删除指定收藏夹及其全部条目。
  Future<void> _deleteFolder(AppFavoriteFolder folder) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除收藏夹'),
        content: Text('将删除“${folder.name}”及其全部收藏条目，且无法恢复。'),
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
    await _loadFolders();
    _showMessage('已删除收藏夹“${folder.name}”');
  }

  /// 展示统一名称输入对话框，空名称时禁用确认按钮。
  Future<String?> _showFolderNameDialog({
    required String title,
    String initialName = '',
  }) {
    String value = initialName;
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          return AlertDialog(
            title: Text(title),
            content: TextField(
              key: const Key('app-favorite-folder-name'),
              autofocus: true,
              maxLength: 20,
              controller: TextEditingController(text: value),
              decoration: const InputDecoration(hintText: '输入收藏夹名称'),
              onChanged: (String text) {
                setDialogState(() => value = text.trim());
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

  /// 打开指定收藏夹的详情页，返回后刷新数量和列表。
  Future<void> _openFolder(AppFavoriteFolder folder) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AppFavoriteDetailPage(
          folder: folder,
          favoritesService: _favoritesService,
          accountDataService: _accountDataService,
        ),
      ),
    );
    if (mounted) {
      await _loadFolders();
    }
  }

  /// 分发收藏夹列表页“更多”菜单操作。
  Future<void> _handleMenuAction(_AppFavoriteMenuAction action) async {
    switch (action) {
      case _AppFavoriteMenuAction.importFromAccount:
        await _importFromAccountFolders();
      case _AppFavoriteMenuAction.exportFile:
        await _exportToFile();
      case _AppFavoriteMenuAction.importFile:
        await _importFromFile();
    }
  }

  /// 读取 B 站账号收藏夹并复制到本机同名收藏夹，不修改账号数据。
  Future<void> _importFromAccountFolders() async {
    if (_busy || _importingAccountFolders) {
      return;
    }
    setState(() => _importingAccountFolders = true);
    final AccountDataPage<FavoriteFolder> page = await _accountDataService
        .loadFavoriteFolders();
    if (!mounted) {
      return;
    }
    setState(() => _importingAccountFolders = false);
    if (!page.isSuccess) {
      _showMessage(page.message ?? '暂时无法读取 B 站收藏夹，请稍后重试。');
      return;
    }
    if (page.items.isEmpty) {
      _showMessage('当前账号还没有可导入的 B 站收藏夹。');
      return;
    }
    final Set<int>? selected = await _showAccountFolderPicker(page.items);
    if (selected == null || selected.isEmpty || !mounted) {
      return;
    }
    final List<FavoriteFolder> targets = page.items
        .where((FavoriteFolder folder) => selected.contains(folder.mediaId))
        .toList(growable: false);
    setState(() => _busy = true);
    int folderCount = 0;
    int itemCount = 0;
    try {
      for (final FavoriteFolder folder in targets) {
        final AppFavoriteFolder? target = await _findOrCreateFolderByName(
          folder.title,
        );
        if (target == null) {
          continue;
        }
        final String targetFolderId = target.id;
        int pageNumber = 1;
        var hasMore = true;
        while (hasMore && mounted) {
          final AccountDataPage<FavoriteVideo> videos =
              await _accountDataService.loadFavoriteVideos(
                folder.mediaId,
                page: pageNumber,
              );
          if (!videos.isSuccess) {
            break;
          }
          final int added = await _favoritesService.importItems(
            targetFolderId,
            videos.items
                .map(
                  (FavoriteVideo video) => AppFavoriteItem(
                    folderId: targetFolderId,
                    bvid: video.bvid,
                    title: video.title,
                    coverUrl: video.coverUrl,
                    ownerName: video.ownerName,
                    durationText: _formatDuration(video.duration),
                    addedAt: video.favoritedAt ?? DateTime.now(),
                    sourceLabel: 'B站收藏夹：${folder.title}',
                  ),
                )
                .toList(growable: false),
          );
          itemCount += added;
          hasMore = videos.hasMore;
          pageNumber += 1;
        }
        if (mounted) {
          final bool isNewFolder = _folders
              .where((AppFavoriteFolder existing) => existing.id == target.id)
              .isEmpty;
          if (isNewFolder) {
            folderCount += 1;
          }
        }
      }
    } on Object {
      // 单个收藏夹读取失败时保留已成功导入的内容，并向用户说明。
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _loadFolders();
      }
    }
    if (!mounted) {
      return;
    }
    if (folderCount == 0 && itemCount == 0) {
      _showMessage('这些 B 站收藏夹此前已导入，没有新增内容。');
    } else {
      _showMessage('已导入 $folderCount 个收藏夹，共 $itemCount 条视频。');
    }
  }

  /// 在软件收藏夹中查找同名目录，不存在时自动创建。
  Future<AppFavoriteFolder?> _findOrCreateFolderByName(String name) async {
    final List<AppFavoriteFolder> folders = await _favoritesService
        .loadFolders();
    for (final AppFavoriteFolder folder in folders) {
      if (folder.name == name) {
        return folder;
      }
    }
    return _favoritesService.createFolder(name);
  }

  /// 展示 B 站收藏夹多选面板，并返回选中的收藏夹编号集合。
  Future<Set<int>?> _showAccountFolderPicker(List<FavoriteFolder> folders) {
    final Set<int> selected = <int>{};
    return showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.76,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      '从B站收藏夹导入',
                      style: Theme.of(sheetContext).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      itemCount: folders.length,
                      itemBuilder: (BuildContext context, int index) {
                        final FavoriteFolder folder = folders[index];
                        return CheckboxListTile(
                          key: Key('account-folder-${folder.mediaId}'),
                          value: selected.contains(folder.mediaId),
                          controlAffinity: ListTileControlAffinity.trailing,
                          title: Text(folder.title),
                          subtitle: Text('${folder.mediaCount} 个视频'),
                          onChanged: (bool? value) {
                            setSheetState(() {
                              if (value ?? false) {
                                selected.add(folder.mediaId);
                              } else {
                                selected.remove(folder.mediaId);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const Key('confirm-import-account-folders'),
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.of(
                                  sheetContext,
                                ).pop(Set<int>.of(selected)),
                          child: Text('导入 ${selected.length} 个'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 把本机收藏数据导出为 JSON 文件并交给系统分享面板。
  Future<void> _exportToFile() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String jsonText = await _favoritesService.exportJson();
      final Directory directory = await getTemporaryDirectory();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final DateTime now = DateTime.now();
      final String stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}';
      final String fileName = 'FocuBili收藏夹-$stamp.json';
      final File output = File('${directory.path}/$fileName');
      await output.writeAsString(jsonText, flush: true);
      if (!mounted) {
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(output.path, mimeType: 'application/json')],
          fileNameOverrides: <String>[fileName],
          text: '焦点哔哩软件收藏夹备份，共 ${_folders.length} 个收藏夹。',
        ),
      );
    } on Object {
      if (mounted) {
        _showMessage('导出失败，请稍后重试。');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 从 JSON 文件恢复收藏夹，采用合并策略且不覆盖现有数据。
  Future<void> _importFromFile() async {
    if (_busy) {
      return;
    }
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json'],
      dialogTitle: '选择收藏夹备份文件',
    );
    if (result == null || result.files.isEmpty || !mounted) {
      return;
    }
    final String? path = result.files.single.path;
    if (path == null) {
      _showMessage('无法读取所选文件。');
      return;
    }
    setState(() => _busy = true);
    try {
      final String jsonText = await File(path).readAsString();
      final AppFavoriteImportResult imported = await _favoritesService
          .importJson(jsonText);
      if (!mounted) {
        return;
      }
      if (imported.isEmpty) {
        _showMessage('文件中没有可导入的新内容。');
      } else {
        _showMessage(
          '已恢复 ${imported.folderCount} 个收藏夹，'
          '${imported.itemCount} 条视频。',
        );
      }
    } on Object {
      if (mounted) {
        _showMessage('导入失败，请确认文件内容正确。');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _loadFolders();
      }
    }
  }

  /// 把时长格式化为小时分钟秒文本，未知时长返回空字符串。
  String _formatDuration(Duration duration) {
    if (duration <= Duration.zero) {
      return '';
    }
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes % 60;
    final int seconds = duration.inSeconds % 60;
    final String minuteText = minutes.toString().padLeft(2, '0');
    final String secondText = seconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minuteText:$secondText'
        : '$minutes:$secondText';
  }

  /// 显示统一持续三秒的轻量提示。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 创建收藏夹封面占位图，并叠加条目数量角标。
  Widget _buildFolderCard(AppFavoriteFolder folder, int itemCount) {
    return Card(
      key: Key('app-favorite-folder-${folder.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openFolder(folder),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 112,
                height: 70,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: const Center(
                      child: Icon(Icons.star_rounded, color: Colors.black45),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      folder.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$itemCount 个视频',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_AppFavoriteFolderAction>(
                tooltip: '收藏夹操作',
                onSelected: (_AppFavoriteFolderAction action) {
                  switch (action) {
                    case _AppFavoriteFolderAction.rename:
                      unawaited(_renameFolder(folder));
                    case _AppFavoriteFolderAction.delete:
                      unawaited(_deleteFolder(folder));
                  }
                },
                itemBuilder: (BuildContext context) =>
                    const <PopupMenuEntry<_AppFavoriteFolderAction>>[
                      PopupMenuItem<_AppFavoriteFolderAction>(
                        value: _AppFavoriteFolderAction.rename,
                        child: Text('重命名'),
                      ),
                      PopupMenuItem<_AppFavoriteFolderAction>(
                        value: _AppFavoriteFolderAction.delete,
                        child: Text('删除'),
                      ),
                    ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 根据加载状态和空数据创建页面主体。
  Widget _buildBody(Map<String, int> itemCounts) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_folders.isEmpty) {
      return const Center(
        key: Key('app-favorite-folders-empty'),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.star_outline_rounded, size: 44),
              SizedBox(height: 12),
              Text('还没有软件收藏夹'),
              SizedBox(height: 6),
              Text('在看视频时点收藏，或从 B 站账号导入', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return AdaptiveTwoColumnList(
      key: const Key('app-favorite-folders-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _folders.length,
      mainAxisSpacing: 8,
      itemBuilder: (BuildContext context, int index) {
        final AppFavoriteFolder folder = _folders[index];
        return _buildFolderCard(folder, itemCounts[folder.id] ?? 0);
      },
    );
  }

  /// 创建收藏夹页标题、操作菜单和内容区域。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('软件收藏夹'),
        actions: <Widget>[
          IconButton(
            key: const Key('create-app-favorite-folder'),
            tooltip: '新建收藏夹',
            onPressed: _busy ? null : () => unawaited(_createFolder()),
            icon: const Icon(Icons.add_rounded),
          ),
          PopupMenuButton<_AppFavoriteMenuAction>(
            tooltip: '更多操作',
            onSelected: (_AppFavoriteMenuAction action) {
              unawaited(_handleMenuAction(action));
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<_AppFavoriteMenuAction>>[
                  PopupMenuItem<_AppFavoriteMenuAction>(
                    value: _AppFavoriteMenuAction.importFromAccount,
                    child: Text('从B站收藏夹导入'),
                  ),
                  PopupMenuItem<_AppFavoriteMenuAction>(
                    value: _AppFavoriteMenuAction.exportFile,
                    child: Text('导出到文件'),
                  ),
                  PopupMenuItem<_AppFavoriteMenuAction>(
                    value: _AppFavoriteMenuAction.importFile,
                    child: Text('从文件导入'),
                  ),
                ],
          ),
        ],
      ),
      body: AdaptivePageFrame(
        maxWidth: 1180,
        child: Stack(
          children: <Widget>[
            FutureBuilder<Map<String, int>>(
              future: _loadFolderItemCounts(),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<Map<String, int>> snapshot,
                  ) {
                    return _buildBody(snapshot.data ?? const <String, int>{});
                  },
            ),
            if (_busy || _importingAccountFolders)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 标识单个收藏夹可执行的本地操作。
enum _AppFavoriteFolderAction { rename, delete }
