part of 'player_page.dart';

/// 在同一个播放器内衔接来源列表，避免另建页面争抢媒体会话。
mixin _PlayerPlaylistCoordinator on State<PlayerPage>, _PlayerVideoCoordinator {
  PlaybackQueue? _playlist;
  bool _playlistMoving = false;
  int _playlistEpoch = 0;

  /// 显式来源优先；单独打开的视频才使用其内置合集。
  void _initializePlaylist() {
    _playlist = widget.playbackQueue;
    final collection = _activeVideo.collection;
    if (_playlist == null && collection != null) {
      _playlist = PlaybackQueue(
        title: collection.title,
        items: collection.entries.map(
          (item) => PlaybackQueueItem(bvid: item.bvid, title: item.title),
        ),
        hasMore:
            collection.totalCount > collection.entries.length &&
            collection.ownerMid > 0,
        // 独立分页读取器不捕获列表页面的 State。
        loadPage: (page) async {
          final result = await _publicContentService.loadCollectionVideos(
            collection.ownerMid,
            collection.id,
            page: page,
          );
          return PlaybackQueuePage(
            result.items
                .map(
                  (item) =>
                      PlaybackQueueItem(bvid: item.bvid, title: item.title),
                )
                .toList(),
            hasMore: result.hasMore,
          );
        },
      );
    }
    _playlist?.addListener(_playlistChanged);
    _prefetchPlaylist();
  }

  /// 分页只更新列表显示，不改变当前播放项。
  void _playlistChanged() {
    if (mounted) setState(() {});
  }

  /// 取消尚未完成的自动切换，暂停、手动导航和退出后不恢复旧请求。
  @override
  void _cancelPlaylistAdvance() => _playlistEpoch++;

  /// 来源为学习清单时禁止扩展未保存的分 P。
  bool get _playlistUsesExactParts =>
      _playlist?.items.any((item) => item.learningEntry != null) ?? false;

  /// 下一项按钮允许跨分 P、跨视频以及继续请求下一页。
  bool get _hasPlaylistNavigation =>
      _playlist != null || _activeVideo.parts.length > 1;

  /// 临近已加载列表末端时预取一页；失败留在列表中等待用户重试。
  void _prefetchPlaylist() {
    final queue = _playlist;
    if (queue == null || queue.loading || queue.error != null) return;
    final index = queue.indexOf(_activeVideo.bvid, _currentPart.cid);
    if (index >= 0 && index >= queue.items.length - 2 && queue.hasMore) {
      unawaited(queue.loadMore());
    }
  }

  /// 普通完播才自动进入来源下一项，暂停模式保持结束画面。
  @override
  Future<void> _advancePlaylistOnCompletion() async {
    if (_externalNavigationSuspended ||
        _abRepeatActive ||
        _playbackPreferences.mode == PlaybackMode.pause ||
        _playbackPreferences.mode == PlaybackMode.single) {
      return;
    }
    await _moveInPlaylist(forward: true, automatic: true);
  }

  /// 按当前来源移动；分页或详情失败保持当前项并给出可重试提示。
  @override
  Future<void> _moveInPlaylist({
    required bool forward,
    required bool automatic,
  }) async {
    if (_playlistMoving) return;
    final epoch = ++_playlistEpoch;
    final navigation = _partSwitchGeneration;
    setState(() => _playlistMoving = true);
    try {
      final partIndex = _currentPartIndex;
      if (!_playlistUsesExactParts) {
        final nextPart = partIndex + (forward ? 1 : -1);
        if (nextPart >= 0 && nextPart < _activeVideo.parts.length) {
          await _changePart(_activeVideo.parts[nextPart]);
          return;
        }
      }
      final queue = _playlist;
      PlaybackQueueItem? item;
      if (queue != null) {
        final index = queue.indexOf(_activeVideo.bvid, _currentPart.cid);
        if (forward) {
          item = await queue.nextAfter(_activeVideo.bvid, _currentPart.cid);
          if (queue.error != null) {
            if (mounted) _showPlayerNotice(queue.error!);
            return;
          }
        } else if (index > 0) {
          item = queue.items[index - 1];
        }
        if (item == null &&
            _playbackPreferences.mode == PlaybackMode.cycle &&
            queue.items.isNotEmpty &&
            (forward ? !queue.hasMore : true)) {
          item = forward ? queue.items.first : queue.items.last;
        }
      }
      if (!mounted ||
          epoch != _playlistEpoch ||
          navigation != _partSwitchGeneration) {
        return;
      }
      if (item != null) {
        await _openPlaylistItem(item, epoch: epoch);
      } else if (queue == null &&
          _playbackPreferences.mode == PlaybackMode.cycle) {
        final part = forward
            ? _activeVideo.parts.first
            : _activeVideo.parts.last;
        if (part.cid == _currentPart.cid) {
          await _restartPlaybackLoop();
        } else {
          await _changePart(part);
        }
      } else if (!automatic) {
        _showPlayerNotice(forward ? '已到列表末尾' : '已是第一项');
      }
    } catch (_) {
      if (mounted && epoch == _playlistEpoch) _showPlayerNotice('无法切换播放内容，请重试');
    } finally {
      if (mounted) {
        setState(() => _playlistMoving = false);
        _prefetchPlaylist();
      }
    }
  }

  /// 查询完整详情后切换；学习条目使用其保存的分 P，其他视频从第一 P 开始。
  Future<void> _openPlaylistItem(PlaybackQueueItem item, {int? epoch}) async {
    final request = epoch ?? ++_playlistEpoch;
    final navigation = _partSwitchGeneration;
    try {
      final video = await _bilibiliService.lookupVideo(item.bvid);
      if (!mounted ||
          request != _playlistEpoch ||
          navigation != _partSwitchGeneration) {
        return;
      }
      await _switchActiveVideo(
        video,
        learningEntry: item.learningEntry,
        fromBeginning: item.learningEntry == null,
      );
      if (mounted) setState(() => _completionPromptVisible = false);
    } catch (_) {
      if (mounted && request == _playlistEpoch) _showPlayerNotice('无法打开该项，请重试');
    }
  }

  /// 模式保存成功后再应用，避免重开播放器时意外恢复另一种行为。
  @override
  Future<void> _selectPlaybackMode(PlaybackMode mode) async {
    try {
      await _playbackPreferencesService.saveMode(mode);
      if (!mounted) return;
      _cancelPlaylistAdvance();
      _clearAbRepeatForNavigation();
      setState(() {
        _playbackPreferences = _playbackPreferences.copyWith(mode: mode);
        _playbackLoopEnabled = mode == PlaybackMode.single;
      });
      _showPlayerNotice(
        mode == PlaybackMode.single ? '已开启当前分P循环播放' : '已切换为${mode.label}',
      );
    } catch (_) {
      if (mounted) _showPlayerNotice('播放模式保存失败，请重试');
    }
  }

  /// 显示来源列表与播放模式；切换条目仍复用当前页面和媒体服务。
  @override
  Future<void> _showPlaylist() async {
    _prefetchPlaylist();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // 面板监听宿主与队列快照，关闭后不销毁当前播放列表。
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) {
          final queue = _playlist;
          return SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          queue?.title ?? '播放列表',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      DropdownButton<PlaybackMode>(
                        value: _playbackPreferences.mode,
                        items: PlaybackMode.values
                            .map(
                              (mode) => DropdownMenuItem(
                                value: mode,
                                child: Text(mode.label),
                              ),
                            )
                            .toList(),
                        // 选择模式后仅刷新仍打开的面板。
                        onChanged: (mode) async {
                          if (mode == null) return;
                          await _selectPlaybackMode(mode);
                          if (context.mounted) refresh(() {});
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([queue]),
                    // 分页完成后用最新快照构造列表及重试入口。
                    builder: (context, child) {
                      final items = queue?.items;
                      return ListView(
                        children: [
                          if (items == null)
                            for (final part in _activeVideo.parts)
                              ListTile(
                                title: Text(
                                  'P${part.pageNumber} ${part.title}',
                                ),
                                selected: part.cid == _currentPart.cid,
                                // 分 P 点选关闭面板后发送明确导航命令。
                                onTap: () {
                                  Navigator.pop(context);
                                  _cancelPlaylistAdvance();
                                  unawaited(_changePart(part));
                                },
                              )
                          else
                            for (final item in items)
                              ListTile(
                                title: Text(item.title),
                                selected: item.matches(
                                  _activeVideo.bvid,
                                  _currentPart.cid,
                                ),
                                // 只发起一次同页切换，不增加嵌套播放器。
                                onTap: () {
                                  Navigator.pop(context);
                                  unawaited(_openPlaylistItem(item));
                                },
                              ),
                          if (queue?.loading ?? false)
                            const LinearProgressIndicator(),
                          if (queue != null && queue.hasMore)
                            TextButton(
                              onPressed: queue.loading ? null : queue.loadMore,
                              child: Text(queue.error ?? '加载更多'),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 撤销在途导航并释放本次会话拥有的列表。
  void _disposePlaylist() {
    _cancelPlaylistAdvance();
    _playlist?.removeListener(_playlistChanged);
    _playlist?.dispose();
  }
}
