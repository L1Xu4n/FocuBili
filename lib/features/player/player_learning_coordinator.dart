part of 'player_page.dart';

/// 封装播放器内学习清单、观看记录、完播进度和跨视频继续学习流程。
mixin _PlayerLearningCoordinator on State<PlayerPage>, _PlayerPlaybackSession {
  static const Duration _watchHistoryProgressSaveInterval = Duration(
    seconds: 15,
  );

  int? _recordedHistoryPartCid;
  Duration _lastHistorySavedPosition = Duration.zero;
  @override
  LearningListEntry? _learningListEntry;
  bool _learningListLoading = false;
  String? _addingLearningBvid;
  int? _recordedLearningListPartCid;
  Duration _lastLearningListSavedPosition = Duration.zero;
  bool _learningProgressSaveInFlight = false;
  Map<String, WatchHistoryEntry> _watchHistoryByBvid =
      const <String, WatchHistoryEntry>{};

  /// 由播放器状态类提供本机观看记录服务。
  @override
  WatchHistoryService get _watchHistoryService;

  /// 由播放器状态类提供本机学习清单服务。
  LearningListService get _learningListService;

  /// 由播放器状态类提供视频详情查询服务。
  BilibiliService get _bilibiliService;

  /// 说明播放器当前是否真的处于播放状态。
  bool get _playing;

  /// 提供播放器当前用于界面计算的总时长。
  Duration get _displayDuration;

  /// 使用播放器画面提示展示合集和完播操作结果。
  void _showPlayerNotice(String message);

  /// 在同一个播放页面中打开下一支视频，并允许精确恢复学习任务。
  Future<void> _switchActiveVideo(
    VideoPreview video, {
    LearningListEntry? learningEntry,
  });

  /// 读取本机观看记录并按 BV 号索引，供合集封面显示“上次看过”。
  Future<void> _loadWatchHistoryBadges() async {
    final List<WatchHistoryEntry> entries = await _watchHistoryService
        .loadHistory();
    if (!mounted) {
      return;
    }
    setState(() {
      _watchHistoryByBvid = <String, WatchHistoryEntry>{
        for (final WatchHistoryEntry entry in entries) entry.bvid: entry,
      };
    });
  }

  /// 读取当前视频分 P 是否已在学习清单中，避免同一视频的其他 P 覆盖当前任务状态。
  @override
  Future<void> _loadCurrentLearningListEntry() async {
    final String requestedBvid = _activeVideo.bvid;
    final int requestedPartCid = _currentPart.cid;
    if (mounted) {
      setState(() => _learningListLoading = true);
    }
    final List<LearningListEntry> entries = await _learningListService
        .loadEntries();
    if (!mounted ||
        _activeVideo.bvid != requestedBvid ||
        _currentPart.cid != requestedPartCid) {
      return;
    }
    final LearningListEntry? matched = _learningListService.findEntryForPart(
      entries,
      requestedBvid,
      requestedPartCid,
    );
    setState(() {
      _learningListEntry = matched;
      _learningListLoading = false;
      _recordedLearningListPartCid = matched?.partCid;
      _lastLearningListSavedPosition = matched?.position ?? Duration.zero;
    });
  }

  /// 将当前分 P 加入学习清单；播放器已就绪时优先保存真实进度。
  Future<void> _addCurrentVideoToLearningList() async {
    if (_addingLearningBvid != null) {
      return;
    }
    final VideoPreview video = _activeVideo;
    final VideoPart part = _currentPart;
    final String bvid = video.bvid;
    final bool hasLivePlayback = _playbackSnapshot.phase == PlaybackPhase.ready;
    setState(() => _addingLearningBvid = bvid);
    try {
      final List<LearningListEntry> entries = await _learningListService
          .addVideo(
            video,
            part: part,
            position: hasLivePlayback ? _playbackSnapshot.position : null,
            status: hasLivePlayback && _playing
                ? LearningListStatus.learning
                : null,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != part.cid) {
        return;
      }
      final LearningListEntry? entry = _entryForPart(entries, bvid, part.cid);
      setState(() {
        _learningListEntry = entry;
        _recordedLearningListPartCid = entry?.partCid;
        _lastLearningListSavedPosition = entry?.position ?? Duration.zero;
      });
      _showTransientSnackBar('已将 P${part.pageNumber} 加入学习清单');
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('加入学习清单失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 处理详情顶部学习清单按钮：未加入时加入，已加入时先询问是否取消。
  Future<void> _handleCurrentVideoLearningListTap() async {
    if (_learningListLoading || _addingLearningBvid != null) {
      return;
    }
    if (_currentLearningListEntry == null) {
      await _addCurrentVideoToLearningList();
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('取消加入学习清单'),
        content: Text(
          '确定把“${_activeVideo.title}”的 P${_currentPart.pageNumber} 移出学习清单吗？观看记录和笔记不会被删除。',
        ),
        actions: <Widget>[
          TextButton(
            // 保留按钮函数只关闭确认框，不修改学习清单。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('保留'),
          ),
          FilledButton(
            // 取消加入按钮函数把确认结果交回播放器，再执行本机移除操作。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('取消加入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _removeCurrentVideoFromLearningList();
  }

  /// 从本机学习清单移除当前分 P，不影响同视频其他 P、观看记录或笔记。
  Future<void> _removeCurrentVideoFromLearningList() async {
    if (_addingLearningBvid != null) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    final int partCid = _currentPart.cid;
    setState(() => _addingLearningBvid = bvid);
    try {
      await _learningListService.remove(bvid, partCid: partCid);
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != partCid) {
        return;
      }
      setState(() {
        _learningListEntry = null;
        _recordedLearningListPartCid = null;
        _lastLearningListSavedPosition = Duration.zero;
      });
      _showTransientSnackBar('已将当前分 P 移出学习清单');
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('取消加入学习清单失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 查询合集条目的完整资料后加入学习清单；当前正在播放的视频无需重复查询。
  Future<void> _addCollectionVideoToLearningList(
    VideoCollectionEntry entry,
  ) async {
    if (_addingLearningBvid != null) {
      return;
    }
    final String bvid = entry.bvid;
    setState(() => _addingLearningBvid = bvid);
    try {
      final bool currentVideo = bvid == _activeVideo.bvid;
      final VideoPreview video = currentVideo
          ? _activeVideo
          : await _bilibiliService.lookupVideo(bvid);
      final bool hasLivePlayback =
          currentVideo && _playbackSnapshot.phase == PlaybackPhase.ready;
      final List<LearningListEntry> entries = await _learningListService
          .addVideo(
            video,
            part: hasLivePlayback ? _currentPart : null,
            position: hasLivePlayback ? _playbackSnapshot.position : null,
            status: hasLivePlayback && _playing
                ? LearningListStatus.learning
                : null,
          );
      if (!mounted) {
        return;
      }
      if (_activeVideo.bvid == bvid) {
        final LearningListEntry? learningEntry = _entryForPart(
          entries,
          bvid,
          _currentPart.cid,
        );
        setState(() {
          _learningListEntry = learningEntry;
          _recordedLearningListPartCid = learningEntry?.partCid;
          _lastLearningListSavedPosition =
              learningEntry?.position ?? Duration.zero;
        });
      }
      _showPlayerNotice('已加入学习清单');
    } catch (_) {
      if (mounted) {
        _showPlayerNotice('加入学习清单失败，请检查网络后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 从服务返回的任务列表中取出指定 BV 与 CID，避免同视频不同 P 读到错误任务。
  LearningListEntry? _entryForPart(
    List<LearningListEntry> entries,
    String bvid,
    int partCid,
  ) {
    return _learningListService.findEntryForPart(entries, bvid, partCid);
  }

  /// 只返回与画面当前 BV 和 CID 完全一致的任务，异步旧结果不会污染其他分 P 按钮。
  LearningListEntry? get _currentLearningListEntry {
    final LearningListEntry? entry = _learningListEntry;
    if (entry == null ||
        !entry.matchesPart(_activeVideo.bvid, _currentPart.cid)) {
      return null;
    }
    return entry;
  }

  /// 在播放状态真实变化或进度跨过保存间隔时，把当前任务写回学习清单。
  @override
  void _recordLearningListProgressWhenNeeded(PlaybackSnapshot snapshot) {
    final LearningListEntry? entry = _currentLearningListEntry;
    if (entry == null ||
        entry.status == LearningListStatus.completed ||
        snapshot.phase != PlaybackPhase.ready) {
      return;
    }
    final int positionDeltaMs =
        (snapshot.position.inMilliseconds -
                _lastLearningListSavedPosition.inMilliseconds)
            .abs();
    final bool partChanged = _recordedLearningListPartCid != _currentPart.cid;
    final bool crossedInterval =
        positionDeltaMs >= _watchHistoryProgressSaveInterval.inMilliseconds;
    final bool startedLearning =
        snapshot.isPlaying && entry.status != LearningListStatus.learning;
    final bool pausedAtNewPosition =
        !snapshot.isPlaying && positionDeltaMs >= 1000;
    if (!partChanged &&
        !crossedInterval &&
        !startedLearning &&
        !pausedAtNewPosition) {
      return;
    }
    _recordedLearningListPartCid = _currentPart.cid;
    unawaited(
      _saveCurrentLearningListProgress(
        snapshot.position,
        status: snapshot.isPlaying ? LearningListStatus.learning : null,
      ),
    );
  }

  /// 在离开、换分P或播放结束前补存学习任务的当前位置，不自动改变完成状态。
  @override
  void _flushCurrentLearningListProgress() {
    final LearningListEntry? entry = _currentLearningListEntry;
    if (entry == null ||
        entry.status == LearningListStatus.completed ||
        (_recordedLearningListPartCid != _currentPart.cid &&
            _playbackSnapshot.position == Duration.zero)) {
      return;
    }
    unawaited(
      _saveCurrentLearningListProgress(
        _playbackSnapshot.position,
        status: _playing ? LearningListStatus.learning : null,
        force: true,
      ),
    );
  }

  /// 把当前真实分P和位置持久化给已有任务；不存在的任务不会被播放器静默创建。
  Future<void> _saveCurrentLearningListProgress(
    Duration position, {
    LearningListStatus? status,
    bool force = false,
  }) async {
    final LearningListEntry? entry = _currentLearningListEntry;
    if (entry == null || _learningProgressSaveInFlight) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    final VideoPart part = _currentPart;
    final LearningListStatus? safeStatus =
        entry.status == LearningListStatus.completed
        ? LearningListStatus.completed
        : status;
    final Duration safePosition = position.isNegative
        ? Duration.zero
        : position;
    final int positionDeltaMs =
        (safePosition.inMilliseconds -
                _lastLearningListSavedPosition.inMilliseconds)
            .abs();
    if (!force &&
        _recordedLearningListPartCid == part.cid &&
        positionDeltaMs < 1000 &&
        (safeStatus == null || safeStatus == entry.status)) {
      return;
    }
    _learningProgressSaveInFlight = true;
    try {
      final List<LearningListEntry> entries = await _learningListService
          .updateProgress(
            bvid,
            part: part,
            position: safePosition,
            status: safeStatus,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != part.cid) {
        return;
      }
      final LearningListEntry? updated = _entryForPart(entries, bvid, part.cid);
      if (updated != null) {
        setState(() {
          _learningListEntry = updated;
          _recordedLearningListPartCid = part.cid;
          _lastLearningListSavedPosition = updated.position;
        });
      }
    } catch (_) {
      // 学习清单写入失败不应中断播放；之后的进度检查会再次尝试保存。
    } finally {
      _learningProgressSaveInFlight = false;
    }
  }

  /// 把当前已加入清单的分 P 标记完成，并让按钮立即显示“已标记完成”。
  Future<void> _markCurrentLearningCompleted() async {
    final LearningListEntry? current = _currentLearningListEntry;
    if (_addingLearningBvid != null ||
        current == null ||
        !current.matchesPart(_activeVideo.bvid, _currentPart.cid) ||
        current.status == LearningListStatus.completed) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    setState(() => _addingLearningBvid = bvid);
    try {
      final List<LearningListEntry> entries = await _learningListService
          .updateProgress(
            bvid,
            part: _currentPart,
            position: _displayDuration,
            status: LearningListStatus.completed,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != current.partCid) {
        return;
      }
      final LearningListEntry? completed = _entryForPart(
        entries,
        bvid,
        current.partCid,
      );
      setState(() {
        _learningListEntry = completed;
        _completionPromptVisible = true;
        _completionLearningFinished = false;
        _recordedLearningListPartCid = _currentPart.cid;
        _lastLearningListSavedPosition =
            completed?.position ?? _displayDuration;
      });
      _showPlayerNotice('已标记完成');
    } catch (_) {
      if (mounted) {
        _showPlayerNotice('标记完成失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 完成当前分 P 后在同一播放器内打开下一项；最后一项则保留提示并显示全部完成。
  Future<void> _continueLearningAfterCompletion() async {
    final LearningListEntry? current = _currentLearningListEntry;
    if (_addingLearningBvid != null ||
        current == null ||
        !current.matchesPart(_activeVideo.bvid, _currentPart.cid)) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    setState(() => _addingLearningBvid = bvid);
    try {
      final List<LearningListEntry> beforeCompletion =
          await _learningListService.loadEntries();
      final LearningListEntry? next = _learningListService.nextIncompleteAfter(
        beforeCompletion,
        current,
      );
      final List<LearningListEntry> updatedEntries = await _learningListService
          .updateProgress(
            bvid,
            part: _currentPart,
            position: _displayDuration,
            status: LearningListStatus.completed,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != current.partCid) {
        return;
      }
      final LearningListEntry? completed = _entryForPart(
        updatedEntries,
        bvid,
        current.partCid,
      );
      if (next == null) {
        setState(() {
          _learningListEntry = completed;
          _completionPromptVisible = true;
          _completionLearningFinished = true;
          _recordedLearningListPartCid = _currentPart.cid;
          _lastLearningListSavedPosition =
              completed?.position ?? _displayDuration;
        });
        _showPlayerNotice('学习清单已完成');
        return;
      }
      final VideoPreview nextVideo = next.bvid == _activeVideo.bvid
          ? _activeVideo
          : await _bilibiliService.lookupVideo(next.bvid);
      if (!mounted || _activeVideo.bvid != bvid) {
        return;
      }
      await _switchActiveVideo(nextVideo, learningEntry: next);
    } catch (_) {
      if (mounted) {
        if (_activeVideo.bvid == bvid && _currentPart.cid == current.partCid) {
          setState(() {
            _learningListEntry = _learningListEntry?.copyWith(
              status: LearningListStatus.completed,
            );
            _completionPromptVisible = true;
            _completionLearningFinished = false;
          });
        }
        _showPlayerNotice('继续学习失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 仅在某个分P第一次进入就绪状态时记录观看历史，避免状态流重复写入。
  @override
  void _recordWatchHistoryWhenReady(PlaybackSnapshot snapshot) {
    if (snapshot.phase != PlaybackPhase.ready ||
        _recordedHistoryPartCid == _currentPart.cid) {
      return;
    }
    _recordedHistoryPartCid = _currentPart.cid;
    unawaited(_saveCurrentWatchHistory(snapshot.position));
  }

  /// 每隔一小段实际播放进度或暂停后保存当前位置，避免历史进度每半秒写入一次。
  @override
  void _recordWatchHistoryProgressWhenNeeded(PlaybackSnapshot snapshot) {
    if (snapshot.phase != PlaybackPhase.ready ||
        _recordedHistoryPartCid != _currentPart.cid) {
      return;
    }
    final int positionDeltaMs =
        (snapshot.position.inMilliseconds -
                _lastHistorySavedPosition.inMilliseconds)
            .abs();
    final bool crossedInterval =
        positionDeltaMs >= _watchHistoryProgressSaveInterval.inMilliseconds;
    final bool pausedAtNewPosition =
        !snapshot.isPlaying && positionDeltaMs >= 1000;
    if (!crossedInterval && !pausedAtNewPosition) {
      return;
    }
    unawaited(_saveCurrentWatchHistory(snapshot.position));
  }

  /// 在离开或切换分P前补存有变化的位置，保证短时间观看也能出现在历史缩略图中。
  @override
  void _flushCurrentWatchHistoryProgress() {
    if (_recordedHistoryPartCid != _currentPart.cid ||
        _playbackSnapshot.position == _lastHistorySavedPosition) {
      return;
    }
    unawaited(_saveCurrentWatchHistory(_playbackSnapshot.position));
  }

  /// 把当前视频、分P、封面和播放位置交给本机历史服务，写入失败不影响播放。
  Future<void> _saveCurrentWatchHistory(Duration position) async {
    final Duration safePosition = position.isNegative
        ? Duration.zero
        : position;
    _lastHistorySavedPosition = safePosition;
    try {
      final WatchHistoryEntry entry = WatchHistoryEntry(
        bvid: _activeVideo.bvid,
        title: _activeVideo.title,
        ownerName: _activeVideo.ownerName,
        lastPartTitle: _currentPart.title,
        lastPartPageNumber: _currentPart.pageNumber,
        watchedAt: DateTime.now(),
        thumbnailUrl: _activeVideo.thumbnailUrl,
        lastPosition: safePosition,
      );
      final List<WatchHistoryEntry> updated = await _watchHistoryService.record(
        entry,
      );
      if (mounted) {
        setState(() {
          _watchHistoryByBvid = <String, WatchHistoryEntry>{
            for (final WatchHistoryEntry item in updated) item.bvid: item,
          };
        });
      }
    } catch (_) {
      // 本地偏好设置异常不能中断播放器；后续换P或重新打开时仍会再次尝试保存。
    }
  }

  /// 切换分 P、互动节点或活动视频时统一清空旧进度身份，并可预置下一项学习任务。
  void _resetPlaybackProgressTracking({LearningListEntry? learningEntry}) {
    _recordedHistoryPartCid = null;
    _lastHistorySavedPosition = Duration.zero;
    _learningListEntry = learningEntry;
    _learningListLoading = false;
    _recordedLearningListPartCid = null;
    _lastLearningListSavedPosition = learningEntry?.position ?? Duration.zero;
    _completionPromptVisible = false;
    _completionLearningFinished = false;
  }
}
