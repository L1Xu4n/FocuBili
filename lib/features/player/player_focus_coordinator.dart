part of 'player_page.dart';

/// 封装播放器与专注任务之间的状态同步、关联确认、退出保护和最后画面保存。
mixin _PlayerFocusCoordinator on State<PlayerPage> {
  Timer? _focusSeekTransitionTimer;
  FocusTimerController? _boundFocusController;
  String? _observedFocusSessionId;
  FocusSessionStatus? _observedFocusStatus;
  String? _lastFocusPlaybackBvid;
  int? _lastFocusPlaybackPartCid;
  bool? _lastFocusPlaybackPlaying;
  bool _focusSeekTransitionActive = false;
  String? _dismissedAssociationCandidate;
  bool _associationPromptOpen = false;
  bool _leaveRequestInProgress = false;
  bool _allowRoutePop = false;

  /// 由播放器状态类提供当前平台的播放服务。
  PlaybackService get _playbackService;

  /// 由播放器状态类提供明确平台，首次专注引导据此区分 Windows 与 Android 文案。
  AppPlatform get _appPlatform;

  /// 由播放会话协调器提供最近一次真实播放快照。
  PlaybackSnapshot get _playbackSnapshot;

  /// 由播放器状态类提供当前正在展示的视频资料。
  VideoPreview get _activeVideo;

  /// 由播放器状态类提供当前正在播放的分 P。
  VideoPart get _currentPart;

  /// 说明播放器当前是否真的处于播放状态。
  bool get _playing;

  /// 提供播放器当前用于界面计算的总时长。
  Duration get _displayDuration;

  /// 请求播放器切换真实播放或暂停状态。
  Future<void> _setPlaybackActive(bool shouldPlay);

  /// 在播放器画面内显示专注操作结果。
  void _showPlayerNotice(String message);

  /// 显示播放器控制层。
  void _showPlayerControls();

  /// 停止控制层自动隐藏计时器。
  void _stopControlsAutoHideTimer();

  /// 重新启动控制层自动隐藏计时器。
  void _restartControlsAutoHideTimer();

  /// 取消专注监听和快进保护计时器，并把离开页面状态同步给控制器。
  void _disposePlayerFocusCoordinator() {
    final FocusTimerController? controller = _boundFocusController;
    controller?.removeListener(_handleFocusStateChanged);
    if (controller != null) {
      unawaited(
        controller.updatePlaybackState(
          bvid: _activeVideo.bvid,
          partCid: _currentPart.cid,
          isPlaying: false,
        ),
      );
    }
    _focusSeekTransitionTimer?.cancel();
  }

  /// 切换播放器正在监听的专注控制器，并保存当前活动记录编号。
  void _bindFocusController(FocusTimerController? controller) {
    if (identical(_boundFocusController, controller)) {
      return;
    }
    _boundFocusController?.removeListener(_handleFocusStateChanged);
    _boundFocusController = controller;
    _observedFocusSessionId = controller?.activeSession?.id;
    _observedFocusStatus = controller?.activeSession?.status;
    controller?.addListener(_handleFocusStateChanged);
    if (controller != null) {
      _syncFocusPlaybackState(_playbackSnapshot);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_maybePromptFocusAssociation());
      });
    }
  }

  /// 监听专注状态；自然完成或提前结束时自动暂停当前视频。
  void _handleFocusStateChanged() {
    final FocusTimerController? controller = _boundFocusController;
    if (controller == null) {
      return;
    }
    final FocusSession? active = controller.activeSession;
    if (active != null) {
      final bool isNewSession = _observedFocusSessionId != active.id;
      final bool visualStateChanged =
          isNewSession || _observedFocusStatus != active.status;
      _observedFocusSessionId = active.id;
      _observedFocusStatus = active.status;
      if (isNewSession) {
        // 新任务必须重新接收当前真实播放状态，不能被上一条任务留下的页面级去重键跳过。
        _resetFocusPlaybackIdentity();
        _syncFocusPlaybackState(_playbackSnapshot);
      }
      if (visualStateChanged && mounted) {
        setState(() {});
      }
      if (!active.hasVideoAssociation) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_maybePromptFocusAssociation());
        });
      }
      return;
    }
    final String? previousSessionId = _observedFocusSessionId;
    final FocusSession? finished = controller.lastFinishedSession;
    _observedFocusSessionId = null;
    _observedFocusStatus = null;
    if (previousSessionId == null || finished?.id != previousSessionId) {
      return;
    }
    unawaited(_handleFinishedFocus(finished!));
  }

  /// 保存刚结束任务的真实播放帧和进度，再暂停视频并显示结束提示。
  Future<void> _handleFinishedFocus(FocusSession finished) async {
    if (_playing) {
      await _setPlaybackActive(false);
    }
    if (finished.sourceBvid == _activeVideo.bvid &&
        finished.sourcePartCid == _currentPart.cid) {
      await _boundFocusController?.updateFinishedLastSeen(
        sessionId: finished.id,
        framePath: await _captureFocusFrame(),
        position: _playbackSnapshot.position,
      );
    }
    if (!mounted) {
      return;
    }
    _showPlayerNotice(
      finished.status == FocusSessionStatus.completed
          ? '专注完成，视频已暂停'
          : '专注已结束，视频已暂停',
    );
    setState(() {});
  }

  /// 只消费新的真实完播边沿，并在播放身份变化时同步专注控制器。
  void _syncFocusPlaybackState(
    PlaybackSnapshot snapshot, {
    bool playbackJustEnded = false,
  }) {
    final FocusTimerController? controller = _boundFocusController;
    if (controller == null) {
      return;
    }
    if (playbackJustEnded) {
      unawaited(
        controller.completeForPlaybackPart(
          bvid: _activeVideo.bvid,
          partCid: _currentPart.cid,
        ),
      );
    }
    final bool actuallyPlaying =
        snapshot.isPlaying && snapshot.phase == PlaybackPhase.ready;
    if (_focusSeekTransitionActive &&
        _lastFocusPlaybackPlaying == true &&
        !actuallyPlaying &&
        snapshot.phase != PlaybackPhase.ended &&
        snapshot.phase != PlaybackPhase.error) {
      return;
    }
    if (actuallyPlaying && _focusSeekTransitionActive) {
      _finishFocusSeekTransition(syncCurrentSnapshot: false);
    }
    if (_lastFocusPlaybackBvid == _activeVideo.bvid &&
        _lastFocusPlaybackPartCid == _currentPart.cid &&
        _lastFocusPlaybackPlaying == actuallyPlaying) {
      return;
    }
    _lastFocusPlaybackBvid = _activeVideo.bvid;
    _lastFocusPlaybackPartCid = _currentPart.cid;
    _lastFocusPlaybackPlaying = actuallyPlaying;
    unawaited(
      controller.updatePlaybackState(
        bvid: _activeVideo.bvid,
        partCid: _currentPart.cid,
        isPlaying: actuallyPlaying,
      ),
    );
  }

  /// 快进或快退开始时短暂忽略播放器的缓冲暂停，避免勿扰模式反复切换。
  void _beginFocusSeekTransition() {
    if (_lastFocusPlaybackPlaying != true) {
      return;
    }
    _focusSeekTransitionActive = true;
    _focusSeekTransitionTimer?.cancel();
    _focusSeekTransitionTimer = Timer(const Duration(milliseconds: 1500), () {
      _finishFocusSeekTransition();
    });
  }

  /// 结束快进保护窗口，并按需把期间最后一个真实播放状态同步给专注控制器。
  void _finishFocusSeekTransition({bool syncCurrentSnapshot = true}) {
    _focusSeekTransitionTimer?.cancel();
    _focusSeekTransitionTimer = null;
    if (!_focusSeekTransitionActive) {
      return;
    }
    _focusSeekTransitionActive = false;
    if (syncCurrentSnapshot && mounted) {
      _syncFocusPlaybackState(_playbackSnapshot);
    }
  }

  /// 为首页创建且尚未关联的任务询问是否绑定当前真实视频分 P。
  Future<void> _maybePromptFocusAssociation() async {
    final FocusTimerController? controller = _boundFocusController;
    final FocusSession? session = controller?.activeSession;
    final String candidate = '${_activeVideo.bvid}:${_currentPart.cid}';
    if (!mounted ||
        controller == null ||
        session == null ||
        !session.isActive ||
        session.hasVideoAssociation ||
        _playbackSnapshot.phase != PlaybackPhase.ready ||
        _associationPromptOpen ||
        _dismissedAssociationCandidate == candidate ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _associationPromptOpen = true;
    final bool? confirmed = await showFocusVideoAssociationSheet(
      context,
      goal: session.goal,
      videoTitle: _activeVideo.title,
      partPageNumber: _currentPart.pageNumber,
      partTitle: _currentPart.title,
    );
    _associationPromptOpen = false;
    if (!mounted || controller.activeSession?.id != session.id) {
      return;
    }
    if (confirmed == true) {
      final String? framePath = await _captureFocusFrame();
      await controller.associateVideo(
        bvid: _activeVideo.bvid,
        videoTitle: _activeVideo.title,
        partCid: _currentPart.cid,
        partPageNumber: _currentPart.pageNumber,
        partTitle: _currentPart.title,
        isPlaying: _playing,
        framePath: framePath,
        position: _playbackSnapshot.position,
      );
      _dismissedAssociationCandidate = null;
      if (mounted) {
        _showPlayerNotice(
          '已关联视频：${_activeVideo.title}（P${_currentPart.pageNumber} ${_currentPart.title}）',
        );
      }
      return;
    }
    _dismissedAssociationCandidate = candidate;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('我们将在新的视频提示你关联'),
          duration: Duration(seconds: 3),
        ),
      );
  }

  /// 尝试保存播放器当前画面，失败时仍允许关联和退出。
  Future<String?> _captureFocusFrame() async {
    try {
      return await _playbackService.captureCurrentFrame();
    } on Object {
      return null;
    }
  }

  /// 保存当前关联视频的最后画面和播放位置，供首页“上次看到”展示。
  Future<void> _saveFocusLastSeen() async {
    final FocusTimerController? controller = _boundFocusController;
    final FocusSession? session = controller?.activeSession;
    if (controller == null ||
        session == null ||
        session.sourceBvid != _activeVideo.bvid ||
        session.sourcePartCid != _currentPart.cid) {
      return;
    }
    await controller.updateLastSeen(
      framePath: await _captureFocusFrame(),
      position: _playbackSnapshot.position,
    );
  }

  /// 在离开当前分 P 前保存最后画面，并明确同步为不再播放。
  Future<void> _deactivateFocusPlaybackForCurrentPart() async {
    await _saveFocusLastSeen();
    await _boundFocusController?.updatePlaybackState(
      bvid: _activeVideo.bvid,
      partCid: _currentPart.cid,
      isPlaying: false,
    );
  }

  /// 清除上一段视频的专注播放去重键，让新分 P 首次快照一定会同步。
  void _resetFocusPlaybackIdentity() {
    _lastFocusPlaybackBvid = null;
    _lastFocusPlaybackPartCid = null;
    _lastFocusPlaybackPlaying = null;
  }

  /// 计算当前分 P 尚未播放的时长，并限制在专注模块允许的 1 到 180 分钟内。
  Duration _currentPartFocusDuration() {
    final int remainingMilliseconds =
        _currentPartPlaybackRemaining().inMilliseconds;
    return Duration(
      milliseconds: remainingMilliseconds.clamp(
        FocusTimerController.minimumDuration.inMilliseconds,
        FocusTimerController.maximumDuration.inMilliseconds,
      ),
    );
  }

  /// 使用播放器真实总时长和当前位置计算当前分 P 剩余时间，不套用一分钟下限。
  Duration _currentPartPlaybackRemaining() {
    final Duration duration = _playbackSnapshot.duration > Duration.zero
        ? _playbackSnapshot.duration
        : _displayDuration;
    final int remainingMilliseconds =
        duration.inMilliseconds - _playbackSnapshot.position.inMilliseconds;
    return Duration(
      milliseconds: remainingMilliseconds.clamp(0, duration.inMilliseconds),
    );
  }

  /// 打开播放器专注面板，提供当前分 P 计划及活动计时控制。
  Future<void> _openPlayerFocusSheet() async {
    final FocusTimerController? controller = _boundFocusController;
    if (controller == null) {
      _showPlayerNotice('专注控制器尚未准备好');
      return;
    }
    await showPlayerFocusDoNotDisturbGuideIfNeeded(
      context,
      appPlatform: _appPlatform,
    );
    if (!mounted) {
      return;
    }
    _showPlayerControls();
    _stopControlsAutoHideTimer();
    final String? framePath = await _captureFocusFrame();
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => FractionallySizedBox(
        heightFactor:
            MediaQuery.orientationOf(sheetContext) == Orientation.landscape
            ? 0.92
            : 0.78,
        child: PlayerFocusSheet(
          controller: controller,
          defaultGoal: '看完 ${_currentPart.title}',
          partRemainingDuration: _currentPartFocusDuration(),
          bvid: _activeVideo.bvid,
          videoTitle: _activeVideo.title,
          partCid: _currentPart.cid,
          partPageNumber: _currentPart.pageNumber,
          partTitle: _currentPart.title,
          videoIsPlaying: _playing,
          sourceFramePath: framePath,
          sourcePosition: _playbackSnapshot.position,
        ),
      ),
    );
    if (mounted) {
      _restartControlsAutoHideTimer();
    }
  }

  /// 离开关联视频前鼓励继续；坚持退出时保存画面、原因并保持任务可继续。
  Future<void> _requestLeavePlayer() async {
    if (_leaveRequestInProgress || !mounted) {
      return;
    }
    _leaveRequestInProgress = true;
    final FocusTimerController? controller = _boundFocusController;
    final FocusSession? session = controller?.activeSession;
    bool mayLeave = true;
    if (controller != null &&
        session != null &&
        session.isActive &&
        session.sourceBvid == _activeVideo.bvid &&
        session.sourcePartCid == _currentPart.cid) {
      mayLeave = await showFocusInterruptionFlow(
        context,
        controller: controller,
        kind: FocusInterruptionKind.playerExit,
      );
      if (mayLeave) {
        await _saveFocusLastSeen();
      }
    }
    _leaveRequestInProgress = false;
    if (!mounted || !mayLeave) {
      return;
    }
    setState(() => _allowRoutePop = true);
    Navigator.of(context).pop();
  }
}
