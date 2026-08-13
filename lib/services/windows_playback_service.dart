import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:volume_controller/volume_controller.dart';

import '../models/video_preview.dart';
import 'desktop_playback_source_service.dart';
import 'flutter_video_frame_capture.dart';
import 'media_cache_service.dart';
import 'native_playback_service.dart';
import 'playback_video_surface.dart';
import 'windows_dash_media_plan.dart';
import 'windows_playback_recovery_policy.dart';

/// 使用 media_kit 与 Windows 系统能力实现 FocuBili 的桌面播放接口。
class WindowsPlaybackService implements PlaybackService, PlaybackVideoSurface {
  /// 创建 Windows 播放服务并立即订阅底层播放器状态；测试可注入播放源服务。
  WindowsPlaybackService({
    BilibiliDesktopPlaybackSourceService? sourceService,
    Player? player,
  }) : _sourceService = sourceService ?? BilibiliDesktopPlaybackSourceService(),
       _player =
           player ??
           Player(
             configuration: const PlayerConfiguration(
               title: '焦点哔哩',
               bufferSize: 64 * 1024 * 1024,
             ),
           ) {
    _videoController = VideoController(_player);
    WindowsMediaCacheRuntime.registerPlaybackSession();
    _subscribeToPlayer();
  }

  static const Duration _completedResumeThreshold = Duration(seconds: 3);
  static const Duration _progressSaveInterval = Duration(seconds: 5);
  static const Duration _audioDecoderReadyTimeout = Duration(seconds: 5);
  static const Duration _mediaErrorHealthCheckTimeout = Duration(seconds: 1);
  static const Duration _resumePositionTolerance = Duration(seconds: 1);

  final BilibiliDesktopPlaybackSourceService _sourceService;
  final Player _player;
  late final VideoController _videoController;
  final FlutterVideoFrameCapture _frameCapture = FlutterVideoFrameCapture();
  final StreamController<PlaybackSnapshot> _stateController =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  VideoPreview? _currentVideo;
  VideoPart? _currentPart;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot();
  List<PlaybackQuality> _availableQualities = const <PlaybackQuality>[
    PlaybackQuality(id: 64, label: '高清 720P'),
  ];
  int _currentQuality = 64;
  Duration _restoredPosition = Duration.zero;
  DateTime? _lastProgressSavedAt;
  bool _disposed = false;
  bool _opening = false;
  bool _restoringPosition = false;
  bool _handlingMediaError = false;
  bool _cacheConfigured = false;
  bool _shouldPlayAfterFallback = true;
  int _sourceGeneration = 0;
  int _currentMediaAttemptIndex = 0;
  List<WindowsDashMediaAttempt> _mediaAttempts =
      const <WindowsDashMediaAttempt>[];
  Map<String, String> _activeMediaHeaders = const <String, String>{};
  Media? _activeAudioMedia;
  String _activeAudioTrackToken = '';
  bool _externalAudioNeedsReload = false;

  /// 返回 Windows 播放状态流，页面只读且不能直接控制底层 Player。
  @override
  Stream<PlaybackSnapshot> get states => _stateController.stream;

  /// 创建由 media_kit 管理的 GPU 视频画面，关闭其内置控制栏以复用 FocuBili 现有叠加层。
  @override
  Widget buildVideoSurface() {
    return _frameCapture.wrap(
      Video(
        key: const Key('windows-video-surface'),
        controller: _videoController,
        fit: BoxFit.fill,
        fill: Colors.black,
        controls: NoVideoControls,
        pauseUponEnteringBackgroundMode: false,
      ),
    );
  }

  /// 确认 Windows 视频控制器已经开始创建；实际画面由 buildVideoSurface 提供，因此不返回 Texture 编号。
  @override
  Future<int?> initialize() async {
    if (_disposed) {
      return null;
    }
    await _configureWindowsMediaCache();
    return _videoController.id.value;
  }

