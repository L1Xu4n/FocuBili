part of 'player_page.dart';

/// Coordinates one chapter-local loop without reopening media or focus sessions.
mixin _PlayerAbRepeatCoordinator
    on
        State<PlayerPage>,
        _PlayerPlaybackSession,
        _PlayerFocusCoordinator,
        _PlayerNotesWorkspace {
  AbRepeatRange? _abRepeatRange;
  Timer? _abRepeatTimer;
  Future<void>? _abRepeatSeek;
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

  void _clearAbRepeat({bool notify = false}) {
    _abRepeatEpoch++;
    _abRepeatTimer?.cancel();
    _abRepeatTimer = null;
    _abRepeatAwaitingPosition = false;
    _abRepeatEndExpected = false;
    _abRepeatSeekReachedEnd = false;
    _abRepeatCaptureRestoreTarget = null;
    _abRepeatCaptureRestoreSource = null;
    if (_abRepeatRange != null && mounted) {
      setState(() => _abRepeatRange = null);
    }
    if (notify && mounted) _showTransientSnackBar('已清除 A–B 区间，恢复原播放方式');
  }

  @override
  void _clearAbRepeatForNavigation() => _clearAbRepeat();

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
    _abRepeatAwaitingPosition = false;
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
    _abRepeatAwaitingPosition = false;
    _abRepeatEpoch++;
    _abRepeatTimer?.cancel();
    final range = _abRepeatRange;
    if (range != null && !range.contains(target)) _clearAbRepeat(notify: true);
    await _drainAbRepeatSeek();
  }

  void _abRepeatPlaybackIntent(bool playing, {bool backend = false}) {
    if (!playing && !backend) _abRepeatPauseRevision++;
    _abRepeatUserPaused = !playing;
    if (!playing) _abRepeatEndExpected = false;
    if (!playing) _abRepeatTimer?.cancel();
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
        (snapshot.position - range.a).inMilliseconds.abs() <=
            ((range.b - range.a).inMilliseconds ~/ 4).clamp(1, 500)) {
      _abRepeatAwaitingPosition = false;
    }
    if (_externalNavigationSuspended ||
        _abRepeatSourceChanging ||
        !_abRepeatCanRunInLifecycle ||
        _abRepeatCaptureDepth > 0 ||
        _abRepeatCaptureRestoreTarget != null ||
        _abRepeatSeek != null) {
      return ended;
    }
    if (_abRepeatAwaitingPosition) return ended;
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

  /// Register before issuing seek: synchronous backend snapshots cannot duplicate it.
  void _jumpToAbRepeatA(AbRepeatRange range, {bool resumeEnded = false}) {
    final epoch = _abRepeatEpoch;
    if (_abRepeatSeek != null || !_validAbRepeat(epoch, range)) return;
    _abRepeatTimer?.cancel();
    final completion = Completer<void>();
    _abRepeatSeek = completion.future;
    _abRepeatAwaitingPosition = true;
    _abRepeatSeekReachedEnd = resumeEnded;
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

  Future<void> _showAbRepeatSheet() async {
    _showPlayerControls();
    final bvid = _activeVideo.bvid;
    final cid = _currentPart.cid;
    final sheetEpoch = _abRepeatEpoch;
    bool isCurrentSheet() =>
        mounted &&
        sheetEpoch == _abRepeatEpoch &&
        bvid == _activeVideo.bvid &&
        cid == _currentPart.cid;
    if (_displayDuration <= Duration.zero) {
      _showTransientSnackBar('媒体时长尚未就绪，请稍后重试。');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => PlayerAbRepeatSheet(
        bvid: bvid,
        cid: cid,
        duration: _displayDuration,
        readPosition: () => _playbackSnapshot.position,
        initialRange: _abRepeatRange,
        resumeFullLoop: _playbackLoopEnabled,
        onClear: () {
          if (isCurrentSheet()) _clearAbRepeat(notify: true);
        },
        onApply: (range) {
          if (!isCurrentSheet() ||
              !range.matches(_activeVideo.bvid, _currentPart.cid)) {
            return;
          }
          if (range.validate(_displayDuration) != null) {
            _showTransientSnackBar('媒体时长已变化，请重新设置 A、B 点。');
            return;
          }
          unawaited(_applyAbRepeatRange(range));
        },
      ),
    );
  }

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
    _abRepeatRange = null;
    return _drainAbRepeatSeek();
  }
}
