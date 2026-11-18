part of 'player_page.dart';

/// 标识一次竖向滑动正在调整亮度、音量，或因系统手势区而不做处理。
enum _VerticalAdjustmentMode { none, brightness, volume }

/// 封装播放器画面的双击、长按、横滑、竖滑规则以及短暂反馈状态。
mixin _PlayerGestureCoordinator on State<PlayerPage>, _PlayerPlaybackSession {
  static const Duration _gestureFeedbackDuration = Duration(seconds: 3);
  static const double _fullscreenBottomGestureExclusionHeight = 72;
  static const double _fullscreenTopGestureExclusionHeight = 56;
  static const double _fullscreenHorizontalGestureSideExclusionWidth = 48;
  static const double _horizontalSeekTravelWidthRatio = 0.75;
  static const double _minimumHorizontalSeekRangeSeconds = 120;
  static const double _maximumHorizontalSeekRangeSeconds = 600;

  Offset? _lastDoubleTapPosition;
  String? _seekFeedback;
  Timer? _seekFeedbackTimer;
  Timer? _doubleTapFeedbackTimer;
  Timer? _playbackActionTimer;
  int _doubleTapSeekSeconds = 0;
  int _doubleTapFeedbackSequence = 0;
  int _playbackActionSequence = 0;
  bool? _playbackActionPlaying;
  bool _temporarySpeedActive = false;
  @override
  bool _horizontalScrubbing = false;
  double? _requestedNormalSpeed;
  int _playbackSpeedRequest = 0;
  Future<void> _playbackSpeedCommands = Future.value();
  double get _normalPlaybackSpeed => _requestedNormalSpeed ?? _playbackSpeed;
  double _horizontalScrubStartProgress = 0;
  double _horizontalScrubTargetProgress = 0;
  double _horizontalScrubStartX = 0;
  double _horizontalSeekSecondsPerPixel = 0;
  double _horizontalSeekMaximumOffsetSeconds = 0;
  VideoShotPreview? _videoShotPreview;
  bool _videoShotLoading = false;
  int _videoShotRequestToken = 0;
  double _brightness = 1;
  double _volume = 0.5;
  double _verticalGestureStartLevel = 1;
  double _verticalGestureDelta = 0;
  _VerticalAdjustmentMode _verticalAdjustmentMode =
      _VerticalAdjustmentMode.none;

  /// 由播放器状态类提供当前平台的播放服务。
  @override
  PlaybackService get _playbackService;

  /// 由播放器状态类提供用于读取横滑预览图的服务。
  VideoShotService get _videoShotService;

  /// 由播放器状态类提供当前正在展示的视频资料。
  @override
  VideoPreview get _activeVideo;

  /// 由播放器状态类提供当前正在播放的分 P。
  @override
  VideoPart get _currentPart;

  /// 由播放器状态类提供最近一次真实播放状态。
  @override
  PlaybackSnapshot get _playbackSnapshot;

  /// 由播放器状态类提供已保存的画面手势偏好。
  @override
  PlaybackPreferences get _playbackPreferences;

  /// 由播放器状态类提供当前视频用于进度换算的总时长。
  Duration get _displayDuration;

  /// 由播放器状态类说明视频当前是否真实播放。
  bool get _playing;

  /// 由播放器状态类说明当前是否处于全屏。
  bool get _fullscreen;

  /// 读取播放器当前显示的进度比例。
  double get _progress;

  /// 更新播放器当前显示的进度比例。
  @override
  set _progress(double value);

  /// 读取播放器当前倍速。
  double get _playbackSpeed;

  /// 更新播放器当前倍速。
  @override
  set _playbackSpeed(double value);

  /// 更新播放器控制层可见状态。
  @override
  set _showControls(bool value);

  /// 切换播放器的播放或暂停状态。
  void _togglePlayback({bool showControls = true});

  /// 停止控制层自动隐藏计时器。
  @override
  void _stopControlsAutoHideTimer();

  /// 重新启动控制层自动隐藏计时器。
  @override
  void _restartControlsAutoHideTimer();

  /// 显示播放器控制层。
  void _showPlayerControls();

  /// 请求播放器按相对时长跳转。
  Future<void> _seekNativeBy(Duration offset);

  /// 请求播放器跳转到指定进度比例。
  Future<void> _seekToProgress(double progress);

  /// 把播放器异常转换为画面上的可读错误。
  @override
  void _showPlaybackError(String message);

  /// 按新快照重新同步弹幕动画时钟。
  @override
  void _syncDanmakuAnimation(PlaybackSnapshot snapshot);

  /// 把总秒数格式化为播放器使用的时间文字。
  @override
  String _formatSeconds(int totalSeconds);

  /// 取消手势反馈计时器并使晚到的预览图请求失效。
  void _disposePlayerGestureCoordinator() {
    _playbackSpeedRequest++;
    _seekFeedbackTimer?.cancel();
    _doubleTapFeedbackTimer?.cancel();
    _playbackActionTimer?.cancel();
    _videoShotRequestToken += 1;
  }

  /// 记录双击第一次落点，供后续判断左中右分区手势使用。
  void _recordDoubleTapPosition(TapDownDetails details) {
    _lastDoubleTapPosition = details.localPosition;
  }

  /// 根据个性化设置执行分区快进快退，或把任意区域双击改成播放暂停。
  void _handleDoubleTap(Size playerSize) {
    if (!_playbackPreferences.enableDoubleTapSeek) {
      _togglePlayback(showControls: false);
      return;
    }
    final tap = _lastDoubleTapPosition ?? playerSize.center(Offset.zero);
    switch (_playbackPreferences.doubleTapRegions.actionAt(
      tap.dx / playerSize.width,
      tap.dy / playerSize.height,
    )) {
      case DoubleTapAction.rewind:
        _seekBy(-5, showFeedback: true);
      case DoubleTapAction.forward:
        _seekBy(5, showFeedback: true);
      case DoubleTapAction.togglePlayback:
        _togglePlayback(showControls: false);
    }
  }

  /// 显示一次真实播放状态变化，650 毫秒后撤掉动画节点。
  @override
  void _showPlaybackActionFeedback(bool playing) {
    if (!mounted || !_playbackPreferences.showPlaybackActionAnimation) return;
    _playbackActionTimer?.cancel();
    setState(() {
      _playbackActionPlaying = playing;
      _playbackActionSequence++;
    });
    _playbackActionTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _playbackActionPlaying = null);
    });
  }

  /// 累计 1.2 秒内同方向的快进快退；反向操作或超时开始新一轮。
  void _showDoubleTapSeekFeedback(int seconds) {
    final accumulate =
        _doubleTapFeedbackTimer?.isActive == true &&
        _doubleTapSeekSeconds.sign == seconds.sign;
    _doubleTapFeedbackTimer?.cancel();
    setState(() {
      _doubleTapSeekSeconds = accumulate
          ? _doubleTapSeekSeconds + seconds
          : seconds;
      _doubleTapFeedbackSequence++;
      _seekFeedback = null;
    });
    _doubleTapFeedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _doubleTapSeekSeconds = 0);
    });
  }

  /// 按指定秒数更新界面进度并把相同的快进或快退命令交给播放器。
  void _seekBy(int seconds, {bool showFeedback = false}) {
    final double durationSeconds = _displayDuration.inMilliseconds / 1000;
    final double target = (_progress * durationSeconds + seconds)
        .clamp(0, durationSeconds)
        .toDouble();
    _seekFeedbackTimer?.cancel();
    setState(() {
      _progress = durationSeconds == 0 ? 0 : target / durationSeconds;
      if (!showFeedback) _showControls = true;
      _seekFeedback = null;
    });
    unawaited(_seekNativeBy(Duration(seconds: seconds)));
    if (showFeedback) {
      _showDoubleTapSeekFeedback(seconds);
    }
    _restartControlsAutoHideTimer();
  }

  /// 长按使用已设置的临时倍速，恢复过程中再次长按也不会把临时速度当成原速度。
  void _startTemporarySpeed(LongPressStartDetails details) {
    if (!_playing || _temporarySpeedActive || _horizontalScrubbing) return;
    _requestedNormalSpeed ??= _playbackSpeed;
    _stopControlsAutoHideTimer();
    setState(() => _temporarySpeedActive = true);
    unawaited(
      _queuePlaybackSpeed(
        _playbackPreferences.longPressPlaybackSpeed,
        temporary: true,
      ),
    );
  }

  void _stopTemporarySpeed(LongPressEndDetails details) =>
      _cancelTemporaryLongPress();

  /// 松手、指针取消、暂停或切换分 P 时还原，不沿用临时速度。
  void _cancelTemporaryLongPress() {
    if (!_temporarySpeedActive) return;
    setState(() => _temporarySpeedActive = false);
    unawaited(_queuePlaybackSpeed(_normalPlaybackSpeed, temporary: false));
    _restartControlsAutoHideTimer();
  }

  @override
  Future<void> _settleTemporaryPlaybackSpeed() {
    _cancelTemporaryLongPress();
    return _playbackSpeedCommands;
  }

  /// A bridge call may finish after release. Wait before applying the newest
  /// request so the last applied backend value (not just the label) is correct.
  Future<void> _queuePlaybackSpeed(double speed, {required bool temporary}) {
    if (!temporary) _requestedNormalSpeed = speed;
    final request = ++_playbackSpeedRequest;
    return _playbackSpeedCommands = _playbackSpeedCommands.then((_) async {
      if (!mounted || request != _playbackSpeedRequest) return;
      try {
        await _playbackService.setPlaybackSpeed(speed);
        if (!mounted || request != _playbackSpeedRequest) return;
        if (!temporary) _requestedNormalSpeed = null;
        setState(() => _playbackSpeed = speed);
        _syncDanmakuAnimation(_playbackSnapshot.copyWith(speed: speed));
      } catch (error) {
        if (!mounted || request != _playbackSpeedRequest) return;
        if (temporary) {
          _cancelTemporaryLongPress();
        } else {
          _requestedNormalSpeed = null;
        }
        final message = error is PlatformException
            ? error.message ?? error.code
            : error.toString();
        _showPlaybackError('无法切换倍速：$message');
      }
    });
  }

  /// 开始横向拖动时记录当前位置，并按视频时长和画面宽度计算自适应快进速度。
  void _startHorizontalScrub(
    DragStartDetails details,
    Size playerSize,
    EdgeInsets systemPadding,
  ) {
    final double durationSeconds = _displayDuration.inMilliseconds / 1000;
    final double protectedSideWidth =
        (_fullscreenHorizontalGestureSideExclusionWidth + systemPadding.left)
            .clamp(0, playerSize.width / 3)
            .toDouble();
    final double protectedRightWidth =
        (_fullscreenHorizontalGestureSideExclusionWidth + systemPadding.right)
            .clamp(0, playerSize.width / 3)
            .toDouble();
    final double protectedBottomHeight =
        (_fullscreenBottomGestureExclusionHeight + systemPadding.bottom)
            .clamp(0, playerSize.height / 3)
            .toDouble();
    final bool startsInFullscreenSafetyZone =
        _fullscreen &&
        (details.localPosition.dx <= protectedSideWidth ||
            details.localPosition.dx >=
                playerSize.width - protectedRightWidth ||
            details.localPosition.dy >=
                playerSize.height - protectedBottomHeight);
    if (_temporarySpeedActive ||
        startsInFullscreenSafetyZone ||
        durationSeconds <= 0 ||
        playerSize.width <= 0) {
      return;
    }
    _seekFeedbackTimer?.cancel();
    _stopControlsAutoHideTimer();
    final double seekRangeSeconds = (durationSeconds * 0.1)
        .clamp(
          _minimumHorizontalSeekRangeSeconds,
          _maximumHorizontalSeekRangeSeconds,
        )
        .toDouble();
    final double effectiveTravelWidth =
        (playerSize.width * _horizontalSeekTravelWidthRatio)
            .clamp(1, double.infinity)
            .toDouble();
    setState(() {
      _horizontalScrubbing = true;
      _horizontalScrubStartProgress = _progress;
      _horizontalScrubTargetProgress = _progress;
      _horizontalScrubStartX = details.localPosition.dx;
      _horizontalSeekSecondsPerPixel = seekRangeSeconds / effectiveTravelWidth;
      _horizontalSeekMaximumOffsetSeconds = seekRangeSeconds;
      _showControls = true;
    });
    unawaited(_loadVideoShotPreview());
  }

  /// 首次横向拖动时按需读取当前分 P 预览图，并忽略切视频后的晚到结果。
  Future<void> _loadVideoShotPreview() async {
    if (_videoShotPreview != null || _videoShotLoading) {
      return;
    }
    final int requestToken = ++_videoShotRequestToken;
    final bvid = _activeVideo.bvid;
    final cid = _currentPart.cid;
    setState(() => _videoShotLoading = true);
    VideoShotPreview? preview;
    try {
      preview = await _videoShotService
          .loadPreview(bvid: bvid, cid: cid)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // These previews are optional. The next gesture can retry.
    }
    if (!mounted || requestToken != _videoShotRequestToken) return;
    setState(() {
      _videoShotLoading = false;
      _videoShotPreview = bvid == _activeVideo.bvid && cid == _currentPart.cid
          ? preview
          : null;
    });
  }

  /// 切换分 P 或视频时清除旧截图，避免把上一支视频的画面当成新进度预览。
  void _resetVideoShotPreview() {
    _videoShotRequestToken += 1;
    _videoShotPreview = null;
    _videoShotLoading = false;
  }

  /// 拖动过程中只更新本地进度预览，松手前不会反复打断播放器。
  void _updateHorizontalScrub(DragUpdateDetails details) {
    if (!_horizontalScrubbing) {
      return;
    }
    final double durationSeconds = _displayDuration.inMilliseconds / 1000;
    if (durationSeconds <= 0) {
      return;
    }
    final double offsetSeconds =
        ((details.localPosition.dx - _horizontalScrubStartX) *
                _horizontalSeekSecondsPerPixel)
            .clamp(
              -_horizontalSeekMaximumOffsetSeconds,
              _horizontalSeekMaximumOffsetSeconds,
            )
            .toDouble();
    final double targetSeconds =
        (_horizontalScrubStartProgress * durationSeconds + offsetSeconds)
            .clamp(0, durationSeconds)
            .toDouble();
    _seekFeedbackTimer?.cancel();
    setState(() {
      _horizontalScrubTargetProgress = targetSeconds / durationSeconds;
      _progress = _horizontalScrubTargetProgress;
      _seekFeedback = '跳转至 ${_formatSeconds(targetSeconds.round())}';
    });
  }

  /// 横向拖动松手后只向播放器提交一次最终目标进度。
  void _finishHorizontalScrub(DragEndDetails details) {
    if (!_horizontalScrubbing) {
      return;
    }
    final double targetProgress = _horizontalScrubTargetProgress;
    setState(() => _horizontalScrubbing = false);
    unawaited(_seekToProgress(targetProgress));
    _scheduleSeekFeedbackClear();
    _restartControlsAutoHideTimer();
  }

  /// 横向拖动被系统取消时回到拖动开始前的位置，且不请求播放器跳转。
  void _cancelHorizontalScrub() {
    if (!_horizontalScrubbing) {
      return;
    }
    _seekFeedbackTimer?.cancel();
    setState(() {
      _horizontalScrubbing = false;
      _progress = _horizontalScrubStartProgress;
      _seekFeedback = null;
    });
    _restartControlsAutoHideTimer();
  }

  /// 处理系统级指针取消，撤销横向预览、临时倍速和竖滑状态。
  void _handlePlayerPointerCancel(PointerCancelEvent event) {
    _cancelHorizontalScrub();
    _cancelTemporaryLongPress();
    if (_verticalAdjustmentMode != _VerticalAdjustmentMode.none) {
      _verticalAdjustmentMode = _VerticalAdjustmentMode.none;
      _scheduleSeekFeedbackClear();
      _restartControlsAutoHideTimer();
    }
  }

  /// 让快捷跳转或设置提示在三秒后消失，避免永久遮挡画面。
  void _scheduleSeekFeedbackClear() {
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(_gestureFeedbackDuration, () {
      if (mounted) {
        setState(() => _seekFeedback = null);
      }
    });
  }

  /// 根据手指起点选择左侧亮度或右侧音量，并避开播放器顶部与底部控制区。
  void _startVerticalAdjustment(
    DragStartDetails details,
    Size playerSize,
    double topSystemInset,
    double bottomSystemInset,
  ) {
    if (_temporarySpeedActive || _horizontalScrubbing) {
      _verticalAdjustmentMode = _VerticalAdjustmentMode.none;
      return;
    }
    final double topExcludedHeight =
        (_fullscreenTopGestureExclusionHeight + topSystemInset)
            .clamp(0, playerSize.height)
            .toDouble();
    final double bottomExcludedHeight =
        (_fullscreenBottomGestureExclusionHeight + bottomSystemInset)
            .clamp(0, playerSize.height)
            .toDouble();
    if (details.localPosition.dy <= topExcludedHeight ||
        details.localPosition.dy >= playerSize.height - bottomExcludedHeight) {
      _verticalAdjustmentMode = _VerticalAdjustmentMode.none;
      return;
    }
    _verticalAdjustmentMode = details.localPosition.dx < playerSize.width / 2
        ? _VerticalAdjustmentMode.brightness
        : _VerticalAdjustmentMode.volume;
    _verticalGestureStartLevel =
        _verticalAdjustmentMode == _VerticalAdjustmentMode.brightness
        ? _brightness
        : _volume;
    _verticalGestureDelta = 0;
    _stopControlsAutoHideTimer();
  }

  /// 将竖向移动距离换算为亮度或音量比例，并实时发送给播放服务。
  void _updateVerticalAdjustment(
    DragUpdateDetails details,
    double playerHeight,
  ) {
    if (_verticalAdjustmentMode == _VerticalAdjustmentMode.none ||
        playerHeight <= 0) {
      return;
    }
    _verticalGestureDelta += -details.delta.dy / playerHeight * 1.6;
    final double value = (_verticalGestureStartLevel + _verticalGestureDelta)
        .clamp(0, 1)
        .toDouble();
    if (_verticalAdjustmentMode == _VerticalAdjustmentMode.brightness) {
      _brightness = value.clamp(0.01, 1).toDouble();
      unawaited(_playbackService.setScreenBrightness(_brightness));
      _showAdjustmentFeedback('亮度 ${(_brightness * 100).round()}%');
    } else {
      _volume = value;
      unawaited(_playbackService.setMediaVolume(_volume));
      _showAdjustmentFeedback('音量 ${(_volume * 100).round()}%');
    }
  }

  /// 在竖向手势结束后恢复控制栏自动隐藏，并短暂保留调整结果。
  void _finishVerticalAdjustment(DragEndDetails details) {
    if (_verticalAdjustmentMode == _VerticalAdjustmentMode.none) {
      return;
    }
    _verticalAdjustmentMode = _VerticalAdjustmentMode.none;
    _scheduleSeekFeedbackClear();
    _restartControlsAutoHideTimer();
  }

  /// 在播放器中央显示当前亮度、音量或其他画面设置的反馈。
  void _showAdjustmentFeedback(String message) {
    if (!mounted) {
      return;
    }
    if (_seekFeedback != message) {
      setState(() => _seekFeedback = message);
    }
  }
}
