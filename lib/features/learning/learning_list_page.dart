import 'package:focubili/features/common/app_network_image.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../models/learning_list_entry.dart';
import '../../models/learning_subject_folder.dart';
import '../../services/bilibili_service.dart';
import '../../services/learning_list_service.dart';
import 'learning_video_launcher.dart';

/// 展示并管理保存在当前设备上的学习任务，不包含账号或云端同步功能。
class LearningListPage extends StatefulWidget {
  /// 创建学习清单页面；测试可注入内存服务和固定视频详情服务。
  const LearningListPage({
    super.key,
    this.learningListService,
    this.videoService,
  });

  final LearningListService? learningListService;
  final BilibiliService? videoService;

  /// 创建保存任务列表、搜索、排序和异步操作反馈的页面状态。
  @override
  State<LearningListPage> createState() => _LearningListPageState();
}

/// 管理学习清单的本机读取、搜索、手动排序、状态变更和继续学习操作。
class _LearningListPageState extends State<LearningListPage> {
  late final LearningListService _learningListService;
  late final BilibiliService _videoService;
  late final TextEditingController _searchController;
  List<LearningListEntry> _entries = const <LearningListEntry>[];
  List<LearningSubjectFolder> _folders = const [];
  bool _allFolders = true;
  String? _folderId;
  bool _folderBusy = false;
  String _query = '';
  LearningListStatus? _statusFilter;
  bool _selecting = false;
  final Set<String> _selected = {};
  bool get _canReorder =>
      _query.isEmpty && _statusFilter == null && !_selecting && !_folderBusy;
  bool _searching = false;
  bool _loading = true;
  bool _reordering = false;
  String? _openingStableId;
  String? _updatingStableId;

  /// 初始化服务、搜索控制器并读取设备上已有的学习任务。
  @override
  void initState() {
    super.initState();
    _learningListService = widget.learningListService ?? LearningListService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _searchController = TextEditingController();
    unawaited(_reloadEntries());
  }

