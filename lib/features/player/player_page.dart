import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/video_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../services/device_status_service.dart';
import '../../services/native_playback_service.dart';
import '../../services/player_overlay_service.dart';
import '../../services/watch_history_service.dart';
import '../../models/player_overlay_data.dart';

/// 标识一次竖向滑动正在调整亮度、音量，或因底部手势区而不做处理。
enum _VerticalAdjustmentMode { none, brightness, volume }

/// 标识全屏视频画面应保留比例、裁切填充，还是按屏幕比例拉伸。
enum _VideoFitMode { contain, cover, stretch }

/// 标识全屏右上角“更多”菜单中可执行的本地播放器设置。
enum _PlayerMoreMenuAction {
  subtitles,
  decoderSettings,
  fitContain,
  fitCover,
  fitStretch,
}

/// 新架构的原生播放器页面，提供简洁的 App 风格控制层。
class PlayerPage extends StatefulWidget {
  /// 创建播放器页面，并允许测试替换原生播放和本地观看记录服务。
  const PlayerPage({
    super.key,
    required this.video,
    this.playbackService,
    this.watchHistoryService,
    this.deviceStatusService,
    this.playerOverlayService,
  });

  final VideoPreview video;
  final PlaybackService? playbackService;
  final WatchHistoryService? watchHistoryService;
  final DeviceStatusService? deviceStatusService;
  final PlayerOverlayService? playerOverlayService;

  /// 创建播放器状态，保存播放、进度、控制层和全屏状态。
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 管理原生视频纹理、播放状态、手势、控制层和系统全屏状态。
class _PlayerPageState extends State<PlayerPage> {
  static const Duration _controlsAutoHideDelay = Duration(seconds: 5);
  static const Duration _transientHintDuration = Duration(seconds: 3);
  static const Duration _resumeNoticeDuration = _transientHintDuration;
  static const Duration _watchHistoryProgressSaveInterval = Duration(
    seconds: 15,
  );
  static const double _fullscreenBottomGestureExclusionHeight = 72;
  static const double _fullscreenTopGestureExclusionHeight = 56;
  static const double _horizontalSeekTravelWidthRatio = 0.75;
  static const double _minimumHorizontalSeekRangeSeconds = 120;
  static const double _maximumHorizontalSeekRangeSeconds = 600;
  static const String _subtitleOffValue = '__focubili_subtitle_off__';
  static const Duration _danmakuNextSegmentPreloadThreshold = Duration(
    seconds: 30,
  );
  static const int _maximumCachedDanmakuSegments = 3;
  static const double _expandedPartItemHeight = 76;
  static const List<double> _playbackSpeeds = <double>[
    0.75,
    1,
    1.25,
    1.5,
    2,
  ];

  late final PlaybackService _playbackService;
  late final WatchHistoryService _watchHistoryService;
  late final DeviceStatusService _deviceStatusService;
  late final PlayerOverlayService _playerOverlayService;
  late VideoPart _currentPart;
  final ScrollController _partScrollController = ScrollController();
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  PlaybackSnapshot _playbackSnapshot = const PlaybackSnapshot();
  int? _textureId;
  bool _fullscreen = false;
  bool _showControls = true;
  bool _isDraggingProgress = false;
  double _progress = 0;
  Offset? _lastDoubleTapPosition;
  String? _seekFeedback;
  String? _resumeNotice;
  Timer? _controlsTimer;
  Timer? _seekFeedbackTimer;
  Timer? _resumeNoticeTimer;
  Timer? _fullscreenStatusTimer;
  double _playbackSpeed = 1;
  int _currentQuality = 64;
  int? _pendingQualitySelection;
  List<PlaybackQuality> _availableQualities = const <PlaybackQuality>[
    PlaybackQuality(id: 64, label: '高清 720P'),
  ];
  bool _partSelectorExpanded = false;
  bool _partsAscending = true;
  bool _danmakuEnabled = false;
  _VideoFitMode _videoFitMode = _VideoFitMode.contain;
  bool _temporaryDoubleSpeedActive = false;
  bool _horizontalScrubbing = false;
  bool _isRetrying = false;
  double _speedBeforeLongPress = 1;
  double _horizontalScrubStartProgress = 0;
  double _horizontalScrubTargetProgress = 0;
  double _horizontalScrubStartX = 0;
  double _horizontalSeekSecondsPerPixel = 0;
  double _horizontalSeekMaximumOffsetSeconds = 0;
  int? _shownRestoredCid;
  double _brightness = 0.5;
  double _volume = 0.5;
  double _verticalGestureStartLevel = 0.5;
  double _verticalGestureDelta = 0;
  _VerticalAdjustmentMode _verticalAdjustmentMode =
      _VerticalAdjustmentMode.none;
  int? _recordedHistoryPartCid;
  Duration _lastHistorySavedPosition = Duration.zero;
  DateTime _fullscreenClock = DateTime.now();
  int? _batteryPercent;
  SubtitleTrackLoadResult? _subtitleTrackResult;
  SubtitleTrack? _selectedSubtitleTrack;
  List<SubtitleCue> _subtitleCues = const <SubtitleCue>[];
  bool _subtitleTracksLoading = false;
  bool _subtitleCuesLoading = false;
  int _subtitleRequestToken = 0;
  final Map<int, List<DanmakuEntry>> _danmakuSegments =
      <int, List<DanmakuEntry>>{};
  final Set<int> _loadingDanmakuSegments = <int>{};
  final Set<int> _failedDanmakuSegments = <int>{};
  int _danmakuRequestToken = 0;

  /// 判断原生播放器是否真的在播放，避免 Flutter 页面自己伪造播放状态。
  bool get _playing => _playbackSnapshot.isPlaying;

  /// 优先使用原生播放器返回的真实总时长，加载前暂以视频卡片时长保持界面稳定。
  Duration get _displayDuration {
    return _playbackSnapshot.duration > Duration.zero
        ? _playbackSnapshot.duration
        : _currentPart.duration;
  }

  /// 创建播放服务、订阅原生状态，并启动视频纹理和播放数据请求。
  @override
  void initState() {
    super.initState();
    _currentPart = widget.video.initialPart;
    _playbackService = widget.playbackService ?? NativePlaybackService();
    _watchHistoryService = widget.watchHistoryService ?? WatchHistoryService();
    _deviceStatusService =
        widget.deviceStatusService ?? const NativeDeviceStatusService();
    _playerOverlayService =
        widget.playerOverlayService ?? NativePlayerOverlayService();
    _playbackSubscription = _playbackService.states.listen(
      _applyPlaybackSnapshot,
    );
    unawaited(_initializeNativePlayback());
  }

  /// 请求 Android 创建 Media3 视频纹理，再直接请求公开视频的播放数据。
  Future<void> _initializeNativePlayback() async {
    try {
      final SavedPlaybackState? savedState =
          await _playbackService.loadSavedPlaybackState(widget.video.bvid);
      final SystemPlaybackLevels levels =
          await _playbackService.getSystemPlaybackLevels();
      final VideoPart restoredPart = _findSavedPart(savedState);
      final bool restoredPartMatched =
          savedState != null && restoredPart.cid == savedState.cid;
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPart = restoredPart;
        _brightness = levels.brightness;
        _volume = levels.volume;
      });
      if (restoredPartMatched && widget.video.parts.length > 1) {
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
        widget.video,
        part: _currentPart,
        quality: _currentQuality,
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法启动原生播放器：${error.message ?? error.code}');
    } on ArgumentError catch (error) {
      _showPlaybackError(error.message?.toString() ?? 'BV 号无效。');
    } catch (error) {
      _showPlaybackError('无法初始化播放器：$error');
    }
  }

  /// 在视频分P列表中查找本机保存的 cid，失效时回退到接口默认分P。
  VideoPart _findSavedPart(SavedPlaybackState? savedState) {
    if (savedState != null) {
      for (final VideoPart part in widget.video.parts) {
        if (part.cid == savedState.cid) {
          return part;
        }
      }
    }
    return widget.video.initialPart;
  }

