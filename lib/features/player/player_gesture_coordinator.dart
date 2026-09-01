part of 'player_page.dart';

/// 标识一次竖向滑动正在调整亮度、音量，或因系统手势区而不做处理。
enum _VerticalAdjustmentMode { none, brightness, volume }

/// 封装播放器画面的双击、长按、横滑、竖滑规则以及短暂反馈状态。
mixin _PlayerGestureCoordinator on State<PlayerPage> {
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
  bool _temporarySpeedActive = false;
  bool _horizontalScrubbing = false;
  double _speedBeforeLongPress = 1;
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
  PlaybackService get _playbackService;

  /// 由播放器状态类提供用于读取横滑预览图的服务。
  VideoShotService get _videoShotService;

  /// 由播放器状态类提供当前正在展示的视频资料。
  VideoPreview get _activeVideo;

  /// 由播放器状态类提供当前正在播放的分 P。
  VideoPart get _currentPart;

  /// 由播放器状态类提供最近一次真实播放状态。
  PlaybackSnapshot get _playbackSnapshot;

  /// 由播放器状态类提供已保存的画面手势偏好。
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
  set _progress(double value);

  /// 读取播放器当前倍速。
  double get _playbackSpeed;

  /// 更新播放器当前倍速。
  set _playbackSpeed(double value);

  /// 更新播放器控制层可见状态。
  set _showControls(bool value);

  /// 切换播放器的播放或暂停状态。
  void _togglePlayback();

  /// 停止控制层自动隐藏计时器。
  void _stopControlsAutoHideTimer();

  /// 重新启动控制层自动隐藏计时器。
  void _restartControlsAutoHideTimer();

  /// 显示播放器控制层。
  void _showPlayerControls();

  /// 请求播放器按相对时长跳转。
  Future<void> _seekNativeBy(Duration offset);

  /// 请求播放器跳转到指定进度比例。
  Future<void> _seekToProgress(double progress);

  /// 把播放器异常转换为画面上的可读错误。
  void _showPlaybackError(String message);

  /// 按新快照重新同步弹幕动画时钟。
  void _syncDanmakuAnimation(PlaybackSnapshot snapshot);

  /// 把总秒数格式化为播放器使用的时间文字。
  String _formatSeconds(int totalSeconds);

  /// 取消手势反馈计时器并使晚到的预览图请求失效。
  void _disposePlayerGestureCoordinator() {
    _seekFeedbackTimer?.cancel();
    _videoShotRequestToken += 1;
  }

  /// 记录双击第一次落点，供后续判断左中右分区手势使用。
  void _recordDoubleTapPosition(TapDownDetails details) {
    _lastDoubleTapPosition = details.localPosition;
  }

  /// 根据个性化设置执行分区快进快退，或把任意区域双击改成播放暂停。
  void _handleDoubleTap(double playerWidth) {
    if (!_playbackPreferences.enableDoubleTapSeek) {
      _togglePlayback();
      return;
    }
    final double tapX = _lastDoubleTapPosition?.dx ?? playerWidth / 2;
    if (tapX < playerWidth * 0.35) {
      _seekBy(-5, showFeedback: true);
    } else if (tapX > playerWidth * 0.65) {
      _seekBy(5, showFeedback: true);
    } else {
      _togglePlayback();
    }
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
      _showControls = true;
      _seekFeedback = showFeedback
          ? (seconds > 0 ? '快进 ${seconds.abs()} 秒' : '快退 ${seconds.abs()} 秒')
          : null;
    });
    unawaited(_seekNativeBy(Duration(seconds: seconds)));
    if (showFeedback) {
      _seekFeedbackTimer = Timer(_gestureFeedbackDuration, () {
        if (mounted) {
          setState(() => _seekFeedback = null);
        }
      });
    }
    _restartControlsAutoHideTimer();
  }

  /// 长按正在播放的画面时记住原倍速，并临时切换为三倍速。
  void _startTemporaryTripleSpeed(LongPressStartDetails details) {
    if (!_playing || _temporarySpeedActive || _horizontalScrubbing) {
      return;
    }
    _speedBeforeLongPress = _playbackSpeed;
    _stopControlsAutoHideTimer();
    setState(() => _temporarySpeedActive = true);
    unawaited(_setTemporaryPlaybackSpeed(3));
  }

  /// 松开长按手势后恢复长按前的倍速，不改变当前播放进度。
  void _stopTemporaryTripleSpeed(LongPressEndDetails details) {
    if (!_temporarySpeedActive) {
      return;
    }
    final double speedToRestore = _speedBeforeLongPress;
    setState(() => _temporarySpeedActive = false);
    unawaited(_setTemporaryPlaybackSpeed(speedToRestore));
    _restartControlsAutoHideTimer();
  }

  /// 长按被系统取消时恢复原倍速，避免手势竞争后残留三倍速状态。
  void _cancelTemporaryLongPress() {
    if (!_temporarySpeedActive) {
      return;
    }
    final double speedToRestore = _speedBeforeLongPress;
    setState(() => _temporarySpeedActive = false);
    unawaited(_setTemporaryPlaybackSpeed(speedToRestore));
    _restartControlsAutoHideTimer();
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
    setState(() => _videoShotLoading = true);
    final VideoShotPreview? preview = await _videoShotService.loadPreview(
      bvid: _activeVideo.bvid,
      cid: _currentPart.cid,
    );
    if (!mounted || requestToken != _videoShotRequestToken) {
      return;
    }
    setState(() {
      _videoShotLoading = false;
      _videoShotPreview = preview;
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
    _verticalAdjustmentMode = _VerticalAdjustmentMode.none;
  }

  /// 向播放器发送临时倍速，失败时恢复提示状态并显示原因。
  Future<void> _setTemporaryPlaybackSpeed(double speed) async {
    try {
      await _playbackService.setPlaybackSpeed(speed);
      if (mounted) {
        setState(() => _playbackSpeed = speed);
        _syncDanmakuAnimation(_playbackSnapshot.copyWith(speed: speed));
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _temporarySpeedActive = false);
      }
      _showPlaybackError('无法临时切换倍速：${error.message ?? error.code}');
    } catch (error) {
      if (mounted) {
        setState(() => _temporarySpeedActive = false);
      }
      _showPlaybackError('无法临时切换倍速：$error');
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
    _showPlayerControls();
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
