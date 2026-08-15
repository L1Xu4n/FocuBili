part of 'player_page.dart';

/// 封装分 P、互动剧情、章节、合集视频和嵌套播放器之间的导航。
mixin _PlayerVideoCoordinator
    on
        State<PlayerPage>,
        _PlayerPlaybackSession,
        _PlayerLearningCoordinator,
        _PlayerFocusCoordinator,
        _PlayerGestureCoordinator,
        _PlayerNotesWorkspace,
        _PlayerViewportCoordinator,
        _PlayerOverlayCoordinator,
        _PlayerControlsCoordinator {
  /// 更新当前正在展示的视频资料。
  set _activeVideo(VideoPreview value);

  /// 更新当前正在播放的分 P。
  set _currentPart(VideoPart value);

  /// 响应独立增强控制器变化，刷新章节界面，并处理已完播或即将到结尾的互动选择。
  void _handlePlayerEnhancementChanged() {
    if (!mounted) {
      return;
    }
    final PlaybackSnapshot snapshot = _playbackSnapshot;
    setState(() {
      if (snapshot.phase == PlaybackPhase.ended &&
          !_interactiveChoiceOpening &&
          _playerEnhancementController.handlesPlaybackCompletion) {
        _interactivePromptVisible = true;
        _completionPromptVisible = false;
        _showControls = true;
      }
    });
    _scheduleInteractiveChoicePrompt(snapshot);
  }

  /// 根据真实总时长安排选项计时器，让结尾前的毫秒提前量不会被半秒状态刷新跳过。
  @override
  void _scheduleInteractiveChoicePrompt(PlaybackSnapshot snapshot) {
    _interactivePromptTimer?.cancel();
    _interactivePromptTimer = null;
    if (!mounted ||
        snapshot.phase != PlaybackPhase.ready ||
        !snapshot.isPlaying ||
        snapshot.isInPictureInPicture ||
        _interactivePromptVisible ||
        _interactiveChoiceOpening) {
      return;
    }
    final Duration? delay = _playerEnhancementController.interactiveChoiceDelay(
      position: snapshot.position,
      duration: snapshot.duration,
    );
    if (delay == null) {
      return;
    }
    if (delay <= Duration.zero) {
      unawaited(_presentInteractiveChoice(snapshot));
      return;
    }
    _interactivePromptTimer = Timer(delay, () {
      _interactivePromptTimer = null;
      unawaited(_presentInteractiveChoice(_playbackSnapshot));
    });
  }

  /// 显示已经到时的互动选项，并按接口要求暂停当前节点而不替用户选择分支。
  Future<void> _presentInteractiveChoice(PlaybackSnapshot snapshot) async {
    if (!mounted ||
        snapshot.phase != PlaybackPhase.ready ||
        !snapshot.isPlaying ||
        _interactivePromptVisible ||
        _interactiveChoiceOpening ||
        !_playerEnhancementController.canPresentInteractiveChoice) {
      return;
    }
    _interactivePromptTimer?.cancel();
    _interactivePromptTimer = null;
    _playerEnhancementController.markInteractiveChoicePresented();
    setState(() {
      _interactivePromptVisible = true;
      _completionPromptVisible = false;
      _showControls = true;
    });
    if (!_playerEnhancementController.interactiveNode!.pauseVideoForChoice ||
        !snapshot.isPlaying) {
      return;
    }
    try {
      await _playbackService.pause();
    } catch (_) {
      if (mounted) {
        _showPlayerNotice('已到达剧情选择点，请选择下一步。');
      }
    }
  }

  /// 请求当前 BV 与 CID 的章节及互动信息，旧请求由控制器令牌自动丢弃。
  @override
  Future<void> _loadPlayerEnhancements() {
    return _playerEnhancementController.load(
      bvid: _activeVideo.bvid,
      cid: _currentPart.cid,
    );
  }

  /// 保存旧分P后打开新分P，由播放后端按目标 CID 恢复该分P自己的进度。
  @override
  Future<void> _changePart(VideoPart part) async {
    if (part.cid == _currentPart.cid) {
      if (_partSelectorExpanded) {
        _closePartSelector();
      }
      return;
    }
    await _deactivateFocusPlaybackForCurrentPart();
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    _resetVideoShotPreview();
    setState(() {
      _currentPart = part;
      _progress = 0;
      _showControls = true;
      _resumeNotice = null;
      _partSelectorExpanded = false;
      _resetPlaybackProgressTracking();
      _interactivePromptVisible = false;
    });
    _shownRestoredCid = null;
    _openingResumePlan = PlaybackResumePlan.direct(part: part);
    _resumeNoticeTimer?.cancel();
    _resetFocusPlaybackIdentity();
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_loadPlayerEnhancements());
    try {
      await _playbackService.openVideo(
        _activeVideo,
        part: part,
        quality: _currentQuality,
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法切换分P：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法切换分P：$error');
    }
  }

  /// 打开用户明确选择的互动剧情 CID，并提前读取这个节点的下一批选择。
  Future<void> _playInteractiveChoice(InteractiveVideoChoice choice) async {
    if (_interactiveChoiceOpening) {
      return;
    }
    setState(() {
      _interactiveChoiceOpening = true;
      _interactivePromptVisible = false;
      _completionPromptVisible = false;
    });
    await _deactivateFocusPlaybackForCurrentPart();
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    _resetVideoShotPreview();
    final VideoPart branchPart = VideoPart(
      pageNumber: _currentPart.pageNumber,
      cid: choice.cid,
      title: choice.label,
      duration: Duration.zero,
    );
    setState(() {
      _currentPart = branchPart;
      _progress = 0;
      _showControls = true;
      _resumeNotice = null;
      _resetPlaybackProgressTracking();
    });
    _shownRestoredCid = null;
    _openingResumePlan = PlaybackResumePlan.direct(part: branchPart);
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_playerEnhancementController.selectChoice(choice));
    try {
      await _playbackService.openVideo(
        _activeVideo,
        part: branchPart,
        quality: _currentQuality,
        initialPosition: Duration.zero,
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法打开互动剧情：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法打开互动剧情：$error');
    } finally {
      if (mounted) {
        setState(() => _interactiveChoiceOpening = false);
      }
    }
  }

  /// 跳到章节开始时间，并保持用户原来的播放或暂停状态。
  Future<void> _seekToChapter(Duration position) async {
    try {
      await _seekNativeTo(position);
      if (mounted && _displayDuration > Duration.zero) {
        setState(() {
          _progress =
              (position.inMilliseconds / _displayDuration.inMilliseconds)
                  .clamp(0, 1)
                  .toDouble();
        });
      }
      _showPlayerControls();
    } catch (error) {
      if (mounted) {
        _showPlayerNotice('暂时无法跳转到这个视频分段。');
      }
    }
  }

  /// 打开独立的分段信息面板；竖屏从底部出现，横屏从右侧出现。
  Future<void> _showVideoChapterPanel() async {
    final List<VideoChapter> chapters = _playerEnhancementController.chapters;
    if (chapters.isEmpty) {
      _showPlayerNotice('当前视频没有分段信息。');
      return;
    }
    await showVideoChapterPanel(
      context: context,
      chapters: chapters,
      position: _playbackSnapshot.position,
      chapterProgressVisible:
          _playerEnhancementController.chapterProgressVisible,
      // 分段面板跳转函数把用户选择的开始时间交给原生播放器。
      onSeek: (Duration position) => unawaited(_seekToChapter(position)),
      onToggleChapterProgress:
          _playerEnhancementController.toggleChapterProgress,
    );
  }

  /// 返回当前分P在视频分P列表中的位置。
  int get _currentPartIndex => _activeVideo.parts.indexWhere(
    (VideoPart part) => part.cid == _currentPart.cid,
  );

  /// 切换到当前分P的上一集；已是第一集时保持禁用。
  void _playPreviousPart() {
    final int index = _currentPartIndex;
    if (index > 0) {
      unawaited(_changePart(_activeVideo.parts[index - 1]));
    }
  }

  /// 切换到当前分P的下一集；已是最后一集时保持禁用。
  void _playNextPart() {
    final int index = _currentPartIndex;
    if (index >= 0 && index < _activeVideo.parts.length - 1) {
      unawaited(_changePart(_activeVideo.parts[index + 1]));
    }
  }

  /// 当下层播放器夺走唯一原生通道时，重新创建纹理并打开当前视频，恢复原页面的播放所有权。
  Future<void> _restorePlaybackAfterNestedPlayer({
    required bool shouldResume,
  }) async {
    final PlaybackService service = _playbackService;
    if (service is! NativePlaybackService || service.ownsPlatformChannel) {
      return;
    }
    try {
      final int? textureId = await service.initialize();
      if (!mounted) {
        return;
      }
      setState(() {
        _textureId = textureId;
        _playbackSnapshot = _playbackSnapshot.copyWith(
          phase: PlaybackPhase.loading,
          isPlaying: false,
          message: '正在恢复原视频…',
        );
      });
      _openingResumePlan = PlaybackResumePlan.direct(
        part: _currentPart,
        position: _playbackSnapshot.position,
        positionSource: PlaybackResumePositionSource.internalRecovery,
      );
      await service.openVideo(
        _activeVideo,
        part: _currentPart,
        quality: _currentQuality,
        initialPosition: _openingResumePlan!.position,
      );
      if (_playbackSpeed != 1) {
        await service.setPlaybackSpeed(_playbackSpeed);
      }
      if (!shouldResume) {
        await service.pause();
      }
    } catch (error) {
      if (mounted) {
        _showPlaybackError('返回原视频时恢复播放失败：$error');
      }
    }
  }

  /// 暂停当前视频后打开 UP 主公开主页，返回时重建被下层播放器占用的原生会话。
  Future<void> _openOwnerProfile() async {
    if (_activeVideo.ownerMid <= 0) {
      _showPlayerNotice('暂时没有这个 UP 主的主页编号');
      return;
    }
    final bool shouldResume = _playing;
    if (shouldResume) {
      await _playbackService.pause();
    }
    if (!mounted) {
      return;
    }
    await _showStandardSystemUiForNestedRoute();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 用户主页构建函数传入已有昵称头像，并复用公开内容服务。
        builder: (BuildContext context) => UserProfilePage(
          mid: _activeVideo.ownerMid,
          initialName: _activeVideo.ownerName,
          initialAvatarUrl: _activeVideo.ownerAvatarUrl,
          publicContentService: _publicContentService,
          videoService: _bilibiliService,
          learningListService: _learningListService,
          watchHistoryService: _watchHistoryService,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    _resumePlayerSystemUiAfterNestedRoute();
    await _restorePlaybackAfterNestedPlayer(shouldResume: shouldResume);
    if (mounted && shouldResume && !_playing) {
      await _playbackService.play();
    }
  }

  /// 查询合集条目的完整详情，再在当前原生播放器中切换，避免旧页面销毁新播放器。
  Future<void> _openCollectionVideo(VideoCollectionEntry entry) async {
    if (_openingCollectionBvid != null || entry.bvid == _activeVideo.bvid) {
      return;
    }
    setState(() => _openingCollectionBvid = entry.bvid);
    try {
      final VideoPreview video = await _bilibiliService.lookupVideo(entry.bvid);
      final VideoPreview previousVideo = _activeVideo;
      await _switchActiveVideo(video);
      _collectionVideoBackStack.add(previousVideo);
    } catch (error) {
      if (mounted) {
        _showPlayerNotice('无法打开合集视频：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _openingCollectionBvid = null);
      }
    }
  }

  /// 复用现有纹理打开另一支视频；学习任务可精确指定分 P 与进度，避免替换页面释放新播放器。
  @override
  Future<void> _switchActiveVideo(
    VideoPreview video, {
    LearningListEntry? learningEntry,
  }) async {
    await _deactivateFocusPlaybackForCurrentPart();
    _notesPanelAnimationTimer?.cancel();
    _flushVideoNoteAutoSave();
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    await _playbackService.pause();
    final SavedPlaybackState? savedState = await _playbackService
        .loadSavedPlaybackState(video.bvid);
    final LearningListEntry? requestedLearningEntry =
        learningEntry != null && learningEntry.bvid == video.bvid
        ? learningEntry
        : null;
    int? requestedPartCid;
    if (requestedLearningEntry != null) {
      for (final VideoPart part in video.parts) {
        if (part.cid == requestedLearningEntry.partCid) {
          requestedPartCid = part.cid;
          break;
        }
        if (part.pageNumber == requestedLearningEntry.partPageNumber) {
          requestedPartCid = part.cid;
        }
      }
    }
    final WatchHistoryEntry? historyEntry = requestedLearningEntry == null
        ? await _loadWatchHistoryResumeEntry(video.bvid)
        : null;
    final PlaybackResumePlan resolvedPlan = PlaybackResumePlan.resolve(
      video: video,
      requestedPartCid: requestedPartCid,
      requestedPosition: requestedLearningEntry?.position,
      savedState: savedState,
      historyEntry: historyEntry,
    );
    final PlaybackResumePlan resumePlan = requestedLearningEntry == null
        ? resolvedPlan
        : PlaybackResumePlan.direct(
            part: resolvedPlan.part,
            position: resolvedPlan.position,
            positionSource: PlaybackResumePositionSource.requested,
          );
    final VideoPart targetPart = resumePlan.part;
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    _resetVideoShotPreview();
    if (!mounted) {
      return;
    }
    setState(() {
      _activeVideo = video;
      _currentPart = targetPart;
      _playbackSnapshot = _playbackSnapshot.copyWith(
        phase: PlaybackPhase.loading,
        isPlaying: false,
        position: Duration.zero,
        duration: Duration.zero,
        restoredPosition: Duration.zero,
        clearMessage: true,
      );
      _progress = 0;
      _showControls = true;
      _partSelectorExpanded = false;
      _descriptionExpanded = false;
      _resumeNotice = null;
      _notesOpen = false;
      _notesLoading = false;
      _noteSaving = false;
      _noteAutoSaving = false;
      _noteAutoSavePending = false;
      _currentVideoNotes = const <VideoNote>[];
      _editingVideoNote = null;
      _noteTitleController.clear();
      _noteBodyController.clear();
      _notePartCid = targetPart.cid;
      _includeCurrentFrame = false;
      _noteFramePath = null;
      _fullscreenNoteListCollapsed = false;
      _notesOverlayMounted = false;
      _locatedCollectionPreviewBvid = null;
      _resetPlaybackProgressTracking(learningEntry: requestedLearningEntry);
      _interactivePromptVisible = false;
      _interactiveChoiceOpening = false;
    });
    _shownRestoredCid = null;
    _openingResumePlan = resumePlan;
    _resumeNoticeTimer?.cancel();
    _resetFocusPlaybackIdentity();
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_loadPlayerEnhancements());
    await _playbackService.openVideo(
      video,
      part: targetPart,
      quality: _currentQuality,
      initialPosition: resumePlan.position,
    );
    if (resumePlan.shouldShowPartNotice && video.parts.length > 1) {
      _showPartRestoreSnackBar(targetPart.pageNumber);
    }
  }

  /// 从合集内部返回栈取出上一支视频，使返回键符合“回到切换前视频”的预期。
  @override
  Future<void> _restorePreviousCollectionVideo() async {
    if (_openingCollectionBvid != null || _collectionVideoBackStack.isEmpty) {
      return;
    }
    final VideoPreview previousVideo = _collectionVideoBackStack.removeLast();
    setState(() => _openingCollectionBvid = previousVideo.bvid);
    try {
      await _switchActiveVideo(previousVideo);
    } catch (error) {
      _collectionVideoBackStack.add(previousVideo);
      if (mounted) {
        _showPlayerNotice('无法返回上一支合集视频：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _openingCollectionBvid = null);
      }
    }
  }

  /// 打开当前合集的底部列表，让用户在同一播放器内选择其他独立视频。
  Future<void> _showCollectionSheet(VideoCollection collection) async {
    final VideoCollectionEntry? selected =
        await showModalBottomSheet<VideoCollectionEntry>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          // 合集面板构建函数提供搜索、排序、当前位置与本机观看标记。
          builder: (BuildContext sheetContext) => _CollectionPickerSheet(
            collection: collection,
            currentBvid: _activeVideo.bvid,
            watchHistoryByBvid: _watchHistoryByBvid,
            // 合集面板加入函数沿用播放器的完整视频查询与学习清单服务。
            onAddToLearningList: (VideoCollectionEntry entry) =>
                unawaited(_addCollectionVideoToLearningList(entry)),
          ),
        );
    if (selected != null && mounted && selected.bvid != _activeVideo.bvid) {
      await _openCollectionVideo(selected);
    }
  }

  /// 由页面状态类提供公开 UP 主页面使用的只读内容服务。
  BilibiliPublicContentService get _publicContentService;

  /// 由页面状态类提供互动选项提示计时器。
  Timer? get _interactivePromptTimer;
  set _interactivePromptTimer(Timer? value);

  /// 由页面状态类标记互动分支是否正在打开。
  bool get _interactiveChoiceOpening;
  set _interactiveChoiceOpening(bool value);

  /// 由页面状态类标记当前正在查询的合集视频。
  String? get _openingCollectionBvid;
  set _openingCollectionBvid(String? value);

  /// 由页面状态类提供合集预览的滚动控制器。
  ScrollController get _collectionPreviewScrollController;

  /// 由页面状态类记录合集预览已经定位的视频。
  set _locatedCollectionPreviewBvid(String? value);

  /// 由页面状态类提供详情简介的展开状态。
  set _descriptionExpanded(bool value);

  /// 取消互动提示并释放合集预览和增强控制器。
  void _disposePlayerVideoCoordinator() {
    _interactivePromptTimer?.cancel();
    _collectionPreviewScrollController.dispose();
    _playerEnhancementController.removeListener(
      _handlePlayerEnhancementChanged,
    );
    _playerEnhancementController.dispose();
  }
}
