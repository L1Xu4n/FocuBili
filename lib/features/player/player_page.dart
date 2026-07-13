import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/video_preview.dart';
import '../../services/native_playback_service.dart';

/// 标识一次竖向滑动正在调整亮度、音量，或因底部手势区而不做处理。
enum _VerticalAdjustmentMode { none, brightness, volume }

/// 新架构的原生播放器页面，提供简洁的 App 风格控制层。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.video, this.playbackService});

  final VideoPreview video;
  final PlaybackService? playbackService;

  /// 创建播放器状态，保存播放、进度、控制层和全屏状态。
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 管理原生视频纹理、播放状态、手势、控制层和系统全屏状态。
class _PlayerPageState extends State<PlayerPage> {
  static const Duration _controlsAutoHideDelay = Duration(seconds: 5);
  static const Duration _transientHintDuration = Duration(seconds: 3);
  static const Duration _resumeNoticeDuration = _transientHintDuration;
  static const double _fullscreenGestureExclusionHeight = 72;
  static const double _expandedPartItemHeight = 76;
  static const List<double> _playbackSpeeds = <double>[
    0.75,
    1,
    1.25,
    1.5,
    2,
  ];

  late final PlaybackService _playbackService;
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
  double _playbackSpeed = 1;
  int _currentQuality = 64;
  int? _pendingQualitySelection;
  List<PlaybackQuality> _availableQualities = const <PlaybackQuality>[
    PlaybackQuality(id: 64, label: '高清 720P'),
  ];
  bool _partSelectorExpanded = false;
  bool _partsAscending = true;
  bool _danmakuEnabled = false;
  bool _temporaryDoubleSpeedActive = false;
  double _speedBeforeLongPress = 1;
  int? _shownRestoredCid;
  double _brightness = 0.5;
  double _volume = 0.5;
  double _verticalGestureStartLevel = 0.5;
  double _verticalGestureDelta = 0;
  _VerticalAdjustmentMode _verticalAdjustmentMode =
      _VerticalAdjustmentMode.none;

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

