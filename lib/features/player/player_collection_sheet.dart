part of 'player_page.dart';

/// 展示完整合集，并在本机完成搜索、排序和当前视频定位。
class _CollectionPickerSheet extends StatefulWidget {
  /// 创建合集选择器；观看记录仅用于封面标记，不会改变合集数据。
  const _CollectionPickerSheet({
    required this.collection,
    required this.currentBvid,
    required this.watchHistoryByBvid,
  });

  final VideoCollection collection;
  final String currentBvid;
  final Map<String, WatchHistoryEntry> watchHistoryByBvid;

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
    final List<VideoCollectionEntry> entries = _visibleEntries();
    final int index = entries.indexWhere(
      (VideoCollectionEntry entry) => entry.bvid == widget.currentBvid,
    );
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
            CachedNetworkImage(
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

  /// 创建单条合集视频，点击后把选择结果交回播放器页面。
  Widget _buildEntry(VideoCollectionEntry entry) {
    final bool current = entry.bvid == widget.currentBvid;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: current
            ? Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: 0.45)
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
          trailing: Icon(
            current ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
          ),
          // 条目点击函数关闭合集面板，并把所选视频返回给播放器切换。
          onTap: current ? null : () => Navigator.of(context).pop(entry),
        ),
      ),
    );
  }

  /// 创建带标题、搜索框、排序按钮、定位按钮和惰性长列表的合集面板。
  @override
  Widget build(BuildContext context) {
    final List<VideoCollectionEntry> entries = _visibleEntries();
    return SafeArea(
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
                      '合集 · ${widget.collection.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text('${entries.length}/${widget.collection.entries.length}'),
                  IconButton(
                    key: const Key('collection-locate-current'),
                    tooltip: '定位到正在播放',
                    // 定位按钮函数会清空搜索，并滚动到当前播放视频。
                    onPressed: _locateCurrent,
                    icon: const Icon(Icons.my_location_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('collection-search-field'),
                      controller: _searchController,
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
                        child: ListView.builder(
                          key: const Key('collection-sheet-list'),
                          controller: _scrollController,
                          itemExtent: _entryExtent,
                          itemCount: entries.length,
                          // 长列表构建函数只创建屏幕附近的条目，781 条也能继续滑动。
                          itemBuilder: (BuildContext context, int index) =>
                              _buildEntry(entries[index]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
