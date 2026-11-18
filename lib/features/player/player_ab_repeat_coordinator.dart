part of 'player_page.dart';

/// The native playing bit may bounce after the seek Future has resolved.
class _AbRepeatFeedbackWindow {
  _AbRepeatFeedbackWindow(this.epoch, this.range);
  final int epoch;
  final AbRepeatRange range;
  bool? manualTarget;
  bool manuallyPaused = false;
}

/// Coordinates one chapter-local loop without reopening media or focus sessions.
mixin _PlayerAbRepeatCoordinator
    on
        State<PlayerPage>,
        _PlayerPlaybackSession,
        _PlayerFocusCoordinator,
        _PlayerNotesWorkspace {
  AbRepeatRange? _abRepeatRange;
  bool _abRepeatEditorVisible = false;
  int _abRepeatEditorGeneration = 0;
  Offset? _abRepeatEditorOffset;
  String? _abRepeatDraftA;
  String? _abRepeatDraftB;
  Timer? _abRepeatTimer;
  Timer? _abRepeatSeekAckTimer;
  Future<void>? _abRepeatSeek;
  _AbRepeatFeedbackWindow? _abRepeatFeedbackWindow;
  final Set<Future<void>> _temporaryCaptureSeeks = {};

  /// Track commands, not the whole capture: internal chapter switches may drain safely.
  Future<void> _runTemporaryCaptureSeek(Future<void> Function() seek) async {
    final completion = Completer<void>();
    _temporaryCaptureSeeks.add(completion.future);
    try {
      await seek();
    } finally {
      _temporaryCaptureSeeks.remove(completion.future);
      completion.complete();
    }
  }

  int _abRepeatEpoch = 0;
  bool _abRepeatSourceChanging = false;
  bool _abRepeatUserPaused = false;
  bool _abRepeatAwaitingPosition = false;
  bool _abRepeatEndExpected = false;
  bool _abRepeatSeekReachedEnd = false;
  AppLifecycleState _abRepeatLifecycle = AppLifecycleState.resumed;
  int _abRepeatCaptureDepth = 0;
  Duration? _abRepeatCaptureRestoreTarget;
  int? _abRepeatCaptureRestoreSource;
  int _abRepeatPauseRevision = 0;
  int _abRepeatCapturePauseRevision = 0;
  int _abRepeatCaptureSerial = 0;

  @override
  bool get _canResumeAfterNoteCapture =>
      _abRepeatCanRunInLifecycle &&
      _abRepeatCapturePauseRevision == _abRepeatPauseRevision;

  bool get _abRepeatCanRunInLifecycle =>
      _abRepeatLifecycle == AppLifecycleState.resumed ||
      _abRepeatLifecycle == AppLifecycleState.inactive ||
      _playbackSnapshot.audioOnly ||
      _playbackSnapshot.isInPictureInPicture;

  void _handleAbRepeatLifecycle(AppLifecycleState state) {
    _abRepeatLifecycle = state;
    if (!_abRepeatCanRunInLifecycle) {
      _abRepeatEpoch++;
      _abRepeatPlaybackIntent(false);
    } else if (state == AppLifecycleState.resumed && mounted) {
      _observeAbRepeatSnapshot(
        _playbackSnapshot,
        _playbackSnapshot,
        positionEvent: false,
      );
    }
  }

  @override
  Future<int> _beginAbRepeatCapture() async {
    final serial = ++_abRepeatCaptureSerial;
    _abRepeatCapturePauseRevision = _abRepeatPauseRevision;
    _abRepeatCaptureDepth++;
    _abRepeatEpoch++;
    _abRepeatTimer?.cancel();
    _abRepeatCaptureRestoreTarget = null;
    await _drainAbRepeatSeek();
    return serial;
  }

  @override
  bool _isCurrentAbRepeatCapture(int serial) =>
      serial == _abRepeatCaptureSerial;

  @override
  void _prepareAbRepeatCaptureRestore(Duration position) {
    if (_abRepeatRange == null ||
        !_abRepeatRange!.matches(_activeVideo.bvid, _currentPart.cid)) {
      return;
    }
    _abRepeatCaptureRestoreTarget = position;
    _abRepeatCaptureRestoreSource = _sourceGeneration;
  }

  @override
  void _endAbRepeatCapture() {
    _abRepeatCaptureDepth--;
    if (mounted) {
      _observeAbRepeatSnapshot(
        _playbackSnapshot,
        _playbackSnapshot,
        positionEvent: false,
      );
    }
  }

  @override
  bool get _abRepeatActive => _abRepeatRange != null;
  @override
  Future<void> _drainAbRepeatSeek() async {
    final pending = <Future<void>>[?_abRepeatSeek, ..._temporaryCaptureSeeks];
    await Future.wait(pending);
  }

  @override
  Duration get _displayDuration;
  Timer? get _interactivePromptTimer;
  @override
  void _restartDanmakuPresentationFrom(Duration position);
  @override
  void _showPlayerControls();

  void _stopWaitingForAbRepeatPosition() {
    _abRepeatAwaitingPosition = false;
    _abRepeatSeekAckTimer?.cancel();
    _abRepeatSeekAckTimer = null;
  }

  void _clearAbRepeat({bool notify = false}) {
    _abRepeatEpoch++;
    _abRepeatFeedbackWindow = null;
    _abRepeatTimer?.cancel();
    _abRepeatTimer = null;
    _stopWaitingForAbRepeatPosition();
    _abRepeatEndExpected = false;
    _abRepeatSeekReachedEnd = false;
    _abRepeatCaptureRestoreTarget = null;
    _abRepeatCaptureRestoreSource = null;
    if (_abRepeatRange != null && mounted) {
      setState(() => _abRepeatRange = null);
    }
    if (notify && mounted) _showTransientSnackBar('已清除 A–B 区间，恢复原播放方式');
  }

  /// 导航时清理草稿与编辑会话，旧面板回调不再影响新视频。
  @override
  void _clearAbRepeatForNavigation() {
    _abRepeatEditorGeneration++;
    _abRepeatEditorOffset = null;
    _abRepeatDraftA = null;
    _abRepeatDraftB = null;
    _abRepeatEditorVisible = false;
    _clearAbRepeat();
  }

  /// External routes must cancel capture work that can outlive an issued seek.
  @override
  void _cancelNoteCaptureForExternalNavigation() {
    _abRepeatCaptureSerial++;
    _abRepeatCaptureRestoreTarget = null;
    _abRepeatCaptureRestoreSource = null;
    _abRepeatPlaybackIntent(false);
  }

  @override
  Future<void> _suspendAbRepeatForSource() async {
    _abRepeatSourceChanging = true;
    _stopWaitingForAbRepeatPosition();
    _abRepeatCaptureRestoreTarget = null;
    _abRepeatEpoch++;
    _abRepeatTimer?.cancel();
    await _drainAbRepeatSeek();
  }

  @override
  void _resumeAbRepeatAfterSource() {
    _abRepeatSourceChanging = false;
    if (mounted) {
      _observeAbRepeatSnapshot(
        _playbackSnapshot,
        _playbackSnapshot,
        positionEvent: false,
      );
    }
  }

  @override
  Future<void> _prepareAbRepeatManualSeek(Duration target) async {
    _abRepeatCaptureSerial++;
    _abRepeatCaptureRestoreTarget = null;
    _abRepeatCaptureRestoreSource = null;
    _stopWaitingForAbRepeatPosition();
    _abRepeatEpoch++;
    _abRepeatTimer?.cancel();
    final range = _abRepeatRange;
    if (range != null && !range.contains(target)) _clearAbRepeat(notify: true);
    await _drainAbRepeatSeek();
  }

  /// Explicit app playback commands take priority over a still-returning seek.
  void _markAbRepeatManualFeedback(bool shouldPlay) {
    final range = _abRepeatRange;
    if (range == null || !_validAbRepeat(_abRepeatEpoch, range)) return;
    if (_abRepeatEndExpected) _ensureAbRepeatFeedbackWindow(range);
    final window = _abRepeatFeedbackWindow;
    if (window != null && _validAbRepeat(window.epoch, window.range)) {
      window.manualTarget = shouldPlay;
    }
  }

  @override
  bool _shouldAnimatePlaybackAction(
    PlaybackSnapshot previous,
    PlaybackSnapshot snapshot,
  ) {
    final ready = snapshot.phase == PlaybackPhase.ready &&
        !snapshot.isRestoringPosition;
    final ordinary = ready &&
        previous.phase == PlaybackPhase.ready &&
        previous.isPlaying != snapshot.isPlaying;
    final window = _abRepeatFeedbackWindow;
    if (window == null || !_validAbRepeat(window.epoch, window.range)) {
      _abRepeatFeedbackWindow = null;
      // Native EOF can first announce ready/stopped, then ended. The latter
      // will start the actual seek, but the former isn't a pause command.
      return ordinary && !(_abRepeatEndExpected && !snapshot.isPlaying);
    }
    if (snapshot.phase == PlaybackPhase.error || snapshot.isRestoringPosition) {
      _abRepeatFeedbackWindow = null;
      return false;
    }
    final manual = window.manualTarget;
    if (manual != null) {
      if (!ready ||
          snapshot.isPlaying != manual ||
          (snapshot.playRequested != null && snapshot.playRequested != manual)) {
        return false;
      }
      window.manualTarget = null;
      window.manuallyPaused = !manual;
      if (manual) _abRepeatFeedbackWindow = null;
      return true;
    }
    if (snapshot.playRequested == false && !window.manuallyPaused) {
      // An external playback command can change native intent without passing
      // through a PlayerPage button. Keep normal feedback for that real pause.
      _abRepeatFeedbackWindow = null;
      return ordinary;
    }
    if (ready &&
        snapshot.isPlaying &&
        !_abRepeatAwaitingPosition &&
        _abRepeatSeek == null &&
        window.range.contains(snapshot.position)) {
      _abRepeatFeedbackWindow = null;
    }
    return false;
  }

  void _abRepeatPlaybackIntent(bool playing, {bool backend = false}) {
    if (!playing && !backend) _abRepeatPauseRevision++;
    _abRepeatUserPaused = !playing;
    if (!playing) {
      _abRepeatEndExpected = false;
      _abRepeatTimer?.cancel();
      _abRepeatSeekAckTimer?.cancel();
      _abRepeatSeekAckTimer = null;
    }
  }

  bool _validAbRepeat(int epoch, AbRepeatRange range) =>
      mounted &&
      !_externalNavigationSuspended &&
      !_abRepeatSourceChanging &&
      _abRepeatCanRunInLifecycle &&
      _abRepeatCaptureDepth == 0 &&
      _abRepeatCaptureRestoreTarget == null &&
      epoch == _abRepeatEpoch &&
      identical(range, _abRepeatRange) &&
      range.matches(_activeVideo.bvid, _currentPart.cid);

  /// Consume the ended edge before learning/focus completion and full-part loops.
  @override
  bool _observeAbRepeatSnapshot(
    PlaybackSnapshot previous,
    PlaybackSnapshot snapshot, {
    required bool positionEvent,
  }) {
    _abRepeatTimer?.cancel();
    _abRepeatTimer = null;
    if (previous.sleepTimerRemaining > Duration.zero &&
        snapshot.sleepTimerRemaining == Duration.zero &&
        !snapshot.isPlaying) {
      _abRepeatPlaybackIntent(false);
    }
    final range = _abRepeatRange;
    if (range == null) return false;
    if (!range.matches(_activeVideo.bvid, _currentPart.cid) ||
        (snapshot.duration > Duration.zero &&
            range.validate(snapshot.duration) != null)) {
      _clearAbRepeat();
      _showTransientSnackBar('当前媒体时长或分 P 已变化，已清除 A–B 区间');
      return false;
    }
    final ended = snapshot.phase == PlaybackPhase.ended;
    final restoreTarget = _abRepeatCaptureRestoreTarget;
    if (restoreTarget != null) {
      if (_abRepeatCaptureRestoreSource != _sourceGeneration ||
          (positionEvent &&
              snapshot.phase == PlaybackPhase.ready &&
              (snapshot.position - restoreTarget).inMilliseconds.abs() <=
                  350)) {
        _abRepeatCaptureRestoreTarget = null;
        _abRepeatCaptureRestoreSource = null;
      }
    }
    if (snapshot.playRequested == false) {
      _abRepeatPlaybackIntent(false, backend: true);
    }
    if (snapshot.phase == PlaybackPhase.ready &&
        !snapshot.isPlaying &&
        previous.isPlaying &&
        snapshot.duration > Duration.zero &&
        snapshot.position >= snapshot.duration &&
        !_abRepeatUserPaused) {
      _abRepeatEndExpected = true;
    }
    if (ended &&
        _abRepeatSeek != null &&
        !_abRepeatUserPaused &&
        (previous.isPlaying || _abRepeatEndExpected)) {
      _abRepeatSeekReachedEnd = true;
    }
    if (positionEvent &&
        _abRepeatAwaitingPosition &&
        snapshot.phase == PlaybackPhase.ready &&
        !snapshot.isRestoringPosition &&
        range.contains(snapshot.position) &&
        // At high speeds the first fresh sample can already be well past A,
        // and even ahead of the last sample before a timer-triggered seek.
        (snapshot.position == range.a ||
            snapshot.position != previous.position)) {
      _stopWaitingForAbRepeatPosition();
    }
    if (_externalNavigationSuspended ||
        _abRepeatSourceChanging ||
        !_abRepeatCanRunInLifecycle ||
        _abRepeatCaptureDepth > 0 ||
        _abRepeatCaptureRestoreTarget != null ||
        _abRepeatSeek != null) {
      return ended;
    }
    if (_abRepeatAwaitingPosition) {
      if (!_abRepeatUserPaused &&
          (ended ||
              (snapshot.phase == PlaybackPhase.ready && snapshot.isPlaying))) {
        final epoch = _abRepeatEpoch;
        // A backend may finish a seek without delivering a usable position.
        // Do not hammer it with retries or leave an indefinitely stale loop.
        _abRepeatSeekAckTimer ??= Timer(const Duration(seconds: 5), () {
          _abRepeatSeekAckTimer = null;
          final current = _playbackSnapshot;
          if (_validAbRepeat(epoch, range) &&
              _abRepeatAwaitingPosition &&
              !_abRepeatUserPaused &&
              (current.phase == PlaybackPhase.ended ||
                  (current.phase == PlaybackPhase.ready &&
                      current.isPlaying))) {
            _clearAbRepeat();
            _showTransientSnackBar('未能确认区间回跳，已关闭 A–B 循环');
          }
        });
      }
      return ended;
    }
    if (snapshot.phase != PlaybackPhase.ready && !ended) return false;
    if (snapshot.isRestoringPosition) return ended;
    if (ended) {
      if (!_abRepeatUserPaused &&
          (previous.isPlaying || _abRepeatEndExpected)) {
        _jumpToAbRepeatA(range, resumeEnded: true);
      }
      _abRepeatEndExpected = false;
      return true;
    }
    if (!snapshot.isPlaying || snapshot.playRequested == false) return false;
    _abRepeatUserPaused = false;
    if (!range.contains(snapshot.position)) {
      _jumpToAbRepeatA(range);
      return false;
    }
    final speed = snapshot.speed.isFinite && snapshot.speed > 0
        ? snapshot.speed
        : 1.0;
    final delay = Duration(
      microseconds: ((range.b - snapshot.position).inMicroseconds / speed)
          .ceil(),
    );
    final epoch = _abRepeatEpoch;
    _abRepeatTimer = Timer(delay, () {
      if (_validAbRepeat(epoch, range) &&
          _playbackSnapshot.isPlaying &&
          _playbackSnapshot.phase == PlaybackPhase.ready &&
          !_abRepeatUserPaused) {
        _jumpToAbRepeatA(range);
      }
    });
    return false;
  }

  void _ensureAbRepeatFeedbackWindow(AbRepeatRange range) {
    final previous = _abRepeatFeedbackWindow;
    if (previous == null ||
        previous.epoch != _abRepeatEpoch ||
        !identical(previous.range, range)) {
      _abRepeatFeedbackWindow = _AbRepeatFeedbackWindow(_abRepeatEpoch, range);
    }
  }

  /// Register before issuing seek: synchronous backend snapshots cannot duplicate it.
  void _jumpToAbRepeatA(AbRepeatRange range, {bool resumeEnded = false}) {
    final epoch = _abRepeatEpoch;
    if (_abRepeatSeek != null || !_validAbRepeat(epoch, range)) return;
    _abRepeatTimer?.cancel();
    final completion = Completer<void>();
    _abRepeatSeek = completion.future;
    _abRepeatAwaitingPosition = true;
    _abRepeatSeekReachedEnd = resumeEnded;
    if (_playbackSnapshot.isPlaying || resumeEnded) {
      _ensureAbRepeatFeedbackWindow(range);
    }
    unawaited(() async {
      try {
        _beginFocusSeekTransition();
        await _playbackService.seekTo(range.a);
        if (!_validAbRepeat(epoch, range)) return;
        _restartDanmakuPresentationFrom(range.a);
        if (_abRepeatSeekReachedEnd && !_abRepeatUserPaused) {
          await _playbackService.play();
        }
      } catch (_) {
        if (_validAbRepeat(epoch, range)) {
          _clearAbRepeat();
          _showTransientSnackBar('区间跳转失败，已清除 A–B 循环');
        }
      } finally {
        _abRepeatSeek = null;
        completion.complete();
        if (_validAbRepeat(epoch, range)) {
          _observeAbRepeatSnapshot(
            _playbackSnapshot,
            _playbackSnapshot,
            positionEvent: false,
          );
        }
      }
    }());
  }

  /// 打开非模态标记条，只有第一次打开才用当前播放位置初始化 A。
  Future<void> _showAbRepeatSheet() async {
    _showPlayerControls();
    if (_displayDuration <= Duration.zero) {
      _showTransientSnackBar('媒体时长尚未就绪，请稍后重试。');
      return;
    }
    setState(() {
      _abRepeatEditorGeneration++;
      _abRepeatDraftA ??= formatAbRepeatTime(
        _abRepeatRange?.a ?? _playbackSnapshot.position,
      );
      _abRepeatDraftB ??= _abRepeatRange == null
          ? ''
          : formatAbRepeatTime(_abRepeatRange!.b);
      _abRepeatEditorVisible = true;
    });
  }

  /// 收起编辑器而不清除当前分 P 的标记或已启用的区间。
  void _closeAbRepeatEditor() {
    if (!_abRepeatEditorVisible) return;
    setState(() {
      _abRepeatEditorVisible = false;
      _abRepeatEditorGeneration++;
    });
    _restartControlsAutoHideTimer();
  }

  /// 标记条不创建路由或遮罩，关闭后草稿继续属于当前视频。
  Widget _buildAbRepeatEditor({bool floating = false}) {
    final editor = _abRepeatEditorGeneration;
    // 同一视频重新打开编辑器也属于新会话，旧闭包不得覆盖新标记。
    bool isCurrent() =>
        mounted &&
        _abRepeatEditorVisible &&
        editor == _abRepeatEditorGeneration;
    final sheet = PlayerAbRepeatSheet(
      key: ValueKey('ab-editor-${_activeVideo.bvid}-${_currentPart.cid}'),
      inline: true,
      bvid: _activeVideo.bvid,
      cid: _currentPart.cid,
      draftA: _abRepeatDraftA,
      draftB: _abRepeatDraftB,
      duration: _displayDuration,
      readPosition: () => _playbackSnapshot.position,
      initialRange: _abRepeatRange,
      resumeFullLoop: _playbackLoopEnabled,
      // 保存草稿不触发媒体跳转或每帧重建。
      onDraftChanged: (a, b) {
        if (!isCurrent()) return;
        _abRepeatDraftA = a;
        _abRepeatDraftB = b;
      },
      onClose: () {
        if (isCurrent()) _closeAbRepeatEditor();
      },
      onClear: () {
        if (!isCurrent()) return;
        _abRepeatDraftA = null;
        _abRepeatDraftB = null;
        _clearAbRepeat(notify: true);
      },
      onApply: (range) {
        if (!isCurrent() ||
            !range.matches(_activeVideo.bvid, _currentPart.cid)) {
          return;
        }
        if (range.validate(_displayDuration) != null) {
          _showTransientSnackBar('媒体时长已变化，请重新设置 A、B 点。');
          return;
        }
        unawaited(_applyAbRepeatRange(range));
      },
    );
    if (!floating) return sheet;
    return PlayerAbRepeatDock(
      offset: _abRepeatEditorOffset,
      onMove: (offset) {
        if (isCurrent() && _abRepeatEditorOffset != offset) {
          setState(() => _abRepeatEditorOffset = offset);
        }
      },
      child: sheet,
    );
  }

  /// 启用已验证区间并等待旧定位结束，避免迟到的跳转覆盖新标记。
  Future<void> _applyAbRepeatRange(AbRepeatRange range) async {
    final epoch = ++_abRepeatEpoch;
    _abRepeatTimer?.cancel();
    await _abRepeatSeek;
    if (!mounted ||
        epoch != _abRepeatEpoch ||
        !range.matches(_activeVideo.bvid, _currentPart.cid)) {
      return;
    }
    if (range.validate(_displayDuration) != null) {
      _showTransientSnackBar('媒体时长已变化，请重新设置 A、B 点。');
      return;
    }
    // A completed seek may still be waiting for a position event from the
    // previous interval. Its acknowledgement flags do not belong to this one.
    _stopWaitingForAbRepeatPosition();
    _abRepeatEndExpected = false;
    _abRepeatSeekReachedEnd = false;
    _interactivePromptTimer?.cancel();
    setState(() {
      _abRepeatRange = range;
      _interactivePromptVisible = false;
      _completionPromptVisible = false;
    });
    _abRepeatUserPaused = !_playbackSnapshot.isPlaying;
    if (!range.contains(_playbackSnapshot.position)) {
      _jumpToAbRepeatA(range);
    } else {
      _observeAbRepeatSnapshot(
        _playbackSnapshot,
        _playbackSnapshot,
        positionEvent: false,
      );
    }
    _showTransientSnackBar('已启用 A–B 区间循环');
  }

  Future<void> _disposeAbRepeat() {
    _abRepeatEpoch++;
    _abRepeatTimer?.cancel();
    _stopWaitingForAbRepeatPosition();
    _abRepeatRange = null;
    return _drainAbRepeatSeek();
  }
}
