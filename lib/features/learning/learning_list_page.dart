import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/learning_list_entry.dart';
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

  /// 创建保存任务列表、状态筛选和异步操作反馈的页面状态。
  @override
  State<LearningListPage> createState() => _LearningListPageState();
}

/// 管理学习清单的本机读取、状态变更、继续学习和移除操作。
class _LearningListPageState extends State<LearningListPage> {
  late final LearningListService _learningListService;
  late final BilibiliService _videoService;
  List<LearningListEntry> _entries = const <LearningListEntry>[];
  LearningListStatus? _statusFilter;
  bool _loading = true;
  String? _openingBvid;
  String? _updatingBvid;

  /// 初始化服务并读取设备上已有的学习任务。
  @override
  void initState() {
    super.initState();
    _learningListService = widget.learningListService ?? LearningListService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    unawaited(_reloadEntries());
  }

  /// 重新读取本机任务；刷新期间保留旧列表，避免界面突然跳为空白。
  Future<void> _reloadEntries() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    final List<LearningListEntry> entries = await _learningListService
        .loadEntries();
    if (!mounted) {
      return;
    }
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  /// 返回当前筛选下应显示的任务，未选择状态时保留服务给出的更新时间顺序。
  List<LearningListEntry> get _visibleEntries {
    final LearningListStatus? filter = _statusFilter;
    if (filter == null) {
      return _entries;
    }
    return _entries
        .where((LearningListEntry entry) => entry.status == filter)
        .toList(growable: false);
  }

  /// 查询任务视频详情并打开播放器，返回后刷新可能由播放器更新的学习进度。
  Future<void> _openEntry(LearningListEntry entry) async {
    if (_openingBvid != null || _updatingBvid != null) {
      return;
    }
    setState(() => _openingBvid = entry.bvid);
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
    } finally {
      if (mounted) {
        setState(() => _openingBvid = null);
      }
    }
  }

  /// 更新任务状态并用服务返回的完整列表刷新当前页面。
  Future<void> _changeStatus(
    LearningListEntry entry,
    LearningListStatus status,
  ) async {
    if (_updatingBvid != null || entry.status == status) {
      return;
    }
    setState(() => _updatingBvid = entry.bvid);
    try {
      final List<LearningListEntry> updated = await _learningListService
          .updateStatus(entry.bvid, status);
      if (!mounted) {
        return;
      }
      setState(() => _entries = updated);
    } finally {
      if (mounted) {
        setState(() => _updatingBvid = null);
      }
    }
  }

  /// 询问后移除单条任务，避免误触清掉用户专门保存的学习计划。
  Future<void> _confirmRemove(LearningListEntry entry) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('移出学习清单'),
        content: Text('确定移除“${entry.title}”吗？观看记录和笔记不会被删除。'),
        actions: <Widget>[
          TextButton(
            // 取消函数只关闭确认框，保持学习任务不变。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认函数把决定返回页面，再由本机服务执行移除。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _updatingBvid != null) {
      return;
    }
    setState(() => _updatingBvid = entry.bvid);
    try {
      final List<LearningListEntry> updated = await _learningListService.remove(
        entry.bvid,
      );
      if (mounted) {
        setState(() => _entries = updated);
      }
    } finally {
      if (mounted) {
        setState(() => _updatingBvid = null);
      }
    }
  }

  /// 将视频时间格式化为 mm:ss 或 h:mm:ss，供任务进度与分P时间显示。
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
    return Image.network(
      entry.thumbnailUrl,
      fit: BoxFit.cover,
      errorBuilder: (BuildContext context, Object error, StackTrace? trace) =>
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

  /// 创建一条带状态切换、继续学习和移除入口的学习任务卡片。
  Widget _buildEntryCard(LearningListEntry entry) {
    final bool opening = _openingBvid == entry.bvid;
    final bool updating = _updatingBvid == entry.bvid;
    final double progress = entry.duration > Duration.zero
        ? (entry.position.inMilliseconds / entry.duration.inMilliseconds)
              .clamp(0, 1)
              .toDouble()
        : 0;
    return Card(
      key: Key('learning-list-${entry.bvid}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
            leading: SizedBox(
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
            trailing: updating
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : PopupMenuButton<LearningListStatus>(
                    key: Key('learning-status-${entry.bvid}'),
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
            // 条目点击函数查询新鲜视频详情，再恢复任务分P和进度。
            onTap: opening || updating
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
                Text(
                  entry.status.label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  key: Key('continue-learning-${entry.bvid}'),
                  // 继续学习函数沿用条目点击的恢复逻辑，避免两套进度入口不一致。
                  onPressed: opening || updating
                      ? null
                      : () => unawaited(_openEntry(entry)),
                  icon: opening
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('继续学习'),
                ),
                IconButton(
                  key: Key('remove-learning-${entry.bvid}'),
                  // 移除按钮函数先要求确认，观看记录和笔记不会被删除。
                  onPressed: opening || updating
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

  /// 创建筛选芯片，让三种状态既能统一管理也能分别查看。
  Widget _buildStatusFilters() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        ChoiceChip(
          key: const Key('learning-filter-all'),
          label: const Text('全部'),
          selected: _statusFilter == null,
          // 全部筛选函数清除状态限制，保留服务按更新时间排序的顺序。
          onSelected: (_) => setState(() => _statusFilter = null),
        ),
        ...LearningListStatus.values.map(
          (LearningListStatus status) => ChoiceChip(
            key: Key('learning-filter-${status.name}'),
            label: Text(status.label),
            selected: _statusFilter == status,
            // 状态筛选函数只更新当前页面的可见列表，不修改任务数据。
            onSelected: (_) => setState(() => _statusFilter = status),
          ),
        ),
      ],
    );
  }

  /// 创建加载、空状态、筛选和任务卡片组成的学习清单主体。
  Widget _buildBody() {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<LearningListEntry> visibleEntries = _visibleEntries;
    return RefreshIndicator(
      // 下拉刷新函数重新读取本机任务，适合从播放器返回后手动确认状态。
      onRefresh: _reloadEntries,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        itemCount: 1 + (visibleEntries.isEmpty ? 1 : visibleEntries.length),
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 10),
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return _buildStatusFilters();
          }
          if (visibleEntries.isEmpty) {
            return const Padding(
              padding: EdgeInsets.only(top: 64),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.menu_book_outlined, size: 52),
                    SizedBox(height: 12),
                    Text('还没有符合条件的学习任务'),
                    SizedBox(height: 6),
                    Text('在搜索、视频详情或合集条目中加入学习清单吧。'),
                  ],
                ),
              ),
            );
          }
          return _buildEntryCard(visibleEntries[index - 1]);
        },
      ),
    );
  }

  /// 创建标题和刷新入口，并把完整任务管理留在一个独立页面中。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('学习清单'),
        actions: <Widget>[
          IconButton(
            key: const Key('reload-learning-list'),
            // 刷新按钮函数重新读取本机数据，不会访问网络。
            onPressed: _loading ? null : () => unawaited(_reloadEntries()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新学习清单',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}
