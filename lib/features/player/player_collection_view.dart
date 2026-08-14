part of 'player_page.dart';

/// 组合播放器详情中的合集预览、UP 主资料和非全屏内容区域。
extension _PlayerCollectionView on _PlayerPageState {
  /// 将合集视频时长格式化为分秒或时分秒，供封面右下角紧凑显示。
  String _formatCollectionDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 1 << 31).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 将合集条目的发布日期格式化为年月日，日期缺失时返回稳定占位文字。
  String _formatCollectionPublishedDate(DateTime? value) {
    if (value == null) {
      return '日期未知';
    }
    final DateTime local = value.toLocal();
    return '${local.year}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  /// 在合集预览首次出现或切换视频后，把横向列表平滑定位到当前视频。
  void _scheduleCollectionPreviewLocation(VideoCollection collection) {
    final String currentBvid = _activeVideo.bvid;
    if (_locatedCollectionPreviewBvid == currentBvid) {
      return;
    }
    final int currentIndex = collection.indexOfBvid(currentBvid);
    if (currentIndex < 0) {
      return;
    }
    _locatedCollectionPreviewBvid = currentBvid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_collectionPreviewScrollController.hasClients) {
        _locatedCollectionPreviewBvid = null;
        return;
      }
      final ScrollPosition position =
          _collectionPreviewScrollController.position;
      final double target = (currentIndex * 340.0)
          .clamp(0, position.maxScrollExtent)
          .toDouble();
      if ((position.pixels - target).abs() < 1) {
        return;
      }
      _collectionPreviewScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// 创建一条横向合集视频预览，封面、标题和统计密度参考移动端视频列表。
  Widget _buildCollectionPreviewRow(VideoCollectionEntry entry) {
    final bool current = entry.bvid == _activeVideo.bvid;
    final bool opening = _openingCollectionBvid == entry.bvid;
    final bool adding = _addingLearningBvid == entry.bvid;
    final WatchHistoryEntry? watchHistory = _watchHistoryByBvid[entry.bvid];
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: current
          ? colors.primaryContainer.withValues(alpha: 0.32)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('collection-preview-${entry.bvid}'),
        // 合集视频行点击函数在当前播放器中切换到所选视频。
        onTap: current || opening
            ? null
            : () => unawaited(_openCollectionVideo(entry)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: <Widget>[
                    _buildDetailImage(
                      entry.thumbnailUrl,
                      width: 156,
                      height: 88,
                      fit: BoxFit.cover,
                      placeholderIcon: Icons.video_library_outlined,
                    ),
                    if (watchHistory != null && !current)
                      Positioned(
                        left: 5,
                        top: 5,
                        child: WatchHistoryBadge(
                          entry: watchHistory,
                          showPosition: false,
                        ),
                      ),
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            _formatCollectionDuration(entry.duration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (current)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black45,
                          child: Center(
                            child: Text(
                              '正在播放',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      )
                    else if (opening)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black38,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 88,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _PartTitleMarquee(
                        key: Key('collection-title-${entry.bvid}'),
                        text: entry.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatCollectionPublishedDate(entry.publishedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.play_circle_outline_rounded,
                            size: 15,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _formatCount(entry.stats.viewCount),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.subtitles_outlined,
                            size: 15,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _formatCount(entry.stats.danmakuCount),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  key: Key('add-learning-player-collection-${entry.bvid}'),
                  visualDensity: VisualDensity.compact,
                  // 合集预览加入函数查询对应完整视频并自动继承该视频观看进度。
                  onPressed: adding
                      ? null
                      : () =>
                            unawaited(_addCollectionVideoToLearningList(entry)),
                  icon: adding
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.playlist_add_rounded, size: 20),
                  tooltip: '加入学习清单',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建当前视频所属 UGC 合集入口和横向滑动的视频预览，恢复原来的紧凑布局。
  Widget _buildCollectionPanel(VideoCollection collection) {
    final int currentIndex = collection.indexOfBvid(_activeVideo.bvid);
    _scheduleCollectionPreviewLocation(collection);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('video-collection-card'),
            // 合集头部点击函数打开完整合集选择面板。
            onTap: () => unawaited(_showCollectionSheet(collection)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.collections_bookmark_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '合集 · ${collection.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    currentIndex >= 0
                        ? '${currentIndex + 1}/${collection.totalCount}'
                        : '${collection.totalCount}支',
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollCacheExtent: const ScrollCacheExtent.pixels(680),
            key: const Key('collection-preview-list'),
            controller: _collectionPreviewScrollController,
            scrollDirection: Axis.horizontal,
            itemCount: collection.entries.length,
            // 分隔函数为相邻合集预览保留固定的横向间距。
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(width: 10),
            // 构建函数复用带封面与统计的预览行，并限制成可横向滑动的紧凑卡片。
            itemBuilder: (BuildContext context, int index) => SizedBox(
              width: 330,
              child: _buildCollectionPreviewRow(collection.entries[index]),
            ),
          ),
        ),
      ],
    );
  }

  /// 创建可进入公开主页的 UP 主资料卡，不提供关注或私信写操作。
  Widget _buildOwnerPanel() {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const Key('video-owner-card'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: ClipOval(
          child: _buildDetailImage(
            _activeVideo.ownerAvatarUrl,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            placeholderIcon: Icons.person_rounded,
          ),
        ),
        title: Text(
          _activeVideo.ownerName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          _activeVideo.ownerMid > 0 ? 'UID：${_activeVideo.ownerMid}' : 'UP 主',
        ),
        trailing: _activeVideo.ownerMid > 0
            ? const Icon(Icons.chevron_right_rounded)
            : null,
        // UP 主卡点击函数暂停视频后进入公开主页。
        onTap: _activeVideo.ownerMid > 0
            ? () => unawaited(_openOwnerProfile())
            : null,
      ),
    );
  }

  /// 创建可放入统一页面滚动中的简介区，并在普通竖屏保留分P和合集内容。
  Widget _buildNonFullscreenDetails() {
    final VideoCollection? collection = _activeVideo.collection;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '简介',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _buildCurrentVideoLearningListButton(),
              TextButton.icon(
                key: const Key('portrait-note-button'),
                // 竖屏记笔记按钮函数在播放器下方打开编辑区，并固定播放器高度。
                onPressed: () => unawaited(_openVideoNotes()),
                icon: const Icon(Icons.edit_note_rounded, size: 20),
                label: const Text('记笔记'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 12),
          _buildVideoDescription(),
          if (_activeVideo.parts.length > 1) ...<Widget>[
            const SizedBox(height: 18),
            _buildPartSelector(),
          ],
          if (collection != null) ...<Widget>[
            const SizedBox(height: 20),
            _buildCollectionPanel(collection),
          ],
          const SizedBox(height: 20),
          _buildOwnerPanel(),
        ],
      ),
    );
  }

  /// 把最终页面组合交给同库视图扩展，状态类只保留生命周期和业务编排。
}