  /// 把 Android 推送的播放状态写入页面，并在非拖动状态下同步真实进度。
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
      if (!_isDraggingProgress && snapshot.duration > Duration.zero) {
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
    if (_showControls &&
        !snapshot.isInPictureInPicture &&
        _controlsTimer == null) {
      _restartControlsAutoHideTimer();
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

  /// 离开页面前取消订阅和计时器、释放原生资源并恢复竖屏与系统栏。
  @override
  void dispose() {
    _controlsTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _resumeNoticeTimer?.cancel();
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
    if (!_showControls) {
      return;
    }
    _controlsTimer = Timer(_controlsAutoHideDelay, () {
      if (mounted) {
        setState(() {
          _showControls = false;
          _controlsTimer = null;
        });
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

  /// 长按正在播放的画面时记住原倍速，并临时切换到二倍速。
  void _startTemporaryDoubleSpeed(LongPressStartDetails details) {
    if (!_playing || _temporaryDoubleSpeedActive) {
      return;
    }
    _speedBeforeLongPress = _playbackSpeed;
    setState(() => _temporaryDoubleSpeedActive = true);
    unawaited(_setTemporaryPlaybackSpeed(2));
  }

  /// 松开长按手势后恢复用户此前选择的播放倍速。
  void _stopTemporaryDoubleSpeed(LongPressEndDetails details) {
    if (!_temporaryDoubleSpeedActive) {
      return;
    }
    final double speedToRestore = _speedBeforeLongPress;
    setState(() => _temporaryDoubleSpeedActive = false);
    unawaited(_setTemporaryPlaybackSpeed(speedToRestore));
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

  /// 保存旧分P进度后打开新分P；原生层会自动读取新分P的历史位置。
  Future<void> _changePart(VideoPart part) async {
    if (part.cid == _currentPart.cid) {
      return;
    }
    setState(() {
      _currentPart = part;
      _progress = 0;
      _showControls = true;
      _resumeNotice = null;
    });
    _shownRestoredCid = null;
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

  /// 根据手指起点选择左侧亮度或右侧音量，并避开全屏底部系统手势区。
  void _startVerticalAdjustment(
    DragStartDetails details,
    Size playerSize,
    double bottomSystemInset,
  ) {
    final double excludedHeight =
        (_fullscreenGestureExclusionHeight + bottomSystemInset)
            .clamp(0, playerSize.height)
            .toDouble();
    if (_fullscreen &&
        details.localPosition.dy >= playerSize.height - excludedHeight) {
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

  /// 创建两行分P卡片，标题过长时在折叠与展开列表中都会自动滚动。
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
                child: _AutoScrollingText(
                  text: part.title,
                  style: TextStyle(
                    color: selected ? colors.onPrimaryContainer : null,
                    fontSize: compact ? 13 : 14,
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

  /// 切换全屏弹幕按钮的视觉状态；实际弹幕数据接入记录在 TODO.md。
  void _toggleDanmaku() {
    setState(() => _danmakuEnabled = !_danmakuEnabled);
    _showPlayerControls();
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

  /// 创建原生 Texture 视频画面：普通页面按宽度铺满，全屏时保持比例并居中。
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
        return Center(
          child: AspectRatio(aspectRatio: aspectRatio, child: texture),
        );
      }
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: 1000 * aspectRatio,
            height: 1000,
            child: texture,
          ),
        ),
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

  /// 创建加载或错误提示，确保播放数据变化和权限限制不会只留下黑屏。
  Widget _buildPlaybackHint() {
    final PlaybackPhase phase = _playbackSnapshot.phase;
    final String? message = _playbackSnapshot.message;
    if (phase == PlaybackPhase.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            message ?? '无法播放此视频。',
            key: const Key('playback-error'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    if (phase == PlaybackPhase.loading) {
      return Center(
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
      );
    }
    return const SizedBox.shrink();
  }

  /// 创建播放器画面、手势、控制层以及非全屏时的视频信息区域。
  @override
  Widget build(BuildContext context) {
    final bool inPictureInPicture = _playbackSnapshot.isInPictureInPicture;
    final Widget player = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return GestureDetector(
          key: const Key('player-surface'),
          behavior: HitTestBehavior.opaque,
          // 画面单击函数只切换控制层，避免误触导致视频暂停。
          onTap: _toggleControls,
          // 双击落点记录函数为分区快进快退提供位置信息。
          onDoubleTapDown: _recordDoubleTapPosition,
          // 双击处理函数依据画面宽度计算左中右分区。
          onDoubleTap: () => _handleDoubleTap(constraints.maxWidth),
          // 长按开始函数只在正在播放时临时切换到二倍速。
          onLongPressStart: _startTemporaryDoubleSpeed,
          // 长按结束函数恢复用户原先选择的播放倍速。
          onLongPressEnd: _stopTemporaryDoubleSpeed,
          // 竖向手势开始函数判断左侧亮度、右侧音量和底部排除区。
          onVerticalDragStart: (DragStartDetails details) =>
              _startVerticalAdjustment(
            details,
            constraints.biggest,
            MediaQuery.of(context).viewPadding.bottom,
          ),
          // 竖向手势更新函数实时调整窗口亮度或媒体音量。
          onVerticalDragUpdate: (DragUpdateDetails details) =>
              _updateVerticalAdjustment(details, constraints.maxHeight),
          // 竖向手势结束函数恢复控制栏自动隐藏计时。
          onVerticalDragEnd: _finishVerticalAdjustment,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildVideoOutput(),
                IgnorePointer(child: _buildPlaybackHint()),
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
                            height: 64,
                            child: SafeArea(
                              key: const Key('top-player-bar'),
                              top: false,
                              bottom: false,
                              minimum: const EdgeInsets.only(
                                top: 8,
                                left: 4,
                                right: 16,
                              ),
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
                                      key: const Key('picture-in-picture'),
                                      // 画中画按钮函数调用 Android 原生小窗能力。
                                      onPressed: () =>
                                          unawaited(_enterPictureInPicture()),
                                      icon: const Icon(
                                        Icons.picture_in_picture_alt_rounded,
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
                                            : Icons.subtitles_off_rounded,
                                        color: Colors.white,
                                      ),
                                      tooltip:
                                          _danmakuEnabled ? '关闭弹幕' : '开启弹幕',
                                    ),
                                  if (_fullscreen)
                                    PopupMenuButton<String>(
                                      key: const Key('more-settings-menu'),
                                      tooltip: '更多选项',
                                      icon: const Icon(
                                        Icons.more_vert_rounded,
                                        color: Colors.white,
                                      ),
                                      // 更多菜单选择函数提示该设置仍在规划中。
                                      onSelected: _showPendingPlayerSetting,
                                      // 更多菜单构建函数先放置视频设置和画面比例入口。
                                      itemBuilder: (BuildContext context) =>
                                          const <PopupMenuEntry<String>>[
                                        PopupMenuItem<String>(
                                          value: '视频设置',
                                          child: Text('视频设置（待实现）'),
                                        ),
                                        PopupMenuItem<String>(
                                          value: '画面比例设置',
                                          child: Text('画面比例（待实现）'),
                                        ),
                                      ],
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
                                        onSelected: (double speed) => unawaited(
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
                                        onSelected: (int quality) => unawaited(
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
                                        tooltip: _fullscreen ? '退出全屏' : '进入全屏',
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
              ],
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