  /// 使用系统风格提示告知用户已经定位到上次观看的分P。
  void _showPartRestoreSnackBar(int pageNumber) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已跳转到上次分P：P$pageNumber'),
          duration: _transientHintDuration,
        ),
      );
  }

  /// 把 Android 推送的播放状态写入页面、记录就绪观看历史，并在非拖动状态下同步真实进度。
  void _applyPlaybackSnapshot(PlaybackSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    final bool shouldShowResumeNotice = snapshot.phase == PlaybackPhase.ready &&
        snapshot.restoredPosition > Duration.zero &&
        _shownRestoredCid != _currentPart.cid;
    final int? pendingQuality = _pendingQualitySelection;
    final bool qualitySelectionFinished = pendingQuality != null &&
        (snapshot.phase == PlaybackPhase.ready ||
            snapshot.phase == PlaybackPhase.error);
    final bool qualitySelectionFailed =
        qualitySelectionFinished && snapshot.currentQuality != pendingQuality;
    final bool leftPictureInPicture = _playbackSnapshot.isInPictureInPicture &&
        !snapshot.isInPictureInPicture;
    setState(() {
      _playbackSnapshot = snapshot;
      _isRetrying = false;
      if (!_isDraggingProgress &&
          !_horizontalScrubbing &&
          snapshot.duration > Duration.zero) {
        _progress = (snapshot.position.inMilliseconds /
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
      }
      if (snapshot.isInPictureInPicture) {
        _showControls = false;
      } else if (leftPictureInPicture) {
        _showControls = true;
      }
    });
    if (qualitySelectionFailed) {
      _showMembershipQualityNotice();
    }
    if (shouldShowResumeNotice) {
      _shownRestoredCid = _currentPart.cid;
      _showResumeNotice(snapshot.restoredPosition);
    }
    _recordWatchHistoryWhenReady(snapshot);
    _recordWatchHistoryProgressWhenNeeded(snapshot);
    if (_danmakuEnabled && snapshot.phase == PlaybackPhase.ready) {
      _ensureDanmakuSegmentsForPosition(snapshot.position);
    }
    if (!snapshot.isPlaying || snapshot.isInPictureInPicture) {
      _stopControlsAutoHideTimer();
    } else if (_showControls && _controlsTimer == null) {
      _restartControlsAutoHideTimer();
    }
  }

  /// 仅在某个分P第一次进入就绪状态时记录观看历史，避免状态流重复写入。
  void _recordWatchHistoryWhenReady(PlaybackSnapshot snapshot) {
    if (snapshot.phase != PlaybackPhase.ready ||
        _recordedHistoryPartCid == _currentPart.cid) {
      return;
    }
    _recordedHistoryPartCid = _currentPart.cid;
    unawaited(_saveCurrentWatchHistory(snapshot.position));
  }

  /// 每隔一小段实际播放进度或暂停后保存当前位置，避免历史进度每半秒写入一次。
  void _recordWatchHistoryProgressWhenNeeded(PlaybackSnapshot snapshot) {
    if (snapshot.phase != PlaybackPhase.ready ||
        _recordedHistoryPartCid != _currentPart.cid) {
      return;
    }
    final int positionDeltaMs = (snapshot.position.inMilliseconds -
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
  void _flushCurrentWatchHistoryProgress() {
    if (_recordedHistoryPartCid != _currentPart.cid ||
        _playbackSnapshot.position == _lastHistorySavedPosition) {
      return;
    }
    unawaited(_saveCurrentWatchHistory(_playbackSnapshot.position));
  }

  /// 把当前视频、分P、封面和播放位置交给本机历史服务，写入失败不影响播放。
  Future<void> _saveCurrentWatchHistory(Duration position) async {
    final Duration safePosition =
        position.isNegative ? Duration.zero : position;
    _lastHistorySavedPosition = safePosition;
    try {
      await _watchHistoryService.record(
        WatchHistoryEntry(
          bvid: widget.video.bvid,
          title: widget.video.title,
          ownerName: widget.video.ownerName,
          lastPartTitle: _currentPart.title,
          lastPartPageNumber: _currentPart.pageNumber,
          watchedAt: DateTime.now(),
          thumbnailUrl: widget.video.thumbnailUrl,
          lastPosition: safePosition,
        ),
      );
    } catch (_) {
      // 本地偏好设置异常不能中断播放器；后续换P或重新打开时仍会再次尝试保存。
    }
  }

  /// 显示三秒续播提示；控制栏出现时提示会在布局中自动上移。
  void _showResumeNotice(Duration position) {
    _resumeNoticeTimer?.cancel();
    setState(() {
      _resumeNotice = '已跳转到上次进度：${_formatSeconds(position.inSeconds)}';
    });
    _resumeNoticeTimer = Timer(_resumeNoticeDuration, () {
      if (mounted) {
        setState(() => _resumeNotice = null);
      }
    });
  }

  /// 显示可理解的错误说明，并停止控制层自动收起计时器。
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

  /// 再次请求当前视频、当前分P和当前清晰度，等待原生快照决定是否替换原错误提示。
  Future<void> _retryPlayback() async {
    if (_isRetrying || !mounted) {
      return;
    }
    setState(() => _isRetrying = true);
    try {
      await _playbackService.openVideo(
        widget.video,
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

  /// 离开页面前取消重试状态、订阅和计时器，释放原生资源并恢复竖屏与系统栏。
  @override
  void dispose() {
    _flushCurrentWatchHistoryProgress();
    _isRetrying = false;
    _controlsTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _resumeNoticeTimer?.cancel();
    _fullscreenStatusTimer?.cancel();
    _partScrollController.dispose();
    unawaited(_playbackSubscription?.cancel() ?? Future<void>.value());
    unawaited(_playbackService.dispose());
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  /// 根据当前真实播放状态向原生播放器发送播放或暂停命令。
  void _togglePlayback() {
    _showPlayerControls();
    unawaited(_setPlaybackActive(!_playing));
  }

  /// 执行原生播放或暂停命令，并把平台异常转换为页面可读的错误。
  Future<void> _setPlaybackActive(bool shouldPlay) async {
    try {
      if (shouldPlay) {
        await _playbackService.play();
      } else {
        await _playbackService.pause();
      }
    } on PlatformException catch (error) {
      _showPlaybackError('无法控制播放：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法控制播放：$error');
    }
  }

  /// 响应画面单击：只显示或隐藏控制层，不直接改变播放状态。
  void _toggleControls() {
    if (_showControls) {
      _hideControls();
    } else {
      _showPlayerControls();
    }
  }

  /// 显示控制层并在播放状态下重新开始自动收起倒计时。
  void _showPlayerControls() {
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    _restartControlsAutoHideTimer();
  }

  /// 隐藏控制层并停止自动收起倒计时。
  void _hideControls() {
    _stopControlsAutoHideTimer();
    if (_showControls) {
      setState(() => _showControls = false);
    }
  }

  /// 在视频播放且控制层可见时，安排五秒后自动隐藏控制层。
  void _restartControlsAutoHideTimer() {
    _stopControlsAutoHideTimer();
    if (!_showControls ||
        !_playing ||
        _playbackSnapshot.isInPictureInPicture ||
        _isDraggingProgress ||
        _temporaryDoubleSpeedActive ||
        _horizontalScrubbing) {
      return;
    }
    _controlsTimer = Timer(_controlsAutoHideDelay, () {
      if (mounted &&
          _showControls &&
          _playing &&
          !_playbackSnapshot.isInPictureInPicture &&
          !_isDraggingProgress &&
          !_temporaryDoubleSpeedActive &&
          !_horizontalScrubbing) {
        setState(() {
          _showControls = false;
          _controlsTimer = null;
        });
      } else {
        _controlsTimer = null;
      }
    });
  }

  /// 取消已有控制层倒计时，避免多个计时器同时修改页面状态。
  void _stopControlsAutoHideTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
  }

  /// 记录双击第一次落点，供后续判断左中右分区手势使用。
  void _recordDoubleTapPosition(TapDownDetails details) {
    _lastDoubleTapPosition = details.localPosition;
  }

  /// 根据双击位置执行左侧快退五秒、右侧快进五秒或中间播放暂停。
  void _handleDoubleTap(double playerWidth) {
    final double tapX = _lastDoubleTapPosition?.dx ?? playerWidth / 2;
    if (tapX < playerWidth * 0.35) {
      _seekBy(-5, showFeedback: true);
    } else if (tapX > playerWidth * 0.65) {
      _seekBy(5, showFeedback: true);
    } else {
      _togglePlayback();
    }
  }

  /// 按指定秒数更新界面进度并把相同的快进或快退命令交给原生播放器。
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
      _seekFeedbackTimer = Timer(_transientHintDuration, () {
        if (mounted) {
          setState(() => _seekFeedback = null);
        }
      });
    }
    _restartControlsAutoHideTimer();
  }

  /// 请求原生播放器按相对时长跳转，并把发生的异常显示在页面上。
  Future<void> _seekNativeBy(Duration offset) async {
    try {
      await _playbackService.seekBy(offset);
    } on PlatformException catch (error) {
      _showPlaybackError('无法跳转进度：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法跳转进度：$error');
    }
  }

  /// 把进度条比例换算为真实毫秒位置，再请求原生播放器跳转。
  Future<void> _seekToProgress(double progress) async {
    final Duration target = Duration(
      milliseconds: (_displayDuration.inMilliseconds * progress).round(),
    );
    try {
      await _playbackService.seekTo(target);
    } on PlatformException catch (error) {
      _showPlaybackError('无法跳转进度：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法跳转进度：$error');
    }
  }

  /// 请求原生播放器切换倍速，并让控制层继续显示以便用户确认选择。
  Future<void> _changePlaybackSpeed(double speed) async {
    _showPlayerControls();
    try {
      await _playbackService.setPlaybackSpeed(speed);
      if (mounted) {
        setState(() => _playbackSpeed = speed);
      }
    } on PlatformException catch (error) {
      _showPlaybackError('无法切换倍速：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法切换倍速：$error');
    }
  }

  /// 长按正在播放的画面时记住原倍速，并临时切换为二倍速。
  void _startTemporaryDoubleSpeed(LongPressStartDetails details) {
    if (!_playing || _temporaryDoubleSpeedActive || _horizontalScrubbing) {
      return;
    }
    _speedBeforeLongPress = _playbackSpeed;
    _stopControlsAutoHideTimer();
    setState(() {
      _temporaryDoubleSpeedActive = true;
    });
    unawaited(_setTemporaryPlaybackSpeed(2));
  }

  /// 松开长按手势后恢复长按前的倍速，不改变当前播放进度。
  void _stopTemporaryDoubleSpeed(LongPressEndDetails details) {
    if (!_temporaryDoubleSpeedActive) {
      return;
    }
    final double speedToRestore = _speedBeforeLongPress;
    setState(() {
      _temporaryDoubleSpeedActive = false;
    });
    unawaited(_setTemporaryPlaybackSpeed(speedToRestore));
    _restartControlsAutoHideTimer();
  }

  /// 长按被系统取消时恢复原倍速，避免手势竞争后残留二倍速状态。
  void _cancelTemporaryLongPress() {
    if (!_temporaryDoubleSpeedActive) {
      return;
    }
    final double speedToRestore = _speedBeforeLongPress;
    setState(() {
      _temporaryDoubleSpeedActive = false;
    });
    unawaited(_setTemporaryPlaybackSpeed(speedToRestore));
    _restartControlsAutoHideTimer();
  }

  /// 开始横向拖动时记录当前位置，并按视频时长和画面宽度计算自适应快进速度。
  void _startHorizontalScrub(DragStartDetails details, Size playerSize) {
    final double durationSeconds = _displayDuration.inMilliseconds / 1000;
    if (_temporaryDoubleSpeedActive ||
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
  }

  /// 拖动过程中只更新本地进度预览，松手前不会反复打断原生播放器。
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

  /// 横向拖动松手后只向原生播放器提交一次最终目标进度。
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

  /// 横向拖动被系统取消时回到拖动开始前的位置，且不请求原生跳转。
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

  /// 处理系统级指针取消，优先撤销横向预览和临时倍速，避免被识别为正常松手。
  void _handlePlayerPointerCancel(PointerCancelEvent event) {
    _cancelHorizontalScrub();
    _cancelTemporaryLongPress();
    _verticalAdjustmentMode = _VerticalAdjustmentMode.none;
  }

  /// 向原生播放器发送临时倍速，失败时恢复提示状态并显示原因。
  Future<void> _setTemporaryPlaybackSpeed(double speed) async {
    try {
      await _playbackService.setPlaybackSpeed(speed);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _temporaryDoubleSpeedActive = false);
      }
      _showPlaybackError('无法临时切换倍速：${error.message ?? error.code}');
    } catch (error) {
      if (mounted) {
        setState(() => _temporaryDoubleSpeedActive = false);
      }
      _showPlaybackError('无法临时切换倍速：$error');
    }
  }

  /// 让快捷跳转提示在用户松手后三秒消失，避免永久遮挡画面。
  void _scheduleSeekFeedbackClear() {
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(_transientHintDuration, () {
      if (mounted) {
        setState(() => _seekFeedback = null);
      }
    });
  }

  /// 请求原生播放器保留当前进度并切换到所选清晰度。
  Future<void> _changeQuality(int quality) async {
    _showPlayerControls();
    setState(() => _pendingQualitySelection = quality);
    try {
      await _playbackService.selectQuality(quality);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _pendingQualitySelection = null);
      }
      _showMembershipQualityNotice(error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _pendingQualitySelection = null);
      }
      _showMembershipQualityNotice(error.toString());
    }
  }

  /// 用三秒系统提示说明高画质切换失败通常与大会员权限有关。
  void _showMembershipQualityNotice([String? details]) {
    if (!mounted) {
      return;
    }
    final String suffix =
        details == null || details.trim().isEmpty ? '' : '（${details.trim()}）';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('画质切换失败：可能未开通大会员或当前账号无此画质权限$suffix'),
          duration: _transientHintDuration,
        ),
      );
  }

  /// 保存旧分P进度后打开新分P，并等待新分P就绪后更新同一 BV 号的观看记录。
  Future<void> _changePart(VideoPart part) async {
    if (part.cid == _currentPart.cid) {
      return;
    }
    _flushCurrentWatchHistoryProgress();
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    setState(() {
      _currentPart = part;
      _progress = 0;
      _showControls = true;
      _resumeNotice = null;
    });
    _shownRestoredCid = null;
    _recordedHistoryPartCid = null;
    _lastHistorySavedPosition = Duration.zero;
    _resumeNoticeTimer?.cancel();
    try {
      await _playbackService.openVideo(
        widget.video,
        part: part,
        quality: _currentQuality,
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法切换分P：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法切换分P：$error');
    }
  }

  /// 标记进度条正被手指拖动，并暂停自动隐藏以方便精确调整。
  void _startProgressDrag(double value) {
    _isDraggingProgress = true;
    _stopControlsAutoHideTimer();
  }

  /// 只更新拖动过程中的本地显示，避免每一像素都向原生播放器发网络无关的命令。
  void _updateProgressDrag(double value) {
    setState(() => _progress = value);
  }

  /// 结束进度条拖动后把最终位置发送给原生播放器，并恢复自动隐藏策略。
  void _finishProgressDrag(double value) {
    _isDraggingProgress = false;
    setState(() => _progress = value);
    unawaited(_seekToProgress(value));
    _restartControlsAutoHideTimer();
  }

  /// 根据当前进度生成“当前时间 / 总时长”的播放器文字。
  String _formatProgress() {
    final int current = (_progress * _displayDuration.inSeconds).round();
    return '${_formatSeconds(current)} / ${_formatSeconds(_displayDuration.inSeconds)}';
  }

  /// 把秒数转换成分秒格式；超过一小时后自动显示“时:分:秒”。
  String _formatSeconds(int totalSeconds) {
    final int safeSeconds = totalSeconds < 0 ? 0 : totalSeconds;
    final int hours = safeSeconds ~/ 3600;
    final int minutes = (safeSeconds % 3600) ~/ 60;
    final int seconds = safeSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// 把倍速数字格式化为播放器按钮使用的简短文字。
  String _formatSpeed(double speed) {
    return speed == speed.roundToDouble()
        ? '${speed.toInt()}x'
        : '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '')}x';
  }

  /// 返回当前清晰度的用户可读名称，未知编号时显示原始质量编号。
  String _currentQualityLabel() {
    for (final PlaybackQuality quality in _availableQualities) {
      if (quality.id == _currentQuality) {
        return quality.label;
      }
    }
    return 'Q$_currentQuality';
  }

  /// 创建播放器底部菜单使用的白色紧凑文字标签。
  Widget _buildControlMenuLabel(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Text(text, style: const TextStyle(color: Colors.white)),
    );
  }

  /// 根据手指起点选择左侧亮度或右侧音量，并避开全屏顶部与底部系统手势区。
  void _startVerticalAdjustment(
    DragStartDetails details,
    Size playerSize,
    double topSystemInset,
    double bottomSystemInset,
  ) {
    if (_temporaryDoubleSpeedActive || _horizontalScrubbing) {
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
    if (_fullscreen &&
        (details.localPosition.dy <= topExcludedHeight ||
            details.localPosition.dy >=
                playerSize.height - bottomExcludedHeight)) {
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

  /// 将竖向移动距离换算为亮度或音量比例，并实时发送到 Android。
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
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(_transientHintDuration, () {
      if (mounted) {
        setState(() => _seekFeedback = null);
      }
    });
    _restartControlsAutoHideTimer();
  }

  /// 在播放器中央显示当前亮度或音量百分比。
  void _showAdjustmentFeedback(String message) {
    if (!mounted) {
      return;
    }
    if (_seekFeedback != message) {
      setState(() => _seekFeedback = message);
    }
  }

  /// 创建单行横向滚动分P列表，每张卡片用两行分别显示编号和标题。
  Widget _buildPartSelector() {
    if (widget.video.parts.length <= 1) {
      return const SizedBox.shrink();
    }
    final List<VideoPart> parts = _orderedParts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 18),
        Row(
          children: <Widget>[
            Text(
              '选集 · 共 ${parts.length} 集',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            TextButton.icon(
              // 展开按钮函数让选集面板占满播放器下方空间。
              onPressed: _openPartSelector,
              icon: const Icon(Icons.open_in_full_rounded),
              label: const Text('展开'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 54,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: parts.length,
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int index) {
              return SizedBox(
                width: 190,
                child: _buildPartCard(parts[index], compact: true),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 按当前正序或倒序设置返回用于界面的分P列表副本。
  List<VideoPart> _orderedParts() {
    final List<VideoPart> parts = List<VideoPart>.of(widget.video.parts)
      ..sort(
        (VideoPart left, VideoPart right) =>
            left.pageNumber.compareTo(right.pageNumber),
      );
    return _partsAscending ? parts : parts.reversed.toList(growable: false);
  }

  /// 打开铺满播放器下方空间的双列选集面板并定位当前分P。
  void _openPartSelector() {
    setState(() => _partSelectorExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateCurrentPart());
  }

  /// 关闭展开选集面板，恢复视频信息和单行横向选集。
  void _closePartSelector() {
    setState(() => _partSelectorExpanded = false);
  }

  /// 切换选集正序或倒序，并保持当前分P仍在可见区域。
  void _setPartOrdering(bool ascending) {
    setState(() => _partsAscending = ascending);
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateCurrentPart());
  }

  /// 按当前排序计算目标行，将双列列表滚动到正在播放的分P。
  void _locateCurrentPart() {
    if (!_partScrollController.hasClients) {
      return;
    }
    final List<VideoPart> parts = _orderedParts();
    final int index = parts.indexWhere(
      (VideoPart part) => part.cid == _currentPart.cid,
    );
    if (index < 0) {
      return;
    }
    final double target = (index ~/ 2) * (_expandedPartItemHeight + 8);
    _partScrollController.animateTo(
      target.clamp(0, _partScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  /// 创建占满剩余空间的双列选集，以及定位、排序和关闭按钮。
  Widget _buildExpandedPartSelector() {
    final List<VideoPart> parts = _orderedParts();
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '选择分P · 共 ${parts.length} 集',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  // 定位按钮函数滚动到正在播放的分P。
                  onPressed: _locateCurrentPart,
                  icon: const Icon(Icons.my_location_rounded),
                  tooltip: '定位到当前分P',
                ),
                IconButton(
                  // 正序按钮函数按 P1 到最后一P重新排列列表。
                  onPressed: () => _setPartOrdering(true),
                  icon: const Icon(Icons.arrow_upward_rounded),
                  tooltip: '正排序',
                ),
                IconButton(
                  // 倒序按钮函数按最后一P到 P1 重新排列列表。
                  onPressed: () => _setPartOrdering(false),
                  icon: const Icon(Icons.arrow_downward_rounded),
                  tooltip: '倒排序',
                ),
                IconButton(
                  // 关闭按钮函数退出展开选集界面。
                  onPressed: _closePartSelector,
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭选择',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: GridView.builder(
              controller: _partScrollController,
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent: _expandedPartItemHeight,
              ),
              itemCount: parts.length,
              itemBuilder: (BuildContext context, int index) {
                return _buildPartCard(parts[index], compact: false);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 创建分P卡片，标题在同一按钮内最多显示两行并按需竖向滚动。
  Widget _buildPartCard(VideoPart part, {required bool compact}) {
    final bool selected = part.cid == _currentPart.cid;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceVariant,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('part-${part.pageNumber}'),
        borderRadius: BorderRadius.circular(10),
        // 分P卡片函数保存旧进度并打开用户选择的新分P。
        onTap: () => unawaited(_changePart(part)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 4 : 8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                'P${part.pageNumber}',
                style: TextStyle(
                  color: selected ? colors.onPrimaryContainer : null,
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 12 : 13,
                ),
              ),
              SizedBox(height: compact ? 1 : 3),
              Expanded(
                child: _PartTitleMarquee(
                  key: Key('part-title-${part.pageNumber}'),
                  text: part.title,
                  style: TextStyle(
                    color: selected ? colors.onPrimaryContainer : null,
                    fontSize: compact ? 12 : 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 进入或退出沉浸横屏，并同步播放器布局和控制层状态。
  Future<void> _toggleFullscreen() async {
    final bool nextFullscreen = !_fullscreen;
    if (mounted) {
      setState(() {
        _fullscreen = nextFullscreen;
        _showControls = true;
      });
      if (nextFullscreen) {
        _startFullscreenStatusUpdates();
      } else {
        _stopFullscreenStatusUpdates();
      }
      _restartControlsAutoHideTimer();
    }
    if (nextFullscreen) {
      await SystemChrome.setPreferredOrientations(
        <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await _restoreSystemUi();
    }
  }

  /// 启动全屏顶部的本地时间和电量刷新；只在全屏期间每分钟读取一次以节省资源。
  void _startFullscreenStatusUpdates() {
    _stopFullscreenStatusUpdates();
    _refreshFullscreenStatus();
    _fullscreenStatusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _refreshFullscreenStatus();
    });
  }

  /// 停止全屏设备状态定时器，避免退出播放页后仍保留页面回调。
  void _stopFullscreenStatusUpdates() {
    _fullscreenStatusTimer?.cancel();
    _fullscreenStatusTimer = null;
  }

  /// 立即刷新显示时间，并异步读取 Android 提供的当前电量百分比。
  void _refreshFullscreenStatus() {
    if (!mounted || !_fullscreen) {
      return;
    }
    setState(() => _fullscreenClock = DateTime.now());
    unawaited(_refreshFullscreenBattery());
  }

  /// 读取电量后确认页面仍在全屏，再更新顶部小型状态栏的显示内容。
  Future<void> _refreshFullscreenBattery() async {
    final int? batteryPercent = await _deviceStatusService.loadBatteryPercent();
    if (!mounted || !_fullscreen) {
      return;
    }
    setState(() => _batteryPercent = batteryPercent);
  }

  /// 将当前本地时间格式化为全屏顶部状态栏使用的“时:分”文字。
  String _formatFullscreenClock() {
    return '${_fullscreenClock.hour.toString().padLeft(2, '0')}:'
        '${_fullscreenClock.minute.toString().padLeft(2, '0')}';
  }

  /// 创建全屏标题上方的小型本地状态栏，显示时间和系统可用的电量百分比。
  Widget _buildFullscreenStatusStrip() {
    final String batteryText =
        _batteryPercent == null ? '--' : '${_batteryPercent!}%';
    return SizedBox(
      key: const Key('fullscreen-device-status'),
      height: 18,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            Text(
              _formatFullscreenClock(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                height: 1,
              ),
            ),
            const Spacer(),
            const Icon(
              Icons.battery_full_rounded,
              color: Colors.white70,
              size: 13,
            ),
            const SizedBox(width: 3),
            Text(
              batteryText,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 恢复普通竖屏与 edge-to-edge 系统栏设置。
  Future<void> _restoreSystemUi() async {
    await SystemChrome.setPreferredOrientations(
      <DeviceOrientation>[DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 处理顶部返回按钮：全屏时先退出全屏，普通页面时关闭播放器。
  void _handleBackPressed() {
    if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else {
      Navigator.of(context).pop();
    }
  }

  /// 接收系统返回结果：全屏拦截成功时只退出全屏，不关闭播放页。
  void _handlePopInvoked(bool didPop) {
    if (didPop || !_fullscreen) {
      return;
    }
    unawaited(_toggleFullscreen());
  }

  /// 切换全屏弹幕按钮，并在开启后按当前播放位置读取真实的六分钟弹幕片段。
  void _toggleDanmaku() {
    final bool nextEnabled = !_danmakuEnabled;
    setState(() => _danmakuEnabled = nextEnabled);
    if (nextEnabled) {
      _failedDanmakuSegments.clear();
      _ensureDanmakuSegmentsForPosition(_playbackSnapshot.position);
    }
    _showPlayerControls();
  }

  /// 清理旧分P的弹幕内存与晚到请求，避免切P后在新视频上绘制旧视频文字。
  void _clearDanmakuForPart() {
    _danmakuRequestToken += 1;
    _danmakuSegments.clear();
    _loadingDanmakuSegments.clear();
    _failedDanmakuSegments.clear();
  }

  /// 确保当前片段存在，并在接近六分钟边界时预取下一片段减少播放中的等待。
  void _ensureDanmakuSegmentsForPosition(Duration position) {
    if (!_danmakuEnabled || _playbackSnapshot.isInPictureInPicture) {
      return;
    }
    final int currentSegment =
        DanmakuSegmentLoadResult.segmentIndexForPosition(position);
    unawaited(_loadDanmakuSegment(currentSegment));
    final int positionInSegmentMilliseconds = position.inMilliseconds %
        DanmakuSegmentLoadResult.segmentDuration.inMilliseconds;
    final int remainingMilliseconds =
        DanmakuSegmentLoadResult.segmentDuration.inMilliseconds -
            positionInSegmentMilliseconds;
    if (remainingMilliseconds <=
        _danmakuNextSegmentPreloadThreshold.inMilliseconds) {
      unawaited(_loadDanmakuSegment(currentSegment + 1));
    }
    _trimDanmakuSegments(currentSegment);
  }

  /// 请求一段真实弹幕并以片段编号缓存，失败只提示一次且不会重复刷接口。
  Future<void> _loadDanmakuSegment(int segmentIndex) async {
    if (!_danmakuEnabled ||
        segmentIndex < 1 ||
        segmentIndex > DanmakuSegmentLoadResult.maximumSegmentIndex ||
        _danmakuSegments.containsKey(segmentIndex) ||
        _loadingDanmakuSegments.contains(segmentIndex) ||
        _failedDanmakuSegments.contains(segmentIndex)) {
      return;
    }
    final int requestToken = _danmakuRequestToken;
    _loadingDanmakuSegments.add(segmentIndex);
    final DanmakuSegmentLoadResult result =
        await _playerOverlayService.loadDanmakuSegment(
      bvid: widget.video.bvid,
      cid: _currentPart.cid,
      segmentIndex: segmentIndex,
    );
    if (!mounted || requestToken != _danmakuRequestToken) {
      return;
    }
    _loadingDanmakuSegments.remove(segmentIndex);
    if (!_danmakuEnabled) {
      return;
    }
    if (result.status == DanmakuLoadStatus.unavailable) {
      _failedDanmakuSegments.add(segmentIndex);
      _showTransientSnackBar(result.message);
      return;
    }
    setState(() {
      _danmakuSegments[result.segmentIndex] = result.entries;
    });
    _trimDanmakuSegments(
      DanmakuSegmentLoadResult.segmentIndexForPosition(
        _playbackSnapshot.position,
      ),
    );
  }

  /// 仅保留当前位置前后相邻的少量弹幕片段，防止长视频连续观看时内存持续增长。
  void _trimDanmakuSegments(int currentSegment) {
    if (_danmakuSegments.length <= _maximumCachedDanmakuSegments) {
      return;
    }
    final List<int> removableSegments = _danmakuSegments.keys
        .where((int index) => (index - currentSegment).abs() > 1)
        .toList(growable: false);
    for (final int index in removableSegments) {
      _danmakuSegments.remove(index);
    }
    while (_danmakuSegments.length > _maximumCachedDanmakuSegments) {
      final int oldestIndex = _danmakuSegments.keys.reduce(
        (int left, int right) =>
            (left - currentSegment).abs() >= (right - currentSegment).abs()
                ? left
                : right,
      );
      _danmakuSegments.remove(oldestIndex);
    }
  }

  /// 返回当前六分钟片段的真实弹幕列表；未加载、为空或关闭弹幕时返回空列表。
  List<DanmakuEntry> _currentDanmakuEntries() {
    if (!_danmakuEnabled) {
      return const <DanmakuEntry>[];
    }
    final int segmentIndex = DanmakuSegmentLoadResult.segmentIndexForPosition(
      _playbackSnapshot.position,
    );
    return _danmakuSegments[segmentIndex] ?? const <DanmakuEntry>[];
  }

  /// 创建显示真实弹幕的不可点击画布，避免弹幕层阻挡控制栏和播放器手势。
  Widget _buildDanmakuOverlay() {
    if (!_danmakuEnabled || _playbackSnapshot.isInPictureInPicture) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: Padding(
          padding: EdgeInsets.only(
            top: _fullscreen ? 84 : 8,
            bottom: _showControls ? 76 : 4,
          ),
          child: RepaintBoundary(
            child: SizedBox.expand(
              child: CustomPaint(
                key: const Key('danmaku-canvas'),
                painter: _DanmakuPainter(
                  entries: _currentDanmakuEntries(),
                  position: _playbackSnapshot.position,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 清空旧分P的字幕和进行中的请求，避免切换分P后短暂显示错误字幕。
  void _clearSubtitlesForPart() {
    _subtitleRequestToken += 1;
    if (!mounted) {
      return;
    }
    setState(() {
      _subtitleTrackResult = null;
      _selectedSubtitleTrack = null;
      _subtitleCues = const <SubtitleCue>[];
      _subtitleTracksLoading = false;
      _subtitleCuesLoading = false;
    });
  }

  /// 请求当前 BV 和分P可用的字幕轨道；结果只含文字元数据，不会包含字幕地址或 Cookie。
  Future<void> _loadSubtitleTracks() async {
    final int requestToken = ++_subtitleRequestToken;
    if (mounted) {
      setState(() => _subtitleTracksLoading = true);
    }
    final SubtitleTrackLoadResult result =
        await _playerOverlayService.loadSubtitleTracks(
      bvid: widget.video.bvid,
      cid: _currentPart.cid,
    );
    if (!mounted || requestToken != _subtitleRequestToken) {
      return;
    }
    setState(() {
      _subtitleTracksLoading = false;
      _subtitleTrackResult = result;
    });
  }

  /// 打开字幕选择面板；首次点开时按需读取轨道，避免进入视频就自动下载全部字幕。
  Future<void> _showSubtitleSelector() async {
    _showPlayerControls();
    if (_subtitleTrackResult == null && !_subtitleTracksLoading) {
      await _loadSubtitleTracks();
    }
    if (!mounted) {
      return;
    }
    if (_subtitleTracksLoading) {
      _showTransientSnackBar('正在读取字幕轨道…');
      return;
    }
    final SubtitleTrackLoadResult? result = _subtitleTrackResult;
    if (result == null || result.status != SubtitleLoadStatus.available) {
      _showTransientSnackBar(result?.message ?? '字幕暂时无法读取，请稍后重试。');
      return;
    }
    final String? selectedTrackId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              const ListTile(
                title: Text('字幕'),
                subtitle: Text('字幕内容由当前视频提供，临时地址不会离开原生层。'),
              ),
              ListTile(
                leading: const Icon(Icons.subtitles_off_rounded),
                title: const Text('关闭字幕'),
                trailing: _selectedSubtitleTrack == null
                    ? const Icon(Icons.check_rounded)
                    : null,
                // 关闭字幕函数只移除本页显示内容，不修改视频或账号数据。
                onTap: () => Navigator.of(sheetContext).pop(_subtitleOffValue),
              ),
              for (final SubtitleTrack track in result.tracks)
                ListTile(
                  enabled: !track.isLocked,
                  leading: Icon(
                    track.isLocked
                        ? Icons.lock_outline_rounded
                        : Icons.subtitles_rounded,
                  ),
                  title: Text(track.label),
                  subtitle: track.language.isEmpty
                      ? (track.isLocked ? const Text('当前不可用') : null)
                      : Text(track.language),
                  trailing: _selectedSubtitleTrack?.id == track.id
                      ? const Icon(Icons.check_rounded)
                      : null,
                  // 轨道选择函数只返回不敏感编号，真正字幕地址始终保留在 Android 内存。
                  onTap: track.isLocked
                      ? null
                      : () => Navigator.of(sheetContext).pop(track.id),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || selectedTrackId == null) {
      return;
    }
    if (selectedTrackId == _subtitleOffValue) {
      _disableSubtitles();
      return;
    }
    SubtitleTrack? selectedTrack;
    for (final SubtitleTrack track in result.tracks) {
      if (track.id == selectedTrackId) {
        selectedTrack = track;
        break;
      }
    }
    if (selectedTrack != null) {
      await _selectSubtitleTrack(selectedTrack);
    }
  }

  /// 请求并启用一个用户选择的字幕轨道，失败时保留已经在显示的旧字幕。
  Future<void> _selectSubtitleTrack(SubtitleTrack track) async {
    if (track.isLocked) {
      _showTransientSnackBar('此字幕当前不可用。');
      return;
    }
    final int requestToken = ++_subtitleRequestToken;
    setState(() => _subtitleCuesLoading = true);
    final SubtitleCueLoadResult result =
        await _playerOverlayService.loadSubtitleCues(
      bvid: widget.video.bvid,
      cid: _currentPart.cid,
      trackId: track.id,
    );
    if (!mounted || requestToken != _subtitleRequestToken) {
      return;
    }
    setState(() => _subtitleCuesLoading = false);
    if (result.status != SubtitleLoadStatus.available || result.cues.isEmpty) {
      _showTransientSnackBar(result.message);
      return;
    }
    setState(() {
      _selectedSubtitleTrack = track;
      _subtitleCues = result.cues;
    });
    _showAdjustmentFeedback('字幕：${track.label}');
    _scheduleSeekFeedbackClear();
  }

  /// 关闭当前字幕显示并撤销晚到的字幕请求，不改变播放器进度或原生播放状态。
  void _disableSubtitles() {
    _subtitleRequestToken += 1;
    setState(() {
      _selectedSubtitleTrack = null;
      _subtitleCues = const <SubtitleCue>[];
      _subtitleCuesLoading = false;
    });
  }

  /// 从已经排序的字幕列表二分查找当前播放位置对应的一条字幕，避免每次状态刷新遍历全表。
  SubtitleCue? _activeSubtitleCue() {
    if (_selectedSubtitleTrack == null || _subtitleCues.isEmpty) {
      return null;
    }
    final Duration position = _playbackSnapshot.position;
    int lower = 0;
    int upper = _subtitleCues.length;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      if (_subtitleCues[middle].from <= position) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    if (lower == 0) {
      return null;
    }
    final SubtitleCue candidate = _subtitleCues[lower - 1];
    return position < candidate.to ? candidate : null;
  }

  /// 创建紧贴控制栏上方的字幕显示层，控制栏展开时自动上移而不遮挡进度条。
  Widget _buildSubtitleOverlay() {
    if (_subtitleCuesLoading && !_playbackSnapshot.isInPictureInPicture) {
      return const Positioned(
        left: 24,
        right: 24,
        bottom: 112,
        child: IgnorePointer(
          child: Center(
            child: Text(
              '正在加载字幕…',
              key: Key('subtitle-loading'),
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ),
      );
    }
    final SubtitleCue? cue = _activeSubtitleCue();
    if (cue == null || _playbackSnapshot.isInPictureInPicture) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 24,
      right: 24,
      bottom: _showControls ? 112 : 28,
      child: IgnorePointer(
        child: Semantics(
          liveRegion: true,
          label: '字幕：${cue.content}',
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.62),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Text(
                  cue.content,
                  key: const Key('active-subtitle'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.28,
                    shadows: <Shadow>[
                      Shadow(color: Colors.black, blurRadius: 3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 对尚未实现的更多设置给出明确提示，避免用户误以为设置已经生效。
  void _showPendingPlayerSetting(String setting) {
    _showAdjustmentFeedback('$setting将在后续版本实现');
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(_transientHintDuration, () {
      if (mounted) {
        setState(() => _seekFeedback = null);
      }
    });
    _restartControlsAutoHideTimer();
  }

  /// 根据菜单操作切换画面比例，或提示解码设置仍需要后续原生能力支持。
  void _handleMoreSettingsSelection(_PlayerMoreMenuAction action) {
    switch (action) {
      case _PlayerMoreMenuAction.subtitles:
        unawaited(_showSubtitleSelector());
        return;
      case _PlayerMoreMenuAction.decoderSettings:
        _showPendingPlayerSetting('解码设置');
        return;
      case _PlayerMoreMenuAction.fitContain:
        _changeVideoFitMode(_VideoFitMode.contain);
        return;
      case _PlayerMoreMenuAction.fitCover:
        _changeVideoFitMode(_VideoFitMode.cover);
        return;
      case _PlayerMoreMenuAction.fitStretch:
        _changeVideoFitMode(_VideoFitMode.stretch);
        return;
    }
  }

  /// 保存用户选择的全屏画面比例，并用三秒提示确认该设置已经只作用于渲染层。
  void _changeVideoFitMode(_VideoFitMode mode) {
    if (_videoFitMode != mode) {
      setState(() => _videoFitMode = mode);
    }
    _showAdjustmentFeedback('画面比例：${_videoFitModeLabel(mode)}');
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(_transientHintDuration, () {
      if (mounted) {
        setState(() => _seekFeedback = null);
      }
    });
    _showPlayerControls();
  }

  /// 将内部画面比例枚举转换为菜单和提示中使用的中文名称。
  String _videoFitModeLabel(_VideoFitMode mode) {
    switch (mode) {
      case _VideoFitMode.contain:
        return '适应画面';
      case _VideoFitMode.cover:
        return '填充画面';
      case _VideoFitMode.stretch:
        return '拉伸铺满';
    }
  }

  /// 构建“更多”菜单，勾选当前画面比例，并明确标注尚未接入的播放器能力。
  List<PopupMenuEntry<_PlayerMoreMenuAction>> _buildMoreSettingsMenu() {
    return <PopupMenuEntry<_PlayerMoreMenuAction>>[
      const PopupMenuItem<_PlayerMoreMenuAction>(
        value: _PlayerMoreMenuAction.decoderSettings,
        child: Text('解码设置（待实现）'),
      ),
      const PopupMenuItem<_PlayerMoreMenuAction>(
        value: _PlayerMoreMenuAction.subtitles,
        child: Row(
          children: <Widget>[
            Icon(Icons.subtitles_rounded),
            SizedBox(width: 8),
            Text('字幕'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<_PlayerMoreMenuAction>(
        enabled: false,
        child: Text('画面比例'),
      ),
      _buildVideoFitModeMenuItem(
        action: _PlayerMoreMenuAction.fitContain,
        mode: _VideoFitMode.contain,
      ),
      _buildVideoFitModeMenuItem(
        action: _PlayerMoreMenuAction.fitCover,
        mode: _VideoFitMode.cover,
      ),
      _buildVideoFitModeMenuItem(
        action: _PlayerMoreMenuAction.fitStretch,
        mode: _VideoFitMode.stretch,
      ),
    ];
  }

  /// 创建一项带勾选状态的画面比例菜单，帮助用户确认当前正在使用的模式。
  CheckedPopupMenuItem<_PlayerMoreMenuAction> _buildVideoFitModeMenuItem({
    required _PlayerMoreMenuAction action,
    required _VideoFitMode mode,
  }) {
    return CheckedPopupMenuItem<_PlayerMoreMenuAction>(
      key: Key('video-fit-mode-${mode.name}'),
      value: action,
      checked: _videoFitMode == mode,
      child: Text(_videoFitModeLabel(mode)),
    );
  }

  /// 请求 Android 原生画中画；失败时用三秒提示说明系统或播放状态限制。
  Future<void> _enterPictureInPicture() async {
    final double aspectRatio = _playbackSnapshot.videoAspectRatio > 0
        ? _playbackSnapshot.videoAspectRatio
        : 16 / 9;
    try {
      final bool entered =
          await _playbackService.enterPictureInPicture(aspectRatio);
      if (!mounted) {
        return;
      }
      if (entered) {
        _hideControls();
      } else {
        _showTransientSnackBar('无法进入画中画，请检查系统是否允许画中画。');
      }
    } on PlatformException catch (error) {
      _showTransientSnackBar(error.message ?? '当前设备暂不支持画中画。');
    } catch (_) {
      _showTransientSnackBar('无法进入画中画，请稍后重试。');
    }
  }

  /// 显示统一持续三秒的系统临时提示。
  void _showTransientSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: _transientHintDuration),
      );
  }

  /// 创建原生 Texture 视频画面：普通页面保持原有填充策略，全屏时应用用户选择的比例模式。
  Widget _buildVideoOutput() {
    final int? textureId = _textureId;
    if (textureId != null) {
      final double aspectRatio = _playbackSnapshot.videoAspectRatio > 0
          ? _playbackSnapshot.videoAspectRatio
          : 16 / 9;
      final Widget texture = RepaintBoundary(
        child: Texture(textureId: textureId),
      );
      if (_fullscreen) {
        return _buildFullscreenVideoOutput(texture, aspectRatio);
      }
      return _buildScaledVideoOutput(
        texture: texture,
        aspectRatio: aspectRatio,
        fit: BoxFit.cover,
      );
    }
    return Center(
      child: Icon(
        _playing
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        size: 86,
        color: Colors.white24,
      ),
    );
  }

  /// 按当前全屏画面比例模式返回保留黑边、裁切填充或拉伸后的 Texture 布局。
  Widget _buildFullscreenVideoOutput(Widget texture, double aspectRatio) {
    switch (_videoFitMode) {
      case _VideoFitMode.contain:
        return Center(
          child: AspectRatio(aspectRatio: aspectRatio, child: texture),
        );
      case _VideoFitMode.cover:
        return _buildScaledVideoOutput(
          texture: texture,
          aspectRatio: aspectRatio,
          fit: BoxFit.cover,
        );
      case _VideoFitMode.stretch:
        return _buildScaledVideoOutput(
          texture: texture,
          aspectRatio: aspectRatio,
          fit: BoxFit.fill,
        );
    }
  }

  /// 用指定 BoxFit 缩放 Texture：cover 会裁切，fill 会按屏幕比例拉伸。
  Widget _buildScaledVideoOutput({
    required Widget texture,
    required double aspectRatio,
    required BoxFit fit,
  }) {
    return SizedBox.expand(
      child: FittedBox(
        fit: fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: 1000 * aspectRatio,
          height: 1000,
          child: texture,
        ),
      ),
    );
  }

  /// 创建加载或错误提示；错误时允许重试，加载提示自身保持不可点击。
  Widget _buildPlaybackHint() {
    final PlaybackPhase phase = _playbackSnapshot.phase;
    final String? message = _playbackSnapshot.message;
    if (phase == PlaybackPhase.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                message ?? '无法播放此视频。',
                key: const Key('playback-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const Key('retry-playback'),
                onPressed:
                    _isRetrying ? null : () => unawaited(_retryPlayback()),
                icon: _isRetrying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded),
                label: Text(_isRetrying ? '正在重试…' : '重试播放'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (phase == PlaybackPhase.loading) {
      return IgnorePointer(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 14),
              Text(
                message ?? '正在准备播放…',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /// 创建播放器画面、手势、可点击错误重试层、控制层以及非全屏时的视频信息区域。
  @override
  Widget build(BuildContext context) {
    final bool inPictureInPicture = _playbackSnapshot.isInPictureInPicture;
    // 错误时关闭底层画面手势，避免父级单击手势抢走“重试播放”按钮的点击。
    final bool enableSurfaceGestures =
        _playbackSnapshot.phase != PlaybackPhase.error;
    final Widget player = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Listener(
          // 指针被系统取消时优先撤销预览，避免取消事件被拖动识别器当作普通松手。
          onPointerCancel: _handlePlayerPointerCancel,
          child: GestureDetector(
            key: const Key('player-surface'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            // 画面单击函数只切换控制层，避免误触导致视频暂停。
            onTap: enableSurfaceGestures ? _toggleControls : null,
            // 双击落点记录函数为分区快进快退提供位置信息。
            onDoubleTapDown:
                enableSurfaceGestures ? _recordDoubleTapPosition : null,
            // 双击处理函数依据画面宽度计算左中右分区。
            onDoubleTap: enableSurfaceGestures
                ? () => _handleDoubleTap(constraints.maxWidth)
                : null,
            // 长按开始函数仅临时切换到二倍速，横向快进由独立拖动手势负责。
            onLongPressStart:
                enableSurfaceGestures ? _startTemporaryDoubleSpeed : null,
            // 长按结束函数恢复原倍速，不改变播放位置。
            onLongPressEnd:
                enableSurfaceGestures ? _stopTemporaryDoubleSpeed : null,
            // 长按取消函数恢复界面状态且不提交未确认的进度。
            onLongPressCancel:
                enableSurfaceGestures ? _cancelTemporaryLongPress : null,
            // 横向拖动开始函数立即进入进度预览，并计算当前视频对应的拖动速度。
            onHorizontalDragStart: enableSurfaceGestures
                ? (DragStartDetails details) =>
                    _startHorizontalScrub(details, constraints.biggest)
                : null,
            // 横向拖动更新函数只刷新预览，避免频繁向原生播放器发送跳转命令。
            onHorizontalDragUpdate:
                enableSurfaceGestures ? _updateHorizontalScrub : null,
            // 横向拖动结束函数一次性提交最终目标位置。
            onHorizontalDragEnd:
                enableSurfaceGestures ? _finishHorizontalScrub : null,
            // 横向拖动取消函数恢复开始位置，避免系统手势造成误跳转。
            onHorizontalDragCancel:
                enableSurfaceGestures ? _cancelHorizontalScrub : null,
            // 竖向手势开始函数判断左侧亮度、右侧音量和上下安全区排除。
            onVerticalDragStart: enableSurfaceGestures
                ? (DragStartDetails details) => _startVerticalAdjustment(
                      details,
                      constraints.biggest,
                      MediaQuery.of(context).viewPadding.top,
                      MediaQuery.of(context).viewPadding.bottom,
                    )
                : null,
            // 竖向手势更新函数实时调整窗口亮度或媒体音量。
            onVerticalDragUpdate: enableSurfaceGestures
                ? (DragUpdateDetails details) =>
                    _updateVerticalAdjustment(details, constraints.maxHeight)
                : null,
            // 竖向手势结束函数恢复控制栏自动隐藏计时。
            onVerticalDragEnd:
                enableSurfaceGestures ? _finishVerticalAdjustment : null,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildVideoOutput(),
                  _buildDanmakuOverlay(),
                  _buildSubtitleOverlay(),
                  if (_temporaryDoubleSpeedActive)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 7,
                              ),
                              child: Text(
                                '二倍速中>>',
                                key: Key('temporary-double-speed'),
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _seekFeedback == null ? 0 : 1,
                        duration: const Duration(milliseconds: 160),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            child: Text(
                              _seekFeedback ?? '',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    left: 24,
                    right: 24,
                    bottom: _showControls ? 108 : 12,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _resumeNotice == null ? 0 : 1,
                        duration: const Duration(milliseconds: 180),
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Text(
                                _resumeNotice ?? '',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: !_showControls && !inPictureInPicture ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: LinearProgressIndicator(
                          key: const Key('mini-progress'),
                          value: _progress,
                          minHeight: 2,
                          backgroundColor: Colors.white24,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  AnimatedOpacity(
                    key: const Key('player-controls'),
                    opacity: _showControls && !inPictureInPicture ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: IgnorePointer(
                      ignoring: !_showControls || inPictureInPicture,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Colors.black54,
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black87,
                            ],
                          ),
                        ),
                        child: Stack(
                          children: <Widget>[
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              height: _fullscreen ? 92 : 64,
                              child: SafeArea(
                                key: const Key('top-player-bar'),
                                top: false,
                                bottom: false,
                                minimum: const EdgeInsets.only(
                                  top: 4,
                                  left: 4,
                                  right: 16,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    if (_fullscreen)
                                      _buildFullscreenStatusStrip(),
                                    Expanded(
                                      child: Row(
                                        children: <Widget>[
                                          IconButton(
                                            // 返回按钮函数在全屏时先退出全屏，否则关闭播放器页面。
                                            onPressed: _handleBackPressed,
                                            icon: const Icon(
                                              Icons.arrow_back_rounded,
                                              color: Colors.white,
                                            ),
                                            tooltip: '返回',
                                          ),
                                          if (_fullscreen)
                                            Expanded(
                                              child: _AutoScrollingText(
                                                text: widget.video.title,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          if (_fullscreen)
                                            IconButton(
                                              key: const Key(
                                                  'picture-in-picture'),
                                              // 画中画按钮函数调用 Android 原生小窗能力。
                                              onPressed: () => unawaited(
                                                  _enterPictureInPicture()),
                                              icon: const Icon(
                                                Icons
                                                    .picture_in_picture_alt_rounded,
                                                color: Colors.white,
                                              ),
                                              tooltip: '画中画',
                                            ),
                                          if (_fullscreen)
                                            IconButton(
                                              key: const Key('danmaku-toggle'),
                                              // 弹幕按钮函数目前只保存开关状态，真实弹幕接入已记录到 TODO.md。
                                              onPressed: _toggleDanmaku,
                                              icon: Icon(
                                                _danmakuEnabled
                                                    ? Icons.subtitles_rounded
                                                    : Icons
                                                        .subtitles_off_rounded,
                                                color: Colors.white,
                                              ),
                                              tooltip: _danmakuEnabled
                                                  ? '关闭弹幕'
                                                  : '开启弹幕',
                                            ),
                                          if (_fullscreen)
                                            PopupMenuButton<
                                                _PlayerMoreMenuAction>(
                                              key: const Key(
                                                  'more-settings-menu'),
                                              tooltip: '更多选项',
                                              icon: const Icon(
                                                Icons.more_vert_rounded,
                                                color: Colors.white,
                                              ),
                                              // 更多菜单选择函数只更新 Flutter 的本地画面布局，不改变解码或播放源。
                                              onSelected:
                                                  _handleMoreSettingsSelection,
                                              // 更多菜单构建函数提供可勾选的画面比例，并保留未接入能力的待实现说明。
                                              itemBuilder:
                                                  (BuildContext context) =>
                                                      _buildMoreSettingsMenu(),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: SafeArea(
                                top: false,
                                minimum: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 2,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 5,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                          overlayRadius: 12,
                                        ),
                                      ),
                                      child: Slider(
                                        value: _progress,
                                        // 开始拖动函数暂停自动收起，便于精确调整进度。
                                        onChangeStart: _startProgressDrag,
                                        // 进度拖动函数只更新本地显示，不频繁打断原生播放。
                                        onChanged: _updateProgressDrag,
                                        // 结束拖动函数把最终位置交给原生播放器。
                                        onChangeEnd: _finishProgressDrag,
                                      ),
                                    ),
                                    Row(
                                      children: <Widget>[
                                        IconButton(
                                          key: const Key('play-pause-button'),
                                          // 左下角播放按钮函数向原生播放器发送播放或暂停命令。
                                          onPressed: _togglePlayback,
                                          icon: Icon(
                                            _playing
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            color: Colors.white,
                                          ),
                                          tooltip: _playing ? '暂停' : '播放',
                                        ),
                                        Text(
                                          _formatProgress(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                        const Spacer(),
                                        PopupMenuButton<double>(
                                          key: const Key('speed-menu'),
                                          initialValue: _playbackSpeed,
                                          tooltip: '播放倍速',
                                          // 倍速菜单选择函数把用户选择交给原生播放器。
                                          onSelected: (double speed) =>
                                              unawaited(
                                            _changePlaybackSpeed(speed),
                                          ),
                                          // 倍速菜单构建函数生成固定且容易理解的五档速度。
                                          itemBuilder: (BuildContext context) {
                                            return _playbackSpeeds
                                                .map(
                                                  (double speed) =>
                                                      PopupMenuItem<double>(
                                                    key: Key('speed-$speed'),
                                                    value: speed,
                                                    child: Text(
                                                      _formatSpeed(speed),
                                                    ),
                                                  ),
                                                )
                                                .toList(growable: false);
                                          },
                                          child: _buildControlMenuLabel(
                                            _formatSpeed(_playbackSpeed),
                                          ),
                                        ),
                                        PopupMenuButton<int>(
                                          key: const Key('quality-menu'),
                                          initialValue: _currentQuality,
                                          tooltip: '清晰度',
                                          // 清晰度菜单选择函数保留进度后重新请求播放源。
                                          onSelected: (int quality) =>
                                              unawaited(
                                            _changeQuality(quality),
                                          ),
                                          // 清晰度菜单构建函数使用原生接口实际返回的档位。
                                          itemBuilder: (BuildContext context) {
                                            return _availableQualities
                                                .map(
                                                  (PlaybackQuality quality) =>
                                                      PopupMenuItem<int>(
                                                    key: Key(
                                                      'quality-${quality.id}',
                                                    ),
                                                    value: quality.id,
                                                    child: Text(quality.label),
                                                  ),
                                                )
                                                .toList(growable: false);
                                          },
                                          child: _buildControlMenuLabel(
                                            _currentQualityLabel(),
                                          ),
                                        ),
                                        IconButton(
                                          // 全屏按钮函数切换横屏沉浸状态。
                                          onPressed: () =>
                                              unawaited(_toggleFullscreen()),
                                          icon: Icon(
                                            _fullscreen
                                                ? Icons.fullscreen_exit_rounded
                                                : Icons.fullscreen_rounded,
                                            color: Colors.white,
                                          ),
                                          tooltip:
                                              _fullscreen ? '退出全屏' : '进入全屏',
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 错误重试层放在控制栏之后，确保按钮不会被全屏控制栏的透明区域拦截点击。
                  _buildPlaybackHint(),
                ],
              ),
            ),
          ),
        );
      },
    );

    final bool fullscreenLayout = _fullscreen || inPictureInPicture;
    final double aspectRatio = _playbackSnapshot.videoAspectRatio > 0
        ? _playbackSnapshot.videoAspectRatio
        : 16 / 9;
    final Size screenSize = MediaQuery.sizeOf(context);
    final double playerHeight = fullscreenLayout
        ? screenSize.height
        : (screenSize.width / aspectRatio)
            .clamp(180, screenSize.height * 0.62)
            .toDouble();
    final Scaffold pageScaffold = Scaffold(
      backgroundColor: fullscreenLayout ? Colors.black : null,
      body: SafeArea(
        top: !fullscreenLayout,
        left: !fullscreenLayout,
        right: !fullscreenLayout,
        bottom: false,
        child: Column(
          children: <Widget>[
            SizedBox(
              width: double.infinity,
              height: playerHeight,
              child: player,
            ),
            if (!fullscreenLayout)
              Expanded(
                child: _partSelectorExpanded
                    ? _buildExpandedPartSelector()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              widget.video.title,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text('UP主：${widget.video.ownerName}'),
                            const SizedBox(height: 6),
                            Text('BV号：${widget.video.bvid}'),
                            if (widget.video.parts.length > 1) ...<Widget>[
                              const SizedBox(height: 6),
                              Text(
                                '当前：P${_currentPart.pageNumber}  ${_currentPart.title}',
                              ),
                            ],
                            _buildPartSelector(),
                            const SizedBox(height: 18),
                            const Text(
                              '播放进度会保存在本机；最后三秒会自动视为已看完。',
                            ),
                          ],
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: !_fullscreen,
      // 系统返回函数保证全屏时先回到竖屏播放器，而不是离开视频页。
      onPopInvoked: _handlePopInvoked,
      child: pageScaffold,
    );
  }
}

/// 在固定两行高度内竖向循环标题，避免超长分P名称被横向截断。
class _PartTitleMarquee extends StatefulWidget {
  /// 创建一个会在两行内容溢出时自动竖向滚动的分P标题。
  const _PartTitleMarquee({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  /// 创建分P标题滚动组件的状态对象。
  @override
  State<_PartTitleMarquee> createState() => _PartTitleMarqueeState();
}

/// 测量两行标题的实际溢出高度，并管理竖向循环动画的生命周期。
class _PartTitleMarqueeState extends State<_PartTitleMarquee>
    with SingleTickerProviderStateMixin {
  static const double _textGap = 12;
  late final AnimationController _controller;
  double _travelDistance = 0;
  String? _animationSignature;
  bool _elementActive = true;

  /// 创建竖向标题动画控制器，只有内容超过两行时才会启动。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  /// 当标题文字或样式变化时清除旧的测量结果，等待下一帧重新判断溢出。
  @override
  void didUpdateWidget(covariant _PartTitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _stopAnimation();
    }
  }

  /// 组件重新进入树时重新允许动画在布局完成后启动。
  @override
  void activate() {
    super.activate();
    _elementActive = true;
  }

  /// 列表回收组件时停止动画，防止失活状态继续触发框架刷新。
  @override
  void deactivate() {
    _elementActive = false;
    _controller.stop();
    _animationSignature = null;
    super.deactivate();
  }

  /// 停止并清空旧动画状态，供短标题或新标题重新测量。
  void _stopAnimation() {
    _controller.stop();
    _controller.reset();
    _animationSignature = null;
    _travelDistance = 0;
  }

  /// 在布局完成后按实际竖向距离启动匀速循环，避免在 build 中直接改变动画状态。
  void _scheduleAnimation(double travelDistance) {
    final String signature = '${widget.text}:$travelDistance:${widget.style}';
    if (_animationSignature == signature) {
      return;
    }
    _animationSignature = signature;
    _travelDistance = travelDistance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_elementActive || _animationSignature != signature) {
        return;
      }
      final int milliseconds =
          (travelDistance / 18 * 1000).round().clamp(5000, 28000).toInt();
      _controller
        ..duration = Duration(milliseconds: milliseconds)
        ..repeat();
    });
  }

  /// 释放动画控制器，避免分P列表销毁后仍占用动画资源。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建静态两行标题，或构建两份文字组成的无缝竖向循环标题。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth) {
          return Text(
            widget.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final TextPainter visiblePainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 2,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        if (!visiblePainter.didExceedMaxLines) {
          if (_animationSignature != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _elementActive) {
                _stopAnimation();
              }
            });
          }
          return Text(
            widget.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final TextPainter completePainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final double travelDistance =
            completePainter.height - visiblePainter.height + _textGap;
        _scheduleAnimation(travelDistance);
        return SizedBox(
          width: constraints.maxWidth,
          height: visiblePainter.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              // 动画构建函数在两行裁剪区域内竖向移动两份完整标题，实现循环阅读。
              builder: (BuildContext context, Widget? child) {
                final double offset = _travelDistance * _controller.value;
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      top: -offset,
                      left: 0,
                      right: 0,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        child: Text(widget.text, style: widget.style),
                      ),
                    ),
                    Positioned(
                      top: completePainter.height + _textGap - offset,
                      left: 0,
                      right: 0,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        child: Text(widget.text, style: widget.style),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// 在可用宽度不足时自动横向滚动标题，短标题保持静止。
class _AutoScrollingText extends StatefulWidget {
  /// 创建一条只在溢出时启动滚动动画的单行文字。
  const _AutoScrollingText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  /// 创建自动滚动文字的动画状态。
  @override
  State<_AutoScrollingText> createState() => _AutoScrollingTextState();
}

/// 测量标题宽度并管理循环横移距离与动画生命周期。
class _AutoScrollingTextState extends State<_AutoScrollingText>
    with SingleTickerProviderStateMixin {
  static const double _textGap = 36;
  late final AnimationController _controller;
  double _travelDistance = 0;
  String? _animationSignature;
  bool _elementActive = true;

  /// 创建标题滚动动画控制器，动画只在文字溢出后才启动。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  /// 标题内容变化时重置旧动画，等待下一次布局重新测量。
  @override
  void didUpdateWidget(covariant _AutoScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _stopAnimation();
    }
  }

  /// 标题重新回到组件树时恢复活动标记，允许下一次布局重新启动动画。
  @override
  void activate() {
    super.activate();
    _elementActive = true;
  }

  /// 全屏旋转暂时移除标题时立即停止动画，防止失活组件继续触发框架重建。
  @override
  void deactivate() {
    _elementActive = false;
    _controller.stop();
    _animationSignature = null;
    super.deactivate();
  }

  /// 停止并清空当前横向滚动状态，供短标题或新标题重新计算。
  void _stopAnimation() {
    _controller.stop();
    _controller.reset();
    _animationSignature = null;
    _travelDistance = 0;
  }

  /// 在本帧布局完成后按标题长度启动匀速循环滚动。
  void _scheduleAnimation(double travelDistance) {
    final String signature = '${widget.text}:$travelDistance';
    if (_animationSignature == signature) {
      return;
    }
    _animationSignature = signature;
    _travelDistance = travelDistance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_elementActive || _animationSignature != signature) {
        return;
      }
      final int milliseconds =
          (travelDistance / 28 * 1000).round().clamp(4200, 18000).toInt();
      _controller
        ..duration = Duration(milliseconds: milliseconds)
        ..repeat();
    });
  }

  /// 释放动画控制器，避免离开全屏后继续消耗刷新资源。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 测量文字是否溢出，并构建静态标题或无缝循环的双份标题。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        if (!constraints.hasBoundedWidth ||
            painter.width <= constraints.maxWidth) {
          if (_animationSignature != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _elementActive) {
                _stopAnimation();
              }
            });
          }
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        _scheduleAnimation(painter.width + _textGap);
        return SizedBox(
          width: constraints.maxWidth,
          height: painter.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              // 动画构建函数在固定尺寸画布中移动两份标题，避免无限约束和横向溢出。
              builder: (BuildContext context, Widget? child) {
                final double offset = _travelDistance * _controller.value;
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      left: -offset,
                      top: 0,
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        style: widget.style,
                      ),
                    ),
                    Positioned(
                      left: painter.width + _textGap - offset,
                      top: 0,
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        style: widget.style,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// 在播放器画面上绘制当前时间段的真实弹幕，不参与命中测试或播放控制。
class _DanmakuPainter extends CustomPainter {
  static const Duration _scrollDisplayDuration = Duration(seconds: 8);
  static const Duration _fixedDisplayDuration = Duration(seconds: 4);
  static const double _laneHeight = 26;
  static const int _maximumVisibleEntries = 80;

  /// 创建基于播放位置重绘的弹幕画笔；传入的数据已经由原生和服务层限量校验。
  _DanmakuPainter({required this.entries, required this.position});

  final List<DanmakuEntry> entries;
  final Duration position;

  /// 逐条绘制当前可见的滚动、顶部固定和底部固定弹幕，并限制同屏最大数量。
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final int laneCount =
        (size.height / _laneHeight).floor().clamp(1, 18).toInt();
    int paintedEntries = 0;
    for (final DanmakuEntry entry in entries) {
      final Duration elapsed = position - entry.position;
      if (elapsed.isNegative) {
        continue;
      }
      final bool fixedEntry = entry.mode == 4 || entry.mode == 5;
      final Duration visibleDuration =
          fixedEntry ? _fixedDisplayDuration : _scrollDisplayDuration;
      if (elapsed > visibleDuration ||
          paintedEntries >= _maximumVisibleEntries) {
        continue;
      }
      final TextPainter textPainter = TextPainter(
        text: TextSpan(
          text: entry.content,
          style: TextStyle(
            color: _colorForEntry(entry),
            fontSize: 15,
            fontWeight: FontWeight.w600,
            shadows: const <Shadow>[
              Shadow(color: Colors.black, blurRadius: 2),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: size.width * 0.86);
      final int lane = _laneForEntry(entry, laneCount);
      final double y = _verticalOffsetForEntry(
        entry: entry,
        lane: lane,
        laneCount: laneCount,
        size: size,
        textHeight: textPainter.height,
      );
      final double x = _horizontalOffsetForEntry(
        entry: entry,
        elapsed: elapsed,
        size: size,
        textWidth: textPainter.width,
      );
      textPainter.paint(canvas, Offset(x, y));
      paintedEntries += 1;
    }
  }

  /// 根据普通滚动、反向滚动和固定模式计算横坐标，使弹幕随真实播放时间同步移动。
  double _horizontalOffsetForEntry({
    required DanmakuEntry entry,
    required Duration elapsed,
    required Size size,
    required double textWidth,
  }) {
    if (entry.mode == 4 || entry.mode == 5) {
      return (size.width - textWidth) / 2;
    }
    final double progress =
        elapsed.inMilliseconds / _scrollDisplayDuration.inMilliseconds;
    final double travelDistance = size.width + textWidth;
    if (entry.mode == 6) {
      return -textWidth + progress * travelDistance;
    }
    return size.width - progress * travelDistance;
  }

  /// 根据模式和稳定车道编号计算纵坐标，顶部与底部固定弹幕分别留在画面两端。
  double _verticalOffsetForEntry({
    required DanmakuEntry entry,
    required int lane,
    required int laneCount,
    required Size size,
    required double textHeight,
  }) {
    final double maximumTop =
        (size.height - textHeight).clamp(0, double.infinity).toDouble();
    if (entry.mode == 4) {
      return (size.height - (lane + 1) * _laneHeight)
          .clamp(0, maximumTop)
          .toDouble();
    }
    if (entry.mode == 5) {
      return (lane * _laneHeight).clamp(0, maximumTop).toDouble();
    }
    final int scrollingLane = lane % laneCount;
    return (scrollingLane * _laneHeight).clamp(0, maximumTop).toDouble();
  }

  /// 为同一条真实弹幕生成稳定车道，减少状态刷新时文字在画面中跳动。
  int _laneForEntry(DanmakuEntry entry, int laneCount) {
    final int seed =
        entry.position.inMilliseconds ~/ 100 + entry.content.hashCode;
    return seed.abs() % laneCount;
  }

  /// 把 B 站返回的 RGB 整数颜色转换为带不透明 Alpha 的 Flutter 颜色。
  Color _colorForEntry(DanmakuEntry entry) {
    return Color(0xFF000000 | (entry.color & 0xFFFFFF));
  }

  /// 只有时间轴或当前片段列表变化时才请求重绘，避免无关页面状态触发弹幕画布刷新。
  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return oldDelegate.position != position ||
        !identical(oldDelegate.entries, entries);
  }
}
