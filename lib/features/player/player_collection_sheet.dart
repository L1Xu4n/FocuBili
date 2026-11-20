part of 'player_page.dart';

/// 展示完整合集，并在本机完成搜索、排序和当前视频定位。
class _CollectionPickerSheet extends StatefulWidget {
  /// 创建合集选择器；观看记录仅用于封面标记，不会改变合集数据。
  const _CollectionPickerSheet({
    required this.collection,
    required this.currentBvid,
    required this.watchHistoryByBvid,
    required this.learningListService,
    required this.resolveLearningSelection,
    required this.onLearningSaved,
  });

  final VideoCollection collection;
  final String currentBvid;
  final Map<String, WatchHistoryEntry> watchHistoryByBvid;

  final LearningListService learningListService;
  final Future<LearningPartSelection> Function(VideoCollectionEntry)
  resolveLearningSelection;
  final VoidCallback onLearningSaved;

  /// 创建保存搜索文字、排序选项和滚动位置的面板状态。
  @override
  State<_CollectionPickerSheet> createState() => _CollectionPickerSheetState();
}

/// 管理合集展开面板的过滤、排序和当前位置滚动。
class _CollectionPickerSheetState extends State<_CollectionPickerSheet> {
  static const double _entryExtent = 76;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  _CollectionEntryOrder _order = _CollectionEntryOrder.original;
  String _keyword = '';
  bool _selecting = false;
  bool _saving = false;
  bool _confirming = false;
  int _draftGeneration = 0;
  int _initialTaskCount = 0;
  Map<String, Set<String>>? _initialLearningIds;
  Set<String> _selectedBvids = {};
  Set<String> _beforeDrag = {};
  String? _learningError;
  String? _learningNotice;

  bool get _canChangeSelection =>
      _initialLearningIds != null && !_saving && !_confirming;

  Future<void> _startLearningSelection(VideoCollectionEntry entry) async {
    if (_selecting) return;
    final generation = ++_draftGeneration;
    final wasFiltered = _keyword.trim().isNotEmpty;
    FocusScope.of(context).unfocus();
    _searchController.clear();
    setState(() {
      _keyword = '';
      _selecting = true;
      _learningError = null;
      _learningNotice = null;
    });
    if (wasFiltered) _locateVideo(entry.bvid, animated: false);

    final learning = widget.learningListService;
    final entries = await learning.loadEntries();
    if (!mounted || generation != _draftGeneration) return;
    if (learning.readFailed) {
      setState(() => _learningError = '无法读取学习清单，请取消后重试。');
      return;
    }
    final collectionBvids = widget.collection.entries
        .map((e) => e.bvid)
        .toSet();
    final ids = <String, Set<String>>{};
    for (final task in entries) {
      if (collectionBvids.contains(task.bvid)) {
        (ids[task.bvid] ??= <String>{}).add(task.stableId);
      }
    }
    setState(() {
      _initialTaskCount = entries.length;
      _initialLearningIds = ids;
      _selectedBvids = {...ids.keys, entry.bvid};
    });
  }

  void _endLearningSelection({String? notice}) {
    ++_draftGeneration;
    setState(() {
      _selecting = false;
      _saving = false;
      _initialLearningIds = null;
      _selectedBvids.clear();
      _beforeDrag.clear();
      _learningError = null;
      _learningNotice = notice;
    });
  }

  void _toggleLearningSelection(String bvid) {
    if (!_canChangeSelection) return;
    setState(() {
      _learningError = null;
      if (!_selectedBvids.remove(bvid)) _selectedBvids.add(bvid);
    });
  }

  void _updateLearningRange(
    DragSelectionUpdate update,
    List<VideoCollectionEntry> entries,
  ) {
    if (!_canChangeSelection) return;
    if (update.anchor == update.previous && update.previous == update.current) {
      _beforeDrag = {..._selectedBvids};
    }
    final start = update.anchor < update.current
        ? update.anchor
        : update.current;
    final end = update.anchor > update.current ? update.anchor : update.current;
    setState(() {
      _learningError = null;
      _selectedBvids = {..._beforeDrag};
      for (var i = start; i <= end; i++) {
        if (update.checked) {
          _selectedBvids.add(entries[i].bvid);
        } else {
          _selectedBvids.remove(entries[i].bvid);
        }
      }
    });
  }