  /// 页面销毁时释放搜索控制器，避免输入资源残留在内存中。
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 重新读取本机任务；刷新期间保留旧列表，避免界面突然跳为空白。
  Future<void> _reloadEntries() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    final state = await _learningListService.loadState();
    if (!mounted) {
      return;
    }
    setState(() {
      if (!_learningListService.readFailed) _applyState(state);
      _loading = false;
    });
  }

  /// 打开 AppBar 内的搜索输入框，并让软键盘立即聚焦到学习清单关键词。
  void _openSearch() {
    setState(() => _searching = true);
  }

  /// 关闭搜索、清空关键词并恢复完整学习清单的手动排序能力。
  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _query = '';
      _searching = false;
    });
  }

  /// 更新搜索关键词；只过滤当前已读取的本机任务，不会把关键词发送到网络。
  void _updateQuery(String value) {
    setState(() => _query = value.trim().toLowerCase());
  }

  /// 判断一条任务是否匹配标题、UP 主、分 P 标题或 P 序号的本机搜索词。
  bool _matchesQuery(LearningListEntry entry) {
    if (!_allFolders && entry.folderId != _folderId) return false;
    if (_statusFilter != null && entry.status != _statusFilter) return false;
    if (_query.isEmpty) {
      return true;
    }
    final String haystack = <String>[
      entry.title,
      entry.ownerName,
      entry.partTitle,
      _folderName(entry.folderId),
      'p${entry.partPageNumber}',
    ].join('\n').toLowerCase();
    return haystack.contains(_query);
  }

  /// 返回搜索结果中的未完成任务；服务已保证其为用户手动设定的顺序。
  List<LearningListEntry> get _activeEntries => _entries
      .where(
        (LearningListEntry entry) =>
            entry.status != LearningListStatus.completed &&
            _matchesQuery(entry),
      )
      .toList(growable: false);

  /// 返回搜索结果中的已完成任务；它们始终在页面底部独立分区显示。
  List<LearningListEntry> get _completedEntries => _entries
      .where(
        (LearningListEntry entry) =>
            entry.status == LearningListStatus.completed &&
            _matchesQuery(entry),
      )
      .toList(growable: false);

  /// 查询任务视频详情并打开播放器，返回后刷新可能由播放器更新的学习进度。
  Future<void> _openEntry(LearningListEntry entry) async {
    if (_openingStableId != null || _updatingStableId != null || _reordering) {
      return;
    }
    setState(() => _openingStableId = entry.stableId);
    try {
      await LearningVideoLauncher.open(
        context,
        entry,
        service: _videoService,
        learningListService: _learningListService,
      );
      if (mounted) {
        await _reloadEntries();
      }
    } catch (_) {
      _showSaveError();
    } finally {
      if (mounted) {
        setState(() => _openingStableId = null);
      }
    }
  }

  /// 更新指定视频分 P 的状态，并用服务返回的分区顺序刷新当前页面。
  Future<void> _changeStatus(
    LearningListEntry entry,
    LearningListStatus status,
  ) async {
    if (_updatingStableId != null || entry.status == status || _reordering) {
      return;
    }
    setState(() => _updatingStableId = entry.stableId);
    try {
      final List<LearningListEntry> updated = await _learningListService
          .updateStatus(entry.bvid, status, partCid: entry.partCid);
      if (!mounted) {
        return;
      }
      setState(() => _entries = updated);
    } catch (_) {
      _showSaveError();
    } finally {
      if (mounted) {
        setState(() => _updatingStableId = null);
      }
    }
  }

  /// 询问后移除单个视频分 P，避免误触清掉同一视频的其他学习计划。
  Future<void> _confirmRemove(LearningListEntry entry) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('移出学习清单'),
        content: Text(
          '确定移除“${entry.title}”的 P${entry.partPageNumber} 吗？观看记录和笔记不会被删除。',
        ),
        actions: <Widget>[
          TextButton(
            // 取消函数只关闭确认框，保持学习任务不变。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认函数把决定返回页面，再由本机服务执行只移除当前分 P 的操作。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        _updatingStableId != null ||
        _reordering) {
      return;
    }
    setState(() => _updatingStableId = entry.stableId);
    try {
      final List<LearningListEntry> updated = await _learningListService.remove(
        entry.bvid,
        partCid: entry.partCid,
      );
      if (mounted) {
        setState(() => _entries = updated);
      }
    } catch (_) {
      _showSaveError();
    } finally {
      if (mounted) {
        setState(() => _updatingStableId = null);
      }
    }
  }

  /// 按拖拽结果持久化未完成任务顺序；搜索期间禁用拖拽，避免只排序局部结果。
  Future<void> _reorderActiveEntries(int oldIndex, int newIndex) async {
    if (!_canReorder || _reordering || _updatingStableId != null) {
      return;
    }
    final List<LearningListEntry> activeEntries = _activeEntries;
    if (oldIndex < 0 || oldIndex >= activeEntries.length) {
      return;
    }
    final int targetIndex = newIndex;
    if (targetIndex < 0 || targetIndex >= activeEntries.length) {
      return;
    }
    final List<LearningListEntry> reordered = List<LearningListEntry>.of(
      activeEntries,
    );
    final LearningListEntry moved = reordered.removeAt(oldIndex);
    reordered.insert(targetIndex, moved);
    setState(() => _reordering = true);
    try {
      final List<LearningListEntry> updated = await _learningListService
          .reorderIncomplete(
            reordered
                .map((LearningListEntry entry) => entry.stableId)
                .toList(growable: false),
            folderId: _folderId,
            withinFolder: !_allFolders,
          );
      if (mounted) {
        setState(() => _entries = updated);
      }
    } catch (_) {
      _showSaveError();
    } finally {
      if (mounted) {
        setState(() => _reordering = false);
      }
    }
  }

  Future<void> _removeSelected() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移除所选学习任务'),
        content: Text('移除 ${_selected.length} 条任务？观看记录和笔记保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final entries = await _learningListService.removeBatch(Set.of(_selected));
      if (mounted) {
        setState(() {
          _entries = entries;
          _selected.clear();
        });
      }
    } catch (_) {
      _showSaveError();
    }
  }

  Future<void> _changeSelected(LearningListStatus status) async {
    try {
      final entries = await _learningListService.updateStatuses(
        Set.of(_selected),
        status,
      );
      if (mounted) {
        setState(() {
          _entries = entries;
          _selected.clear();
        });
      }
    } catch (_) {
      _showSaveError();
    }
  }

  void _applyState(LearningListState state) {
    _entries = state.entries;
    _folders = state.folders;
    if (_folderId != null &&
        !_folders.any((folder) => folder.id == _folderId)) {
      _folderId = null;
      _allFolders = false;
    }
  }

  String _folderName(String? id) {
    for (final folder in _folders) {
      if (folder.id == id) return folder.name;
    }
    return '未分组';
  }

  Future<void> _editFolder([LearningSubjectFolder? folder]) async {
    if (_folderBusy) return;
    var name = folder?.name ?? '';
    String? error;
    var saving = false;
    final result = await showDialog<LearningListState>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, updateDialog) {
          Future<void> save() async {
            if (saving) return;
            updateDialog(() {
              saving = true;
              error = null;
            });
            try {
              final result = folder == null
                  ? await _learningListService.createFolder(name)
                  : await _learningListService.renameFolder(folder.id, name);
              if (dialog.mounted) Navigator.pop(dialog, result);
            } catch (exception) {
              if (dialog.mounted) {
                updateDialog(() {
                  saving = false;
                  error = exception is ArgumentError
                      ? exception.message.toString()
                      : '未保存，请重试';
                });
              }
            }
          }

          return PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: Text(folder == null ? '新建学科分组' : '重命名学科分组'),
              content: TextFormField(
                key: const Key('learning-folder-name'),
                initialValue: name,
                autofocus: true,
                maxLength: LearningSubjectFolder.maximumNameCharacters,
                enabled: !saving,
                decoration: InputDecoration(
                  labelText: '学科名称',
                  hintText: '例如：数学、英语',
                  errorText: error,
                ),
                onChanged: (value) => name = value,
                onFieldSubmitted: (_) => save(),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(dialog),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const Key('save-learning-folder'),
                  onPressed: saving ? null : save,
                  child: Text(saving ? '保存中' : '保存'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (result != null && mounted) setState(() => _applyState(result));
  }

  Future<void> _deleteFolder(LearningSubjectFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除学科分组'),
        content: Text('删除“${folder.name}”？组内学习任务会移到“未分组”，学习进度、观看记录和笔记保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-delete-learning-folder'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除分组'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _folderBusy) return;
    await _changeFolders(() => _learningListService.deleteFolder(folder.id));
  }

  Future<void> _changeFolders(
    Future<LearningListState> Function() action,
  ) async {
    if (_folderBusy) return;
    setState(() => _folderBusy = true);
    try {
      final state = await action();
      if (mounted) {
        setState(() {
          _applyState(state);
          _selected.clear();
        });
      }
    } catch (_) {
      _showSaveError();
    } finally {
      if (mounted) setState(() => _folderBusy = false);
    }
  }

  Future<void> _moveToFolder(Set<String> ids) async {
    if (_folderBusy || ids.isEmpty) return;
    final destination = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('移动到学科分组'),
        children: [
          SimpleDialogOption(
            key: const Key('move-folder-ungrouped'),
            onPressed: () => Navigator.pop(dialog, ''),
            child: const Text('未分组'),
          ),
          for (final folder in _folders)
            SimpleDialogOption(
              key: Key('move-folder-${folder.id}'),
              onPressed: () => Navigator.pop(dialog, folder.id),
              child: Text(folder.name),
            ),
          if (_folders.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('可先在清单顶部新建学科分组。'),
            ),
        ],
      ),
    );
    if (destination == null || !mounted) return;
    await _changeFolders(
      () => _learningListService.moveEntries(
        ids,
        destination.isEmpty ? null : destination,
      ),
    );
  }

  Widget _buildFolderHeader() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text('学科分组', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            key: const Key('create-learning-folder'),
            tooltip: '新建学科分组',
            onPressed: _folderBusy ? null : () => _editFolder(),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          if (!_allFolders && _folderId != null)
            PopupMenuButton<String>(
              key: const Key('manage-learning-folder'),
              tooltip: '管理当前分组',
              enabled: !_folderBusy,
              onSelected: (action) {
                final folder = _folders.firstWhere(
                  (folder) => folder.id == _folderId,
                );
                if (action == 'rename') {
                  unawaited(_editFolder(folder));
                } else {
                  unawaited(_deleteFolder(folder));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名分组')),
                PopupMenuItem(value: 'delete', child: Text('删除分组')),
              ],
            ),
        ],
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: const Key('learning-folder-all'),
                label: Text('全部学科（${_entries.length}）'),
                selected: _allFolders,
                onSelected: (_) => setState(() {
                  _allFolders = true;
                  _selected.clear();
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: const Key('learning-folder-ungrouped'),
                label: Text(
                  '未分组（${_entries.where((entry) => entry.folderId == null).length}）',
                ),
                selected: !_allFolders && _folderId == null,
                onSelected: (_) => setState(() {
                  _allFolders = false;
                  _folderId = null;
                  _selected.clear();
                }),
              ),
            ),
            for (final folder in _folders)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: Key('learning-folder-${folder.id}'),
                  label: Text(
                    '${folder.name}（${_entries.where((entry) => entry.folderId == folder.id).length}）',
                  ),
                  selected: !_allFolders && _folderId == folder.id,
                  onSelected: (_) => setState(() {
                    _allFolders = false;
                    _folderId = folder.id;
                    _selected.clear();
                  }),
                ),
              ),
          ],
        ),
      ),
      if (_folderBusy) const LinearProgressIndicator(),
      const SizedBox(height: 8),
    ],
  );

  void _showSaveError() {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未保存，请检查设备存储后重试')));
    }
  }

  /// 将视频时间格式化为 mm:ss 或 h:mm:ss，供任务进度与分 P 时间显示。
  String _formatPosition(Duration value) {
    final int seconds = value.inSeconds.clamp(0, 24 * 60 * 60);
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 为三种学习状态返回稳定且有区分度的主题颜色。
  Color _statusColor(BuildContext context, LearningListStatus status) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return switch (status) {
      LearningListStatus.notStarted => colors.outline,
      LearningListStatus.learning => colors.primary,
      LearningListStatus.completed => Colors.green.shade700,
    };
  }

  /// 创建无网络封面或图片加载失败时的本地占位区域。
  Widget _buildThumbnail(LearningListEntry entry) {
    if (entry.thumbnailUrl.isEmpty) {
      return _buildThumbnailPlaceholder();
    }
    return AppNetworkImage(
      imageUrl: entry.thumbnailUrl,
      fit: BoxFit.cover,
      errorWidget: (BuildContext context, String url, Object error) =>
          _buildThumbnailPlaceholder(),
    );
  }

  /// 创建学习任务封面缺失时使用的固定视频图标。
  Widget _buildThumbnailPlaceholder() {
    return const ColoredBox(
      color: Colors.black12,
      child: Center(child: Icon(Icons.menu_book_outlined)),
    );
  }

  /// 创建一条带状态切换、继续学习、分 P 信息和移除入口的学习任务卡片。
  Widget _buildEntryCard(LearningListEntry entry, {int? reorderIndex}) {
    final bool opening = _openingStableId == entry.stableId;
    final bool updating = _updatingStableId == entry.stableId;
    final bool completed = entry.status == LearningListStatus.completed;
    final double progress = entry.duration > Duration.zero
        ? (entry.position.inMilliseconds / entry.duration.inMilliseconds)
              .clamp(0, 1)
              .toDouble()
        : 0;
    return Card(
      key: Key('learning-list-${entry.stableId}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
            leading: _selecting
                ? Checkbox(
                    value: _selected.contains(entry.stableId),
                    onChanged: (checked) => setState(() {
                      if (checked == true) {
                        _selected.add(entry.stableId);
                      } else {
                        _selected.remove(entry.stableId);
                      }
                    }),
                  )
                : SizedBox(
                    width: 88,
                    height: 54,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildThumbnail(entry),
                    ),
                  ),
            title: Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'P${entry.partPageNumber} ${entry.partTitle}\n${entry.ownerName}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (updating)
                  const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  PopupMenuButton<LearningListStatus>(
                    key: Key('learning-status-${entry.stableId}'),
                    tooltip: '修改学习状态',
                    // 状态选择函数只改变本机清单状态，不会开始或停止播放器。
                    onSelected: (LearningListStatus status) =>
                        unawaited(_changeStatus(entry, status)),
                    itemBuilder: (BuildContext context) => LearningListStatus
                        .values
                        .map(
                          (LearningListStatus status) =>
                              PopupMenuItem<LearningListStatus>(
                                value: status,
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      status == entry.status
                                          ? Icons.check_circle_rounded
                                          : Icons.circle_outlined,
                                      color: _statusColor(context, status),
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(status.label),
                                  ],
                                ),
                              ),
                        )
                        .toList(growable: false),
                  ),
                if (reorderIndex != null) ...<Widget>[
                  const SizedBox(width: 2),
                  ReorderableDragStartListener(
                    index: reorderIndex,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_handle_rounded),
                    ),
                  ),
                ],
              ],
            ),
            // 条目点击函数查询新鲜视频详情，再恢复这个分 P 独立保存的进度。
            onTap: opening || updating || _reordering
                ? null
                : () => unawaited(_openEntry(entry)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${_formatPosition(entry.position)} / ${_formatPosition(entry.duration)}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.circle,
                  size: 9,
                  color: _statusColor(context, entry.status),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '${entry.status.label} · ${_folderName(entry.folderId)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                TextButton.icon(
                  key: Key('continue-learning-${entry.stableId}'),
                  // 继续按钮只为未完成项目打开播放器；已完成项目仍可点击卡片回看，但不参与顺序继续学习。
                  onPressed: opening || updating || _reordering || completed
                      ? null
                      : () => unawaited(_openEntry(entry)),
                  icon: opening
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          completed
                              ? Icons.task_alt_rounded
                              : Icons.play_arrow_rounded,
                          size: 18,
                        ),
                  label: Text(completed ? '已完成' : '继续学习'),
                ),
                IconButton(
                  key: Key('move-learning-${entry.stableId}'),
                  onPressed: _folderBusy || opening || updating || _reordering
                      ? null
                      : () => _moveToFolder({entry.stableId}),
                  icon: const Icon(Icons.drive_file_move_outline),
                  tooltip: '移动到学科分组',
                ),
                IconButton(
                  key: Key('remove-learning-${entry.stableId}'),
                  // 移除按钮函数先要求确认，观看记录、笔记和其他分 P 都不会被删除。
                  onPressed: opening || updating || _reordering
                      ? null
                      : () => unawaited(_confirmRemove(entry)),
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: '移出学习清单',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 创建拖拽排序前的说明，搜索时提示用户清空关键词后再调整完整顺序。
  Widget _buildListHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_learningListService.readFailed)
            const Text('学习清单读取失败，原数据保留。请重试。'),
          _buildFolderHeader(),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _statusFilter == null,
                onSelected: (_) => setState(() => _statusFilter = null),
              ),
              for (final status in LearningListStatus.values)
                ChoiceChip(
                  label: Text(status.label),
                  selected: _statusFilter == status,
                  onSelected: (_) => setState(() => _statusFilter = status),
                ),
            ],
          ),
          if (_selecting)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _selected.addAll(
                      [
                        ..._activeEntries,
                        ..._completedEntries,
                      ].map((e) => e.stableId),
                    );
                  }),
                  child: const Text('选择当前结果'),
                ),
                TextButton(
                  onPressed: _selected.isEmpty ? null : _removeSelected,
                  child: Text('移除所选（${_selected.length}）'),
                ),
                TextButton(
                  key: const Key('move-selected-learning'),
                  onPressed: _selected.isEmpty || _folderBusy
                      ? null
                      : () => _moveToFolder(Set.of(_selected)),
                  child: const Text('移动所选'),
                ),
                for (final status in LearningListStatus.values)
                  TextButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => _changeSelected(status),
                    child: Text('标为${status.label}'),
                  ),
              ],
            ),
          Text(
            _query.isEmpty ? '待学习' : '搜索结果',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            _canReorder
                ? '拖动右侧图标调整学习顺序；完成后会自动移到列表末尾。'
                : '筛选或多选时不能拖拽，恢复全部后可调整顺序。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_reordering) ...<Widget>[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  /// 创建已完成分区和搜索无结果提示，让完成任务与待学习任务视觉分隔。
  Widget _buildListFooter(List<LearningListEntry> completedEntries) {
    final List<LearningListEntry> activeEntries = _activeEntries;
    if (activeEntries.isEmpty && completedEntries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 64, 24, 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.search_off_rounded, size: 52),
              const SizedBox(height: 12),
              Text(_query.isEmpty ? '还没有学习任务' : '没有匹配的学习任务'),
              const SizedBox(height: 6),
              Text(
                _query.isEmpty
                    ? '在搜索、视频详情或合集条目中加入某个分 P 吧。'
                    : '试试视频标题、UP 主、分 P 标题或 P 序号。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (completedEntries.isEmpty) {
      return const SizedBox(height: 28);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '已完成（${completedEntries.length}）',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 10),
          ...completedEntries.expand(
            (LearningListEntry entry) => <Widget>[
              _buildEntryCard(entry),
              const SizedBox(height: 10),
            ],
          ),
        ],
      ),
    );
  }

  /// 创建可下拉刷新、可拖拽未完成任务，并把已完成任务固定在末尾的列表主体。
  Widget _buildBody() {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<LearningListEntry> activeEntries = _activeEntries;
    final List<LearningListEntry> completedEntries = _completedEntries;
    return RefreshIndicator(
      // 下拉刷新函数重新读取本机任务，不会访问网络。
      onRefresh: _reloadEntries,
      child: ReorderableListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 0),
        buildDefaultDragHandles: false,
        header: _buildListHeader(),
        footer: _buildListFooter(completedEntries),
        itemCount: activeEntries.length,
        // 构建函数只为未完成条目提供拖动手柄，完成条目由 footer 固定在末尾分区。
        itemBuilder: (BuildContext context, int index) => Padding(
          key: Key('reorder-learning-list-${activeEntries[index].stableId}'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: _buildEntryCard(
            activeEntries[index],
            reorderIndex: _canReorder ? index : null,
          ),
        ),
        // 重排回调在搜索为空时把完整未完成队列写回本机，避免局部搜索导致顺序意外变化。
        onReorderItem: _reorderActiveEntries,
      ),
    );
  }

  /// 创建标题、搜索和刷新入口，并把完整任务管理留在一个独立页面中。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                key: const Key('learning-list-search-field'),
                controller: _searchController,
                autofocus: true,
                onChanged: _updateQuery,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索视频、UP 主或分 P',
                  filled: true,
                  fillColor: Theme.of(context).scaffoldBackgroundColor,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              )
            : const Text('学习清单'),
        actions: <Widget>[
          IconButton(
            tooltip: _selecting ? '结束多选' : '多选管理',
            icon: Icon(_selecting ? Icons.close : Icons.checklist),
            onPressed: () => setState(() {
              _selecting = !_selecting;
              _selected.clear();
            }),
          ),
          IconButton(
            key: const Key('search-learning-list'),
            // 搜索按钮函数在标题和本机搜索输入框之间切换，不读取网络数据。
            onPressed: _searching ? _closeSearch : _openSearch,
            icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
            tooltip: _searching ? '关闭搜索' : '搜索学习清单',
          ),
          IconButton(
            key: const Key('reload-learning-list'),
            // 刷新按钮函数重新读取本机数据，不会访问网络。
            onPressed: _loading || _reordering
                ? null
                : () => unawaited(_reloadEntries()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新学习清单',
          ),
        ],
      ),
      body: AdaptivePageFrame(maxWidth: 1180, child: _buildBody()),
    );
  }
}
