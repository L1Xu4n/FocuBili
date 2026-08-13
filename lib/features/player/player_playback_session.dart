part of 'player_page.dart';

/// 封装播放器会话初始化、状态快照同步、续播恢复、清晰度确认和失败重试。
mixin _PlayerPlaybackSession on State<PlayerPage> {
  static const Duration _sessionTransientHintDuration = Duration(seconds: 3);

  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  PlaybackSnapshot _playbackSnapshot = const PlaybackSnapshot();
  int? _textureId;
  String? _resumeNotice;
  Timer? _resumeNoticeTimer;
  int _currentQuality = 64;
  int? _pendingQualitySelection;
  bool _qualitySelectionSawLoading = false;
  List<PlaybackQuality> _availableQualities = const <PlaybackQuality>[
    PlaybackQuality(id: 64, label: '高清 720P'),
  ];
  bool _isRetrying = false;
  int? _shownRestoredCid;
  bool _completionPromptVisible = false;
  bool _completionLearningFinished = false;
  bool _interactivePromptVisible = false;
  int _preferredOpeningQuality = PreferredPlaybackQuality.p720.id;
  bool _defaultQualityPending = true;
  Duration? _pendingInitialPosition;

  /// 由页面状态提供循环播放开关。
  bool get _playbackLoopEnabled;

  /// 由页面状态更新循环播放开关。
  set _playbackLoopEnabled(bool value);

  /// 由页面状态提供“播放 N 次后暂停”的总次数。
  int? get _pauseAfterPlayCount;

  /// 由页面状态清除“播放 N 次后暂停”的设置。
  set _pauseAfterPlayCount(int? value);

  /// 由页面状态记录当前会话已经完整播放的次数。
  int get _completedPlayCount;

  /// 由页面状态更新已经完整播放的次数。
  set _completedPlayCount(int value);

  /// 由页面状态防止同一个 ended 边沿发起多个循环重启。
  bool get _loopRestartInFlight;

  /// 由页面状态更新循环重启保护标记。
  set _loopRestartInFlight(bool value);

  /// 由播放器状态类提供当前平台的播放服务。
  PlaybackService get _playbackService;

  /// 由播放器状态类提供设备网络和电量服务。
  DeviceStatusService get _deviceStatusService;

  /// 由播放器状态类提供播放偏好持久化服务。
  PlaybackPreferencesService get _playbackPreferencesService;

  /// 由播放器状态类提供脱敏问题诊断服务。
  ProblemDiagnosticsService get _problemDiagnosticsService;

  /// 由播放器状态类提供当前正在展示的视频资料。
  VideoPreview get _activeVideo;

  /// 读取当前正在播放的分 P。
  VideoPart get _currentPart;

  /// 读取播放器已加载的个性化偏好。
  PlaybackPreferences get _playbackPreferences;

  /// 更新播放器已加载的个性化偏好。
  set _playbackPreferences(PlaybackPreferences value);

  /// 说明用户当前是否正在拖动底部进度条。
  bool get _isDraggingProgress;

  /// 说明用户当前是否正在横滑预览进度。
  bool get _horizontalScrubbing;

  /// 更新播放器当前显示的进度比例。
  set _progress(double value);

  /// 更新播放器当前显示的倍速。
  set _playbackSpeed(double value);

  /// 读取播放器控制层是否可见。
  bool get _showControls;

  /// 更新播放器控制层可见状态。
  set _showControls(bool value);

  /// 说明控制层是否已有自动隐藏计时器。
  bool get _controlsAutoHideScheduled;

  /// 提供当前分 P 对应的学习清单记录。
  LearningListEntry? get _learningListEntry;

  /// 提供当前视频的章节和互动增强控制器。
  PlayerEnhancementController get _playerEnhancementController;

  /// 说明用户当前是否启用了弹幕。
  bool get _danmakuEnabled;

  /// 把恢复分 P、系统亮度音量、网络和默认清晰度写入页面共享状态。
  void _applyInitialPlaybackConfiguration({
    required VideoPart part,
    required SystemPlaybackLevels levels,
    required DeviceNetworkType networkType,
    required int preferredQuality,
  });

  /// 重新读取当前视频在学习清单中的状态。
  Future<void> _loadCurrentLearningListEntry();

  /// 加载当前分 P 的章节和互动增强信息。
  Future<void> _loadPlayerEnhancements();

  /// 请求播放器切换到指定清晰度。
  Future<void> _changeQuality(int quality);

  /// 从指定时间重新开始弹幕呈现。
  void _restartDanmakuPresentationFrom(Duration position);

  /// 按最新快照同步弹幕动画时钟。
  void _syncDanmakuAnimation(PlaybackSnapshot snapshot);

  /// 显示高画质可能受大会员权限限制的提示。
  void _showMembershipQualityNotice();

  /// 首次就绪时创建或更新观看记录。
  void _recordWatchHistoryWhenReady(PlaybackSnapshot snapshot);

  /// 在播放过程中按间隔保存观看进度。
  void _recordWatchHistoryProgressWhenNeeded(PlaybackSnapshot snapshot);

  /// 在播放过程中按间隔保存学习清单进度。
  void _recordLearningListProgressWhenNeeded(PlaybackSnapshot snapshot);

  /// 立即补存当前观看记录进度。
  void _flushCurrentWatchHistoryProgress();

  /// 立即补存当前学习清单进度。
  void _flushCurrentLearningListProgress();

  /// 根据最新快照安排互动剧情提示。
  void _scheduleInteractiveChoicePrompt(PlaybackSnapshot snapshot);

  /// 确保当前时间附近的弹幕片段已经开始加载。
  void _ensureDanmakuSegmentsForPosition(Duration position);

  /// 停止控制层自动隐藏计时器。
  void _stopControlsAutoHideTimer();

  /// 重新启动控制层自动隐藏计时器。
  void _restartControlsAutoHideTimer();

  /// 把真实播放状态同步给专注计时器，并显式标记是否刚进入完播状态。
  void _syncFocusPlaybackState(
    PlaybackSnapshot snapshot, {
    bool playbackJustEnded = false,
  });

  /// 在播放就绪后按需询问是否关联当前专注任务。
  Future<void> _maybePromptFocusAssociation();

  /// 请求播放器跳转到指定真实位置。
  Future<void> _seekNativeTo(Duration position);

  /// 使用页面统一的短消息提示初始化位置结果。
  void _showTransientSnackBar(String message);

  /// 把总秒数格式化为播放器使用的时间文字。
  String _formatSeconds(int totalSeconds);

  /// 保存初始跳转位置、监听播放状态流并启动当前视频会话。
  void _startPlayerPlaybackSession(Duration? initialPosition) {
    _pendingInitialPosition = initialPosition;
    _playbackSubscription = _playbackService.states.listen(
      _applyPlaybackSnapshot,
    );
    unawaited(_initializePlaybackSession());
  }

  /// 取消播放状态订阅和续播计时器，供页面销毁流程统一调用。
  void _disposePlayerPlaybackSession() {
    _isRetrying = false;
    _resumeNoticeTimer?.cancel();
    unawaited(_playbackSubscription?.cancel() ?? Future<void>.value());
  }

  /// 读取设备里保存的手势和默认清晰度；异常时返回当前安全默认配置。
  Future<PlaybackPreferences> _loadPlaybackPreferences() async {
    try {
      final PlaybackPreferences preferences = await _playbackPreferencesService
          .load();
      if (mounted) {
        setState(() => _playbackPreferences = preferences);
      }
      return preferences;
    } catch (_) {
      // 本地配置损坏不影响视频播放，默认配置已经是可用的安全回退。
      return _playbackPreferences;
    }
  }

  /// 读取当前网络类型；平台服务异常时按更保守的其他网络配置处理。
  Future<DeviceNetworkType> _loadNetworkTypeSafely() async {
    if (widget.playbackService != null && widget.deviceStatusService == null) {
      return DeviceNetworkType.other;
    }
    try {
      return await _deviceStatusService.loadNetworkType();
    } catch (_) {
      return DeviceNetworkType.other;
    }
  }

  /// 根据 Wi-Fi、有线或移动网络返回本次打开视频应请求的默认清晰度。
  int _preferredQualityForNetwork(
    PlaybackPreferences preferences,
    DeviceNetworkType networkType,
  ) {
    return switch (networkType) {
      DeviceNetworkType.wifi ||
      DeviceNetworkType.ethernet => preferences.wifiDefaultQuality.id,
      DeviceNetworkType.mobile ||
      DeviceNetworkType.offline ||
      DeviceNetworkType.other => preferences.mobileDefaultQuality.id,
    };
  }

  /// 初始化当前平台播放表面，并按恢复分 P、网络偏好和初始位置打开视频。
  Future<void> _initializePlaybackSession() async {
    try {
      final PlaybackPreferences preferences = await _loadPlaybackPreferences();
      final DeviceNetworkType networkType = await _loadNetworkTypeSafely();
      final int preferredQuality = _preferredQualityForNetwork(
        preferences,
        networkType,
      );
      final SavedPlaybackState? savedState = await _playbackService
          .loadSavedPlaybackState(_activeVideo.bvid);
      final SystemPlaybackLevels levels = await _playbackService
          .getSystemPlaybackLevels();
      final VideoPart restoredPart = _findInitialPart(savedState);
      final bool restoredPartMatched =
          widget.initialPartCid == null &&
          savedState != null &&
          restoredPart.cid == savedState.cid;
      if (!mounted) {
        return;
      }
      _applyInitialPlaybackConfiguration(
        part: restoredPart,
        levels: levels,
        networkType: networkType,
        preferredQuality: preferredQuality,
      );
      unawaited(_loadCurrentLearningListEntry());
      unawaited(_loadPlayerEnhancements());
      if (restoredPartMatched && _activeVideo.parts.length > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showPartRestoreSnackBar(restoredPart.pageNumber);
        });
      }
      final int? textureId = await _playbackService.initialize();
      if (!mounted) {
        return;
      }
      setState(() => _textureId = textureId);
      await _playbackService.openVideo(
        _activeVideo,
        part: _currentPart,
        quality: preferredQuality,
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法启动播放器：${error.message ?? error.code}');
    } on ArgumentError catch (error) {
      _showPlaybackError(error.message?.toString() ?? 'BV 号无效。');
    } catch (error) {
      _showPlaybackError('无法初始化播放器：$error');
    }
  }

  /// 在视频分 P 列表中查找本机保存的 cid，失效时回退到接口默认分 P。
  VideoPart _findSavedPart(SavedPlaybackState? savedState) {
    if (savedState != null) {
      for (final VideoPart part in _activeVideo.parts) {
        if (part.cid == savedState.cid) {
          return part;
        }
      }
    }
    return _activeVideo.initialPart;
  }

  /// 优先定位外部入口指定的分 P，没有指定或编号失效时再恢复本机观看分 P。
  VideoPart _findInitialPart(SavedPlaybackState? savedState) {
    final int? requestedCid = widget.initialPartCid;
    if (requestedCid != null) {
      for (final VideoPart part in _activeVideo.parts) {
        if (part.cid == requestedCid) {
          return part;
        }
      }
    }
    return _findSavedPart(savedState);
  }

  /// 使用系统风格提示告知用户已经定位到上次观看的分 P。
  void _showPartRestoreSnackBar(int pageNumber) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已跳转到上次分P：P$pageNumber'),
          duration: _sessionTransientHintDuration,
        ),
      );
  }

  /// 把播放后端推送的快照写入页面，并协调恢复、记录、弹幕、专注和完播状态。
  void _applyPlaybackSnapshot(PlaybackSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    final PlaybackSnapshot previousSnapshot = _playbackSnapshot;
    final bool shouldRestartDanmakuPresentation =
        _shouldRestartDanmakuPresentation(previousSnapshot, snapshot);
    final bool justEnded =
        previousSnapshot.phase != PlaybackPhase.ended &&
        snapshot.phase == PlaybackPhase.ended;
    final bool leftEnded =
        previousSnapshot.phase == PlaybackPhase.ended &&
        snapshot.phase != PlaybackPhase.ended;
    final bool isNewPlaybackError =
        snapshot.phase == PlaybackPhase.error &&
        (previousSnapshot.phase != PlaybackPhase.error ||
            previousSnapshot.message != snapshot.message);
    final Duration? requestedInitialPosition = _pendingInitialPosition;
    final bool shouldSeekToInitialPosition =
        requestedInitialPosition != null &&
        snapshot.phase == PlaybackPhase.ready;
    final bool shouldShowResumeNotice =
        requestedInitialPosition == null &&
        snapshot.phase == PlaybackPhase.ready &&
        snapshot.restoredPosition > Duration.zero &&
        _shownRestoredCid != _currentPart.cid;
    if (shouldSeekToInitialPosition) {
      _pendingInitialPosition = null;
    }
    final int? pendingQuality = _pendingQualitySelection;
    final bool sawQualityLoading =
        pendingQuality != null &&
        (_qualitySelectionSawLoading ||
            snapshot.phase == PlaybackPhase.loading);
    final bool qualitySelectionFinished =
        pendingQuality != null &&
        sawQualityLoading &&
        (snapshot.phase == PlaybackPhase.ready ||
            snapshot.phase == PlaybackPhase.error);
    final bool qualitySelectionFailed =
        qualitySelectionFinished &&
        (snapshot.phase == PlaybackPhase.error ||
            snapshot.currentQuality != pendingQuality);
    final bool shouldResolveDefaultQuality =
        _defaultQualityPending &&
        snapshot.phase == PlaybackPhase.ready &&
        snapshot.availableQualities.isNotEmpty;
    final int? defaultFallbackQuality = shouldResolveDefaultQuality
        ? selectPlaybackQualityAtOrBelow(
            preferredQuality: _preferredOpeningQuality,
            actualQuality: snapshot.currentQuality,
            availableQualities: snapshot.availableQualities.map(
              (PlaybackQuality quality) => quality.id,
            ),
          )
        : null;
    if (shouldResolveDefaultQuality) {
      _defaultQualityPending = false;
    }
    final bool leftPictureInPicture =
        _playbackSnapshot.isInPictureInPicture &&
        !snapshot.isInPictureInPicture;
    final LearningListEntry? currentLearningEntry = _learningListEntry;
    final bool completedLearningEntry =
        justEnded &&
        currentLearningEntry != null &&
        currentLearningEntry.matchesPart(_activeVideo.bvid, _currentPart.cid) &&
        currentLearningEntry.status != LearningListStatus.completed;
    final bool interactiveCompletion =
        justEnded && _playerEnhancementController.handlesPlaybackCompletion;
    bool shouldRestartLoop = false;
    bool shouldPauseAfterPlayCount = false;
    if (justEnded && !interactiveCompletion) {
      _completedPlayCount += 1;
      final int? targetPlayCount = _pauseAfterPlayCount;
      shouldPauseAfterPlayCount =
          targetPlayCount != null && _completedPlayCount >= targetPlayCount;
      shouldRestartLoop =
          !shouldPauseAfterPlayCount &&
          (_playbackLoopEnabled || targetPlayCount != null);
      if (shouldPauseAfterPlayCount) {
        _pauseAfterPlayCount = null;
        _playbackLoopEnabled = false;
      }
    }
    setState(() {
      _playbackSnapshot = snapshot;
      _isRetrying = false;
      if (!_isDraggingProgress &&
          !_horizontalScrubbing &&
          snapshot.duration > Duration.zero) {
        _progress =
            (snapshot.position.inMilliseconds /
                    snapshot.duration.inMilliseconds)
                .clamp(0, 1)
                .toDouble();
      }
      _playbackSpeed = snapshot.speed;
      _currentQuality = snapshot.currentQuality;
      if (snapshot.availableQualities.isNotEmpty) {
        _availableQualities = snapshot.availableQualities;
      }
      if (qualitySelectionFinished) {
        _pendingQualitySelection = null;
        _qualitySelectionSawLoading = false;
      } else if (pendingQuality != null) {
        _qualitySelectionSawLoading = sawQualityLoading;
      }
      if (snapshot.isInPictureInPicture) {
        _showControls = false;
      } else if (leftPictureInPicture) {
        _showControls = true;
      }
      if (leftEnded) {
        _interactivePromptVisible = false;
        _completionPromptVisible = false;
        _completionLearningFinished = false;
      }
      if (justEnded) {
        // 互动视频优先显示剧情选择；普通视频仅在当前分 P 已加入学习清单时显示完成操作。
        _interactivePromptVisible = interactiveCompletion;
        _completionPromptVisible =
            !_interactivePromptVisible &&
            !shouldRestartLoop &&
            completedLearningEntry;
        _completionLearningFinished = false;
        _showControls = true;
      }
    });
    if (shouldRestartDanmakuPresentation) {
      _restartDanmakuPresentationFrom(snapshot.position);
    }
    _syncDanmakuAnimation(snapshot);
    if (isNewPlaybackError) {
      _recordPlaybackDiagnostic(snapshot, previousSnapshot.phase);
    }
    if (qualitySelectionFailed) {
      _showMembershipQualityNotice();
    }
    if (defaultFallbackQuality != null &&
        defaultFallbackQuality != snapshot.currentQuality) {
      unawaited(_changeQuality(defaultFallbackQuality));
    }
    if (shouldShowResumeNotice) {
      _shownRestoredCid = _currentPart.cid;
      _showResumeNotice(snapshot.restoredPosition);
    }
    if (shouldSeekToInitialPosition) {
      unawaited(_seekToRequestedInitialPosition(requestedInitialPosition));
    } else {
      _recordWatchHistoryWhenReady(snapshot);
      _recordWatchHistoryProgressWhenNeeded(snapshot);
      _recordLearningListProgressWhenNeeded(snapshot);
    }
    if (justEnded) {
      _flushCurrentWatchHistoryProgress();
      _flushCurrentLearningListProgress();
      if (shouldPauseAfterPlayCount) {
        unawaited(_playbackService.pause());
        _showTransientSnackBar('已播放 $_completedPlayCount 次，视频已暂停');
      } else if (shouldRestartLoop) {
        unawaited(_restartPlaybackLoop());
      }
    }
    _scheduleInteractiveChoicePrompt(snapshot);
    if (_danmakuEnabled && snapshot.phase == PlaybackPhase.ready) {
      _ensureDanmakuSegmentsForPosition(snapshot.position);
    }
    if (!snapshot.isPlaying || snapshot.isInPictureInPicture) {
      _stopControlsAutoHideTimer();
    } else if (_showControls && !_controlsAutoHideScheduled) {
      _restartControlsAutoHideTimer();
    }
    _syncFocusPlaybackState(snapshot, playbackJustEnded: justEnded);
    if (snapshot.phase == PlaybackPhase.ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_maybePromptFocusAssociation());
      });
    }
  }

  /// 从零开始下一轮播放，并用保护标记避免同一完播状态重复执行。
  Future<void> _restartPlaybackLoop() async {
    if (_loopRestartInFlight || !mounted) {
      return;
    }
    _loopRestartInFlight = true;
    try {
      await _seekNativeTo(Duration.zero);
      await _playbackService.play();
    } on Object {
      _playbackLoopEnabled = false;
      _showTransientSnackBar('循环播放启动失败，已自动关闭');
    } finally {
      _loopRestartInFlight = false;
    }
  }

  /// 识别原生恢复、快进或回退造成的非连续位置，普通心跳和倍速播放不会误触发重置。
  bool _shouldRestartDanmakuPresentation(
    PlaybackSnapshot previous,
    PlaybackSnapshot current,
  ) {
    if (!_danmakuEnabled || current.phase != PlaybackPhase.ready) {
      return false;
    }
    final Duration delta = current.position - previous.position;
    if (delta < const Duration(milliseconds: -250)) {
      return true;
    }
    if (previous.phase != PlaybackPhase.ready &&
        delta > const Duration(seconds: 1)) {
      return true;
    }
    return delta > const Duration(seconds: 3);
  }

  /// 把新的播放失败写入脱敏问题诊断，不记录视频标识、地址、Cookie 或响应正文。
  void _recordPlaybackDiagnostic(
    PlaybackSnapshot snapshot,
    PlaybackPhase previousPhase,
  ) {
    final String playerState = switch (previousPhase) {
      PlaybackPhase.loading => 'preparing',
      PlaybackPhase.ready => 'playing',
      PlaybackPhase.ended => 'ended',
      PlaybackPhase.error => 'error',
      PlaybackPhase.idle => 'idle',
    };
    unawaited(
      _problemDiagnosticsService.recordPlaybackFailure(
        message: snapshot.message ?? '无法获取视频播放地址。',
        playerState: playerState,
        multiPart: _activeVideo.parts.length > 1,
      ),
    );
  }

  /// 在播放器首次就绪后跳转到外部入口要求的时间点，并显示准确来源文案。
  Future<void> _seekToRequestedInitialPosition(Duration position) async {
    final String sourceLabel = switch (widget.initialPositionSource) {
      PlayerInitialPositionSource.note => '笔记位置',
      PlayerInitialPositionSource.focus => '专注位置',
      PlayerInitialPositionSource.learning => '学习清单位置',
      PlayerInitialPositionSource.externalLink => '外部链接位置',
    };
    try {
      await _seekNativeTo(position);
      if (mounted) {
        _showTransientSnackBar(
          '已跳转到$sourceLabel：${formatVideoNotePosition(position)}',
        );
      }
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('视频已打开，但暂时无法跳转到$sourceLabel。');
      }
    }
  }

  /// 显示三秒续播提示，控制栏出现时提示会在布局中自动上移。
  void _showResumeNotice(Duration position) {
    _resumeNoticeTimer?.cancel();
    setState(() {
      _resumeNotice = '已跳转到上次进度：${_formatSeconds(position.inSeconds)}';
    });
    _resumeNoticeTimer = Timer(_sessionTransientHintDuration, () {
      if (mounted) {
        setState(() => _resumeNotice = null);
      }
    });
  }

  /// 显示可理解的播放错误并停止控制层自动收起计时器。
  void _showPlaybackError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _playbackSnapshot = _playbackSnapshot.copyWith(
        phase: PlaybackPhase.error,
        isPlaying: false,
        message: message,
      );
      _showControls = true;
    });
    _stopControlsAutoHideTimer();
  }

  /// 再次请求当前视频、分 P 和清晰度，等待后端快照决定是否替换原错误提示。
  Future<void> _retryPlayback() async {
    if (_isRetrying || !mounted) {
      return;
    }
    setState(() => _isRetrying = true);
    try {
      await _playbackService.openVideo(
        _activeVideo,
        part: _currentPart,
        quality: _currentQuality,
      );
    } catch (_) {
      if (mounted) {
        // 重试调用本身失败时保留旧错误，方便用户继续判断并再次尝试。
        setState(() => _isRetrying = false);
      }
    }
  }
}