  Future<void> _saveLearningSelection() async {
    final initial = _initialLearningIds;
    if (initial == null || !_canChangeSelection) return;
    final addedBvids = _selectedBvids.difference(initial.keys.toSet());
    final removedBvids = initial.keys.toSet().difference(_selectedBvids);
    if (addedBvids.isEmpty && removedBvids.isEmpty) return;
    final removeIds = {for (final bvid in removedBvids) ...initial[bvid]!};
    const capacityError =
        '未保存：学习清单最多保存 ${LearningListService.maximumEntries} 项任务，请减少勾选。';
    // Avoid requesting details when the draft already exceeds local capacity.
    // The service also validates against the newest state when it writes.
    if (_initialTaskCount - removeIds.length + addedBvids.length >
        LearningListService.maximumEntries) {
      setState(() => _learningError = capacityError);
      return;
    }

    if (removedBvids.isNotEmpty) {
      setState(() => _confirming = true);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Text('移出 ${removedBvids.length} 支视频？'),
          content: const Text('会移出这些视频的所有学习任务，并清除清单内的进度。观看历史和笔记不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('返回修改'),
            ),
            FilledButton(
              key: const Key('confirm-collection-learning-changes'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认保存'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirmed != true) return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _learningError = null;
    });
    final selections = <LearningPartSelection>[];
    for (final entry in widget.collection.entries) {
      // Use the original collection order, independent of search/sort order.
      if (!addedBvids.remove(entry.bvid)) continue;
      try {
        selections.add(await widget.resolveLearningSelection(entry));
      } catch (_) {
        if (mounted) {
          setState(() {
            _saving = false;
            _learningError = '未保存：无法读取「${entry.title}」的视频详情，请重试。';
          });
        }
        return;
      }
      if (!mounted || ModalRoute.of(context)?.isActive == false) return;
    }

    final onSaved = widget.onLearningSaved;
    final result = await widget.learningListService.addBatch(
      selections,
      removeIds: removeIds,
    );
    final saved =
        result.persisted &&
        !result.capacityExceeded &&
        result.failedItems.isEmpty;
    if (saved) onSaved();
    if (!mounted) return;
    if (saved) {
      _endLearningSelection(notice: '学习清单已保存');
    } else {
      setState(() {
        _saving = false;
        _learningError = !result.persisted
            ? '未保存，请检查设备存储后重试。'
            : result.capacityExceeded
            ? capacityError
            : '未保存：有视频的分 P 已失效，请重试。';
      });
    }
  }

  /// 面板出现后自动滚到当前播放视频，避免长合集总是从第一条开始。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _locateCurrent(animated: false);
    });
  }

  /// 释放搜索输入框和列表滚动控制器，避免关闭面板后继续占用资源。
  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 根据关键词筛选标题或 BV 号，再复制排序，绝不修改原始合集列表。
  List<VideoCollectionEntry> _visibleEntries() {
    final String normalizedKeyword = _keyword.trim().toLowerCase();
    final List<VideoCollectionEntry> entries = widget.collection.entries
        .where((VideoCollectionEntry entry) {
          if (normalizedKeyword.isEmpty) {
            return true;
          }
          return entry.title.toLowerCase().contains(normalizedKeyword) ||
              entry.bvid.toLowerCase().contains(normalizedKeyword);
        })
        .toList(growable: true);
    switch (_order) {
      case _CollectionEntryOrder.original:
        break;
      case _CollectionEntryOrder.newest:
        entries.sort(_compareNewest);
        break;
      case _CollectionEntryOrder.oldest:
        entries.sort(_compareOldest);
        break;
      case _CollectionEntryOrder.mostPlayed:
        entries.sort(
          (VideoCollectionEntry left, VideoCollectionEntry right) =>
              right.stats.viewCount.compareTo(left.stats.viewCount),
        );
        break;
    }
    return entries;
  }

  /// 按发布时间从新到旧比较；缺少日期的条目放到列表末尾。
  int _compareNewest(VideoCollectionEntry left, VideoCollectionEntry right) {
    if (left.publishedAt == null && right.publishedAt == null) {
      return 0;
    }
    if (left.publishedAt == null) {
      return 1;
    }
    if (right.publishedAt == null) {
      return -1;
    }
    return right.publishedAt!.compareTo(left.publishedAt!);
  }

  /// 按发布时间从旧到新比较；缺少日期的条目仍放到列表末尾。
  int _compareOldest(VideoCollectionEntry left, VideoCollectionEntry right) {
    if (left.publishedAt == null && right.publishedAt == null) {
      return 0;
    }
    if (left.publishedAt == null) {
      return 1;
    }
    if (right.publishedAt == null) {
      return -1;
    }
    return left.publishedAt!.compareTo(right.publishedAt!);
  }

  /// 更新搜索关键词并立即刷新结果，不发送网络请求。
  void _updateKeyword(String value) {
    setState(() => _keyword = value);
  }

  /// 清空搜索条件，并让当前视频重新出现在可见结果中。
  void _clearSearch() {
    _searchController.clear();
    setState(() => _keyword = '');
  }

  /// 切换本地排序方式，并保持搜索结果继续可用。
  void _changeOrder(_CollectionEntryOrder order) {
    setState(() => _order = order);
  }

  /// 清除可能挡住当前项的搜索词，再滚动到当前播放视频。
  void _locateCurrent({bool animated = true}) {
    if (_keyword.isNotEmpty) {
      _clearSearch();
    }
    _locateVideo(widget.currentBvid, animated: animated);
  }

  void _locateVideo(String bvid, {required bool animated}) {
    final List<VideoCollectionEntry> entries = _visibleEntries();
    final int index = entries.indexWhere((entry) => entry.bvid == bvid);
    if (index < 0) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final ScrollPosition position = _scrollController.position;
      final double target = (index * _entryExtent)
          .clamp(0, position.maxScrollExtent)
          .toDouble();
      if (animated) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  /// 返回排序菜单中对初学者友好的中文名称。
  String _orderLabel(_CollectionEntryOrder order) {
    switch (order) {
      case _CollectionEntryOrder.original:
        return '合集顺序';
      case _CollectionEntryOrder.newest:
        return '最新发布';
      case _CollectionEntryOrder.oldest:
        return '最早发布';
      case _CollectionEntryOrder.mostPlayed:
        return '最多播放';
    }
  }

  /// 将公开视频统计压缩为万或亿，避免副标题被数字挤满。
  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }

  /// 将封面时长格式化成分秒或时分秒。
  String _formatDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 1 << 31).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 创建固定比例封面，加载失败时显示视频占位图标而不撑坏列表。
  Widget _buildThumbnail(VideoCollectionEntry entry, bool current) {
    final WatchHistoryEntry? history = widget.watchHistoryByBvid[entry.bvid];
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: <Widget>[
          if (entry.thumbnailUrl.isEmpty)
            const SizedBox(
              width: 96,
              height: 54,
              child: ColoredBox(
                color: Colors.black26,
                child: Icon(Icons.video_library_outlined),
              ),
            )
          else
            AppNetworkImage(
              imageUrl: entry.thumbnailUrl,
              width: 96,
              height: 54,
              fit: BoxFit.cover,
              errorWidget: (BuildContext context, String url, Object error) =>
                  const SizedBox(
                    width: 96,
                    height: 54,
                    child: ColoredBox(
                      color: Colors.black26,
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
            ),
          if (history != null && !current)
            Positioned(
              left: 3,
              top: 3,
              child: WatchHistoryBadge(entry: history, showPosition: false),
            ),
          Positioned(
            right: 3,
            bottom: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(
                  _formatDuration(entry.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 普通模式切换播放；学习模式仅修改待保存的勾选状态。
  Widget _buildEntry(VideoCollectionEntry entry, {Key? handleKey}) {
    final bool current = entry.bvid == widget.currentBvid;
    final bool checked = _selectedBvids.contains(entry.bvid);
    final colors = Theme.of(context).colorScheme;
    final VoidCallback? toggleSelection = _canChangeSelection
        ? () => _toggleLearningSelection(entry.bvid)
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: (_selecting ? checked : current)
            ? colors.primaryContainer.withValues(alpha: 0.45)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          key: Key('collection-sheet-${entry.bvid}'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: _buildThumbnail(entry, current),
          title: Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            current ? '正在播放' : '${_formatCount(entry.stats.viewCount)}播放',
            maxLines: 1,
          ),
          trailing: _selecting
              ? ExcludeFocus(
                  child: Checkbox(
                    key: handleKey,
                    value: checked,
                    onChanged: toggleSelection == null
                        ? null
                        : (_) => toggleSelection(),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      key: Key('add-learning-collection-sheet-${entry.bvid}'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          unawaited(_startLearningSelection(entry)),
                      icon: const Icon(Icons.playlist_add_rounded),
                      tooltip: '管理合集学习清单',
                    ),
                    Icon(
                      current
                          ? Icons.graphic_eq_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ],
                ),
          onTap: _selecting
              ? toggleSelection
              : current
              ? null
              : () => Navigator.of(context).pop(entry),
          onLongPress: _selecting
              ? null
              : () => unawaited(_startLearningSelection(entry)),
        ),
      ),
    );
  }

  /// 创建带标题、搜索框、排序按钮、定位按钮和惰性长列表的合集面板。
  @override
  Widget build(BuildContext context) {
    final List<VideoCollectionEntry> entries = _visibleEntries();
    final initiallySelected = _initialLearningIds?.keys.toSet() ?? <String>{};
    final added = _selectedBvids.difference(initiallySelected).length;
    final removed = initiallySelected.difference(_selectedBvids).length;
    final count = widget.collection.entries.length;
    final contents = SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.84,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _selecting ? '管理学习清单' : '合集 · ${widget.collection.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_selecting)
                    Text('已选 ${_selectedBvids.length}/$count')
                  else ...[
                    Text('${entries.length}/$count'),
                    IconButton(
                      key: const Key('collection-locate-current'),
                      tooltip: '定位到正在播放',
                      // 定位按钮函数会清空搜索，并滚动到当前播放视频。
                      onPressed: _locateCurrent,
                      icon: const Icon(Icons.my_location_rounded),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('collection-search-field'),
                      controller: _searchController,
                      enabled: !_saving,
                      onChanged: _updateKeyword,
                      decoration: InputDecoration(
                        hintText: '搜索标题或 BV 号',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _keyword.isEmpty
                            ? null
                            : IconButton(
                                // 清空按钮函数恢复完整合集结果。
                                onPressed: _clearSearch,
                                icon: const Icon(Icons.close_rounded),
                              ),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<_CollectionEntryOrder>(
                    key: const Key('collection-sort-button'),
                    tooltip: '排序',
                    initialValue: _order,
                    enabled: !_saving,
                    // 排序选择函数只重新排列当前面板，不修改合集本身。
                    onSelected: _changeOrder,
                    itemBuilder: (BuildContext context) => _CollectionEntryOrder
                        .values
                        .map(
                          (_CollectionEntryOrder order) =>
                              PopupMenuItem<_CollectionEntryOrder>(
                                value: order,
                                child: Text(_orderLabel(order)),
                              ),
                        )
                        .toList(growable: false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(Icons.sort_rounded),
                          const SizedBox(width: 5),
                          Text(_orderLabel(_order)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('没有找到匹配的视频'))
                    : Scrollbar(
                        controller: _scrollController,
                        child: DragSelectionRegion(
                          key: ValueKey((_keyword, _order)),
                          controller: _scrollController,
                          itemCount: entries.length,
                          enabled: _canChangeSelection,
                          checkedAt: (i) =>
                              _selectedBvids.contains(entries[i].bvid),
                          onDragUpdate: (update) =>
                              _updateLearningRange(update, entries),
                          builder: (context, dragging) => ListView.builder(
                            key: const Key('collection-sheet-list'),
                            controller: _scrollController,
                            physics: dragging
                                ? const NeverScrollableScrollPhysics()
                                : null,
                            itemExtent: _entryExtent,
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entry = entries[index];
                              if (!_selecting) return _buildEntry(entry);
                              return DragSelectionTarget(
                                index: index,
                                key: ValueKey(entry.bvid),
                                builder: (context, handleKey) => MergeSemantics(
                                  child: _buildEntry(
                                    entry,
                                    handleKey: handleKey,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
              ),
              if (_selecting) ...[
                const Divider(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _learningError ??
                        (_saving
                            ? '正在保存…'
                            : _initialLearningIds == null
                            ? '正在读取学习清单…'
                            : added + removed == 0
                            ? '长按复选框后滑动可连续勾选或取消'
                            : '待加入 $added 支 · 待移出 $removed 支'),
                    style: TextStyle(
                      color: _learningError == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('cancel-collection-learning-selection'),
                      onPressed: _saving ? null : () => _endLearningSelection(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('save-collection-learning-selection'),
                      onPressed: _canChangeSelection && (added + removed > 0)
                          ? _saveLearningSelection
                          : null,
                      child: const Text('保存更改'),
                    ),
                  ],
                ),
              ] else if (_learningNotice case final notice?)
                Semantics(liveRegion: true, child: Text(notice)),
            ],
          ),
        ),
      ),
    );
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && _selecting && !_saving && !_confirming) {
          _endLearningSelection();
        }
      },
      child: contents,
    );
  }
}