  /// 保存上一支视频进度、请求新分P的 DASH 地址，并优先使用调用方提供的安全恢复位置。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    _ensureAvailable();
    final VideoPart targetPart = part ?? video.initialPart;
    if (targetPart.cid <= 0) {
      throw ArgumentError.value(targetPart.cid, 'part.cid', '需要有效的分P编号。');
    }
    if (quality <= 0) {
      throw ArgumentError.value(quality, 'quality', '需要有效的清晰度编号。');
    }
    if (initialPosition?.isNegative ?? false) {
      throw ArgumentError.value(
        initialPosition,
        'initialPosition',
        '初始位置不能为负数。',
      );
    }
    final int generation = _beginSourceRequest();
    await _saveCurrentProgress(force: true);
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    _currentVideo = video;
    _currentPart = targetPart;
    _currentQuality = quality;
    final SavedPlaybackState? savedState = await loadSavedPlaybackState(
      video.bvid,
    );
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    _restoredPosition =
        initialPosition ??
        (savedState?.cid == targetPart.cid
            ? savedState!.position
            : Duration.zero);
    await _openCurrentSource(
      generation: generation,
      video: video,
      part: targetPart,
      quality: quality,
      resumePosition: _restoredPosition,
      shouldPlay: true,
    );
  }

  /// 继续播放当前 Windows 媒体。
  @override
  Future<void> play() async {
    _ensureAvailable();
    _shouldPlayAfterFallback = true;
    final int generation = _sourceGeneration;
    await _restartFromBeginningIfEnded();
    await _reloadExternalAudioAfterCompletion(generation);
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    await _player.play();
    if (_activeAudioMedia != null &&
        _isCurrentSourceRequest(generation) &&
        !await _waitForDecodedAudio(generation)) {
      await _handleMediaError();
    }
  }

  /// 暂停当前 Windows 媒体并立即保存恢复位置。
  @override
  Future<void> pause() async {
    _ensureAvailable();
    _shouldPlayAfterFallback = false;
    await _player.pause();
    await _saveCurrentProgress(force: true);
  }

  /// 把相对快进量加到当前位置并限制在视频有效范围内。
  @override
  Future<void> seekBy(Duration offset) async {
    _ensureAvailable();
    final Duration duration = _player.state.duration;
    int targetMilliseconds =
        _player.state.position.inMilliseconds + offset.inMilliseconds;
    targetMilliseconds = targetMilliseconds.clamp(
      0,
      duration > Duration.zero ? duration.inMilliseconds : 1 << 31,
    );
    _leaveEndedPhaseWhenSeekingBeforeEnd(
      Duration(milliseconds: targetMilliseconds),
      duration,
    );
    await _player.seek(Duration(milliseconds: targetMilliseconds));
  }

  /// 跳转到指定绝对位置，并限制负数或超过结尾的请求。
  @override
  Future<void> seekTo(Duration position) async {
    _ensureAvailable();
    final Duration duration = _player.state.duration;
    final int targetMilliseconds = position.inMilliseconds.clamp(
      0,
      duration > Duration.zero ? duration.inMilliseconds : 1 << 31,
    );
    _leaveEndedPhaseWhenSeekingBeforeEnd(
      Duration(milliseconds: targetMilliseconds),
      duration,
    );
    await _player.seek(Duration(milliseconds: targetMilliseconds));
  }

  /// 从完播状态再次点击播放时回到零点，并先广播 ready 以建立新的播放轮次。
  Future<void> _restartFromBeginningIfEnded() async {
    if (_snapshot.phase != PlaybackPhase.ended) {
      return;
    }
    await _player.seek(Duration.zero);
    _emitPlayerState(phaseOverride: PlaybackPhase.ready);
  }

  /// media_kit 会在完播时卸载外部音轨；重播前重新挂载当前 CDN 音轨，避免第二轮只剩画面。
  Future<void> _reloadExternalAudioAfterCompletion(int generation) async {
    if (!_isCurrentSourceRequest(generation) ||
        !_externalAudioNeedsReload ||
        _currentMediaAttemptIndex >= _mediaAttempts.length) {
      return;
    }
    final WindowsDashMediaAttempt attempt =
        _mediaAttempts[_currentMediaAttemptIndex];
    _activeAudioMedia = attempt.createAudioMedia(_activeMediaHeaders);
    _activeAudioTrackToken = _audioTrackTokenFor(generation);
    final AudioTrack audioTrack = attempt.createAudioTrack(
      _activeAudioMedia!,
      title: _activeAudioTrackToken,
    );
    await _player.setAudioTrack(audioTrack);
    if (_isCurrentSourceRequest(generation)) {
      _externalAudioNeedsReload = false;
    }
  }

  /// 从结尾跳回有效位置时退出 ended，让下一次真实完播能够形成新的状态边沿。
  void _leaveEndedPhaseWhenSeekingBeforeEnd(
    Duration target,
    Duration duration,
  ) {
    if (_snapshot.phase != PlaybackPhase.ended ||
        (duration > Duration.zero && target >= duration)) {
      return;
    }
    _emitPlayerState(phaseOverride: PlaybackPhase.ready);
  }

  /// 校验 0.5 到 3 倍范围并更新 Windows 播放速度。
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    _ensureAvailable();
    if (!speed.isFinite || speed < 0.5 || speed > 3) {
      throw ArgumentError.value(speed, 'speed', '倍速必须在 0.5 到 3.0 之间。');
    }
    await _player.setRate(speed);
  }

  /// 保留当前进度与播放状态，重新请求并打开用户选择的清晰度。
  @override
  Future<void> selectQuality(int quality) async {
    _ensureAvailable();
    if (quality <= 0) {
      throw ArgumentError.value(quality, 'quality', '需要有效的清晰度编号。');
    }
    if (_currentVideo == null || _currentPart == null) {
      return;
    }
    final Duration position = _player.state.position;
    final bool shouldPlay = _player.state.playing;
    final VideoPreview video = _currentVideo!;
    final VideoPart part = _currentPart!;
    final int generation = _beginSourceRequest();
    _currentQuality = quality;
    await _openCurrentSource(
      generation: generation,
      video: video,
      part: part,
      quality: quality,
      resumePosition: position,
      shouldPlay: shouldPlay,
    );
  }

  /// 从 Windows 本机偏好读取该视频最后分P和位置，接近结尾时从头开始。
  @override
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? encoded = preferences.getString(_progressKey(bvid));
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        return null;
      }
      final int cid = (decoded['cid'] as num?)?.toInt() ?? 0;
      final int pageNumber = (decoded['pageNumber'] as num?)?.toInt() ?? 0;
      final int positionMs = (decoded['positionMs'] as num?)?.toInt() ?? 0;
      if (cid <= 0 || pageNumber <= 0 || positionMs < 0) {
        return null;
      }
      return SavedPlaybackState(
        cid: cid,
        pageNumber: pageNumber,
        position: Duration(milliseconds: positionMs),
      );
    } on FormatException {
      return null;
    }
  }

  /// 读取 Windows 应用亮度与系统媒体音量；插件不可用时返回安全中间值。
  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async {
    double brightness = 0.5;
    double volume = 0.5;
    try {
      brightness = await ScreenBrightness.instance.application;
    } catch (_) {
      brightness = 0.5;
    }
    try {
      volume = await VolumeController.instance.getVolume();
    } catch (_) {
      volume = 0.5;
    }
    return SystemPlaybackLevels(
      brightness: brightness.clamp(0.01, 1).toDouble(),
      volume: volume.clamp(0, 1).toDouble(),
    );
  }

  /// 调整当前 FocuBili 窗口亮度，不修改 Windows 的全局显示器设置。
  @override
  Future<void> setScreenBrightness(double brightness) {
    _ensureAvailable();
    return ScreenBrightness.instance.setApplicationScreenBrightness(
      brightness.clamp(0.01, 1).toDouble(),
    );
  }

  /// 调整 Windows 系统媒体音量，并隐藏移动端专用的系统音量浮层请求。
  @override
  Future<void> setMediaVolume(double volume) {
    _ensureAvailable();
    VolumeController.instance.showSystemUI = false;
    return VolumeController.instance.setVolume(volume.clamp(0, 1).toDouble());
  }

  /// Windows 小窗模式将在窗口管理阶段实现；当前明确返回不支持，避免伪造成功状态。
  @override
  Future<bool> enterPictureInPicture(double aspectRatio) async {
    _ensureAvailable();
    return false;
  }

  /// 从 Flutter 已绘制的视频画面读取 PNG，绕开可能直接终止进程的 libmpv 原生截图。
  @override
  Future<String?> captureCurrentFrame() async {
    _ensureAvailable();
    final List<int>? bytes = await _frameCapture.capturePngBytes();
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final Directory frameDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}video_frames',
    );
    await frameDirectory.create(recursive: true);
    final File output = File(
      '${frameDirectory.path}${Platform.pathSeparator}'
      'frame_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await output.writeAsBytes(bytes, flush: true);
    return output.path;
  }

  /// 保存最后进度、释放 media_kit 与全部订阅，并恢复应用窗口默认亮度。
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    try {
      try {
        await _saveCurrentProgress(force: true);
      } catch (_) {
        // 偏好设置写入失败不能阻止播放器、磁盘缓冲句柄和活跃会话标记释放。
      }
      _disposed = true;
      for (final StreamSubscription<dynamic> subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      try {
        await ScreenBrightness.instance.resetApplicationScreenBrightness();
      } catch (_) {
        // Windows 亮度插件不可用时无需阻塞播放器资源释放。
      }
      await _player.dispose();
    } finally {
      _activeAudioMedia = null;
      WindowsMediaCacheRuntime.unregisterPlaybackSession();
      if (!_stateController.isClosed) {
        await _stateController.close();
      }
    }
  }

  /// 把用户选择的 Windows 缓冲目录和容量交给 libmpv；配置失败时仍允许纯内存播放。
  Future<void> _configureWindowsMediaCache() async {
    if (_cacheConfigured || _disposed) {
      return;
    }
    _cacheConfigured = true;
    final PlatformPlayer? platformPlayer = _player.platform;
    if (platformPlayer is! NativePlayer) {
      return;
    }
    try {
      final WindowsMediaCacheService cacheService = WindowsMediaCacheService();
      final Directory directory = await cacheService.resolveCacheDirectory();
      final int capacityBytes = await cacheService.loadCapacityBytes();
      await platformPlayer.setProperty('cache', 'yes');
      await platformPlayer.setProperty('cache-on-disk', 'yes');
      await platformPlayer.setProperty('cache-dir', directory.path);
      await platformPlayer.setProperty(
        'demuxer-max-bytes',
        capacityBytes.toString(),
      );
      await platformPlayer.setProperty(
        'demuxer-max-back-bytes',
        capacityBytes.toString(),
      );
    } catch (_) {
      // 应用缓存目录或偏好设置异常时保留 media_kit 默认内存缓冲，不能阻止视频播放。
    }
  }

  /// 订阅底层播放、缓冲、进度、尺寸、结束和错误事件，并统一转换为页面快照。
  void _subscribeToPlayer() {
    _subscriptions
      ..add(_player.stream.playing.listen((bool _) => _emitPlayerState()))
      ..add(
        _player.stream.position.listen((Duration _) {
          _emitPlayerState();
          unawaited(_saveCurrentProgress());
        }),
      )
      ..add(_player.stream.duration.listen((Duration _) => _emitPlayerState()))
      ..add(_player.stream.rate.listen((double _) => _emitPlayerState()))
      ..add(_player.stream.buffering.listen((bool _) => _emitPlayerState()))
      ..add(_player.stream.width.listen((int? _) => _emitPlayerState()))
      ..add(_player.stream.height.listen((int? _) => _emitPlayerState()))
      ..add(
        _player.stream.completed.listen((bool completed) {
          if (completed) {
            _externalAudioNeedsReload = _activeAudioMedia != null;
            _emitPlayerState(phaseOverride: PlaybackPhase.ended);
            unawaited(_saveCurrentProgress(force: true));
          } else if (_snapshot.phase == PlaybackPhase.ended) {
            // libmpv 在重播或从结尾跳走时会撤销 completed；此时必须形成离开 ended 的新边沿。
            _emitPlayerState(phaseOverride: PlaybackPhase.ready);
          }
        }),
      )
      ..add(
        _player.stream.error.listen((String _) {
          // 错误正文可能含临时 CDN 地址，因此不写日志也不直接交给页面。
          unawaited(
            _verifyPlayerError(
              generation: _sourceGeneration,
              mediaAttemptIndex: _currentMediaAttemptIndex,
            ),
          );
        }),
      );
  }

  /// 请求当前视频的播放源、载入外部音轨，并按调用前状态恢复进度和播放开关。
  Future<void> _openCurrentSource({
    required int generation,
    required VideoPreview video,
    required VideoPart part,
    required int quality,
    required Duration resumePosition,
    required bool shouldPlay,
  }) async {
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    _opening = true;
    _restoringPosition = resumePosition > Duration.zero;
    _emitPlayerState(
      phaseOverride: PlaybackPhase.loading,
      message: resumePosition > Duration.zero ? '正在恢复上次播放位置…' : '正在请求播放数据…',
    );
    try {
      final DesktopPlaybackSources sources = await _sourceService.load(
        bvid: video.bvid,
        cid: part.cid,
        quality: quality,
      );
      if (!_isCurrentSourceRequest(generation)) {
        return;
      }
      _availableQualities = sources.qualities;
      _currentQuality = sources.actualQuality;
      _currentMediaAttemptIndex = 0;
      _mediaAttempts = WindowsDashMediaPlan.build(sources);
      _activeMediaHeaders = sources.mediaHeaders;
      _shouldPlayAfterFallback = shouldPlay;
      if (_mediaAttempts.isEmpty) {
        throw const DesktopPlaybackSourceException('播放数据没有返回安全的媒体地址。');
      }
      await _openFirstAvailableMedia(
        generation: generation,
        resumePosition: resumePosition,
        shouldPlay: shouldPlay,
      );
      if (!_isCurrentSourceRequest(generation)) {
        return;
      }
      _opening = false;
      _restoringPosition = false;
      _emitPlayerState(phaseOverride: PlaybackPhase.ready, clearMessage: true);
    } catch (error) {
      if (!_isCurrentSourceRequest(generation)) {
        return;
      }
      _opening = false;
      _restoringPosition = false;
      final String message = error is DesktopPlaybackSourceException
          ? error.message
          : 'Windows 播放器暂时无法打开该视频，请重试。';
      _emitPlayerState(phaseOverride: PlaybackPhase.error, message: message);
      rethrow;
    }
  }

  /// 首次打开播放源时同步轮换全部主备组合，避免第一条 CDN 失效就直接结束加载。
  Future<void> _openFirstAvailableMedia({
    required int generation,
    required Duration resumePosition,
    required bool shouldPlay,
  }) async {
    while (_isCurrentSourceRequest(generation) &&
        _currentMediaAttemptIndex < _mediaAttempts.length) {
      try {
        await _openMediaAttempt(
          _mediaAttempts[_currentMediaAttemptIndex],
          generation: generation,
          resumePosition: resumePosition,
          shouldPlay: shouldPlay,
        );
        return;
      } catch (_) {
        if (!_isCurrentSourceRequest(generation)) {
          return;
        }
        if (_currentMediaAttemptIndex + 1 >= _mediaAttempts.length) {
          throw const DesktopPlaybackSourceException('主线路和备用线路均无法播放，请稍后重试。');
        }
        _currentMediaAttemptIndex += 1;
        _emitPlayerState(
          phaseOverride: PlaybackPhase.loading,
          message: '当前播放线路不可用，正在切换备用线路…',
        );
      }
    }
    throw const DesktopPlaybackSourceException('播放数据没有返回安全的媒体地址。');
  }

  /// 打开一组视频和外部音频地址，先暂停并恢复位置，再挂载音轨和恢复用户原来的播放状态。
  Future<void> _openMediaAttempt(
    WindowsDashMediaAttempt attempt, {
    required int generation,
    required Duration resumePosition,
    required bool shouldPlay,
  }) async {
    // 保留音频 Media 的强引用，避免 media_kit 的请求头缓存被垃圾回收清掉。
    _activeAudioMedia = attempt.createAudioMedia(_activeMediaHeaders);
    _activeAudioTrackToken = _audioTrackTokenFor(generation);
    final AudioTrack audioTrack = attempt.createAudioTrack(
      _activeAudioMedia!,
      title: _activeAudioTrackToken,
    );
    // 显式暂停旧媒体，避免新视频准备期间沿用上一条线路的播放状态。
    await _player.pause();
    await _player.open(
      attempt.createVideoMedia(_activeMediaHeaders),
      play: false,
    );
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    if (resumePosition > Duration.zero) {
      // 视频一打开就先定位，不能让较慢的外部音轨挂载把历史跳转拖到数秒之后。
      await _player.seek(resumePosition);
      if (!_isCurrentSourceRequest(generation)) {
        return;
      }
      _restoringPosition = false;
      _emitPlayerState(
        phaseOverride: PlaybackPhase.loading,
        message: '正在准备音视频…',
      );
    }
    await _player.setAudioTrack(audioTrack);
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    // 外部音轨挂载可能改变底层时间轴；保持暂停并只在发生明显偏移时补一次跳转。
    await _player.pause();
    if (_needsResumePositionCorrection(resumePosition)) {
      await _player.seek(resumePosition);
    }
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    if (shouldPlay) {
      await _player.play();
    } else {
      await _player.pause();
    }
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    // media_kit 的命令返回只代表已接收；实际播放时还要等音视频解码都建立，避免把残缺线路当成功。
    if (shouldPlay && !await _waitForDecodedAudio(generation)) {
      throw const DesktopPlaybackSourceException('当前音视频线路未能建立解码。');
    }
    _externalAudioNeedsReload = false;
  }

  /// 判断外部音轨挂载后是否偏离目标历史位置，允许一秒内的播放器取整误差。
  bool _needsResumePositionCorrection(Duration resumePosition) {
    if (resumePosition <= Duration.zero) {
      return false;
    }
    final int differenceMilliseconds =
        (_player.state.position.inMilliseconds - resumePosition.inMilliseconds)
            .abs();
    return differenceMilliseconds > _resumePositionTolerance.inMilliseconds;
  }

  /// 等待 media_kit 暴露当前线路的音视频解码结果；零散底层错误只作为线索，不抢先否定已成功的播放。
  Future<bool> _waitForDecodedAudio(int generation) async {
    final DateTime deadline = DateTime.now().add(_audioDecoderReadyTimeout);
    while (_isCurrentSourceRequest(generation) &&
        DateTime.now().isBefore(deadline)) {
      if (_hasDecodedVideo() && await _hasDecodedAudio()) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _isCurrentSourceRequest(generation) &&
        _hasDecodedVideo() &&
        await _hasDecodedAudio();
  }

  /// 判断当前视频轨是否已经建立真实解码输出，避免只凭容器时长把纯音频或损坏视频当作成功。
  bool _hasDecodedVideo() {
    final VideoParams params = _player.state.videoParams;
    final bool hasPixelFormat = params.pixelformat?.trim().isNotEmpty ?? false;
    final bool hasDimensions =
        (params.w ?? _player.state.width ?? 0) > 0 &&
        (params.h ?? _player.state.height ?? 0) > 0;
    return hasPixelFormat && hasDimensions;
  }

  /// 核对 libmpv 当前选中的外部音轨标记，并用公开音频参数确认当前线路已经产生解码输出。
  Future<bool> _hasDecodedAudio() async {
    final AudioParams params = _player.state.audioParams;
    final PlatformPlayer? platformPlayer = _player.platform;
    if (platformPlayer is NativePlayer) {
      try {
        final String activeTitle = await platformPlayer.getProperty(
          'current-tracks/audio/title',
        );
        final String isExternal = await platformPlayer.getProperty(
          'current-tracks/audio/external',
        );
        final String isSelected = await platformPlayer.getProperty(
          'current-tracks/audio/selected',
        );
        return _activeAudioTrackToken.isNotEmpty &&
            activeTitle == _activeAudioTrackToken &&
            _isMpvTrue(isExternal) &&
            _isMpvTrue(isSelected) &&
            _hasAudioOutput(params);
      } catch (_) {
        return false;
      }
    }
    return _hasAudioOutput(params);
  }

  /// 判断 media_kit 是否已经收到解码器输出的有效音频格式和声道，避免依赖更新时机不稳定的单个原生属性。
  bool _hasAudioOutput(AudioParams params) {
    return (params.format?.trim().isNotEmpty ?? false) &&
        (params.channelCount ?? 0) > 0;
  }

  /// 生成只在当前播放源和当前线路组合中使用的内部音轨标题，避免旧音轨状态被误认成新音轨。
  String _audioTrackTokenFor(int generation) {
    return 'FocuBili audio $generation:$_currentMediaAttemptIndex';
  }

  /// 兼容 libmpv 布尔属性可能返回的 yes、true 或 1 文本。
  static bool _isMpvTrue(String value) {
    final String normalized = value.trim().toLowerCase();
    return normalized == 'yes' || normalized == 'true' || normalized == '1';
  }

  /// 延迟核验 media_kit 的宽泛错误事件；当前音视频仍健康时忽略它，只有确认失效才轮换线路。
  Future<void> _verifyPlayerError({
    required int generation,
    required int mediaAttemptIndex,
  }) async {
    if (!_isCurrentMediaAttempt(generation, mediaAttemptIndex) || _opening) {
      return;
    }
    final DateTime deadline = DateTime.now().add(_mediaErrorHealthCheckTimeout);
    do {
      final bool hasDecodedAudio = await _hasDecodedAudio();
      if (!_isCurrentMediaAttempt(generation, mediaAttemptIndex) || _opening) {
        return;
      }
      final bool shouldSwitch =
          WindowsPlaybackRecoveryPolicy.shouldSwitchAfterPlayerError(
            isOpening: _opening,
            isBuffering: _player.state.buffering,
            hasVideoOutput: _hasDecodedVideo(),
            hasDecodedAudio: hasDecodedAudio,
          );
      if (!shouldSwitch) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    if (!_isCurrentMediaAttempt(generation, mediaAttemptIndex) || _opening) {
      return;
    }
    await _handleMediaError(
      expectedGeneration: generation,
      expectedMediaAttemptIndex: mediaAttemptIndex,
    );
  }

  /// 收到媒体错误时依次切换剩余主备 CDN，并仅在全部线路失败后展示错误状态。
  Future<void> _handleMediaError({
    int? expectedGeneration,
    int? expectedMediaAttemptIndex,
  }) async {
    if (_disposed || _handlingMediaError) {
      return;
    }
    if (expectedGeneration != null &&
        expectedMediaAttemptIndex != null &&
        !_isCurrentMediaAttempt(
          expectedGeneration,
          expectedMediaAttemptIndex,
        )) {
      return;
    }
    if (_mediaAttempts.isEmpty ||
        _currentMediaAttemptIndex + 1 >= _mediaAttempts.length) {
      _opening = false;
      _emitPlayerState(
        phaseOverride: PlaybackPhase.error,
        message: 'Windows 播放器遇到媒体错误，请重试或切换清晰度。',
      );
      return;
    }
    _handlingMediaError = true;
    final int generation = _sourceGeneration;
    final Duration resumePosition = _player.state.position;
    final bool shouldPlay = _player.state.playing || _shouldPlayAfterFallback;
    _opening = true;
    _emitPlayerState(
      phaseOverride: PlaybackPhase.loading,
      message: '当前播放线路不可用，正在切换备用线路…',
    );
    try {
      while (!_disposed &&
          generation == _sourceGeneration &&
          _currentMediaAttemptIndex + 1 < _mediaAttempts.length) {
        _currentMediaAttemptIndex += 1;
        try {
          await _openMediaAttempt(
            _mediaAttempts[_currentMediaAttemptIndex],
            generation: generation,
            resumePosition: resumePosition,
            shouldPlay: shouldPlay,
          );
          if (_disposed || generation != _sourceGeneration) {
            return;
          }
          _opening = false;
          _emitPlayerState(
            phaseOverride: PlaybackPhase.ready,
            clearMessage: true,
          );
          return;
        } catch (_) {
          // 当前组合同步打开失败时继续下一组，异常中可能含临时地址，因此保持静默。
        }
      }
      if (!_disposed && generation == _sourceGeneration) {
        _opening = false;
        _emitPlayerState(
          phaseOverride: PlaybackPhase.error,
          message: '主线路和备用线路均无法播放，请重试或切换清晰度。',
        );
      }
    } finally {
      _handlingMediaError = false;
    }
  }

  /// 开始新的播放源请求并让先前仍在等待网络的分P或清晰度请求立即失效。
  int _beginSourceRequest() {
    _sourceGeneration += 1;
    _restoringPosition = false;
    _activeAudioTrackToken = '';
    _externalAudioNeedsReload = false;
    return _sourceGeneration;
  }

  /// 判断异步播放源结果是否仍属于用户最后一次选择，避免旧分P覆盖新分P。
  bool _isCurrentSourceRequest(int generation) {
    return !_disposed && generation == _sourceGeneration;
  }

  /// 同时核对播放源代次和线路序号，阻止旧错误的延迟核验切换已经成功的新线路。
  bool _isCurrentMediaAttempt(int generation, int mediaAttemptIndex) {
    return _isCurrentSourceRequest(generation) &&
        mediaAttemptIndex == _currentMediaAttemptIndex;
  }

  /// 把 media_kit 即时状态转换为项目统一快照，并计算稳定视频宽高比。
  void _emitPlayerState({
    PlaybackPhase? phaseOverride,
    String? message,
    bool clearMessage = false,
  }) {
    if (_disposed || _stateController.isClosed) {
      return;
    }
    final int width = _player.state.width ?? 0;
    final int height = _player.state.height ?? 0;
    PlaybackPhase phase = phaseOverride ?? _snapshot.phase;
    if (phaseOverride == null && phase != PlaybackPhase.ended) {
      if (_opening || _player.state.buffering) {
        phase = PlaybackPhase.loading;
      } else if (_player.state.duration > Duration.zero || width > 0) {
        phase = PlaybackPhase.ready;
      }
    }
    _snapshot = PlaybackSnapshot(
      phase: phase,
      isPlaying: _player.state.playing,
      position: _player.state.position,
      duration: _player.state.duration,
      speed: _player.state.rate,
      currentQuality: _currentQuality,
      availableQualities: _availableQualities,
      videoAspectRatio: width > 0 && height > 0 ? width / height : 16 / 9,
      restoredPosition: _restoredPosition,
      isRestoringPosition: _restoringPosition,
      message: clearMessage ? null : (message ?? _snapshot.message),
    );
    _stateController.add(_snapshot);
  }

  /// 按固定间隔把当前分P与位置写入偏好；离开、暂停和切换时可强制立即保存。
  Future<void> _saveCurrentProgress({bool force = false}) async {
    if (_disposed || _currentVideo == null || _currentPart == null) {
      return;
    }
    final DateTime now = DateTime.now();
    if (!force &&
        _lastProgressSavedAt != null &&
        now.difference(_lastProgressSavedAt!) < _progressSaveInterval) {
      return;
    }
    _lastProgressSavedAt = now;
    Duration position = _player.state.position;
    final Duration duration = _player.state.duration;
    if (duration > Duration.zero &&
        duration - position <= _completedResumeThreshold) {
      position = Duration.zero;
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _progressKey(_currentVideo!.bvid),
      jsonEncode(<String, int>{
        'cid': _currentPart!.cid,
        'pageNumber': _currentPart!.pageNumber,
        'positionMs': position.inMilliseconds.clamp(0, 1 << 31),
      }),
    );
  }

  /// 为单支 BV 视频生成不会与 Android 原生偏好冲突的 Windows 恢复键。
  String _progressKey(String bvid) {
    return 'windows_playback_state_${bvid.trim().toUpperCase()}';
  }

  /// 在服务已释放后阻止晚到的页面操作继续访问底层播放器。
  void _ensureAvailable() {
    if (_disposed) {
      throw StateError('Windows 播放器已经释放。');
    }
  }
}
