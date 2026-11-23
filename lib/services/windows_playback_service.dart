import 'bilibili_auth_service.dart';
import 'playback_preferences_service.dart';
import 'dart:async';
import 'dart:io';
import 'apple_playback_session.dart';
import 'linux_media_session.dart';
import 'linux_mini_player.dart';
import 'apple_video_capabilities.dart';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:volume_controller/volume_controller.dart';

import '../models/video_preview.dart';
import '../platform/app_platform.dart';
import 'desktop_playback_source_service.dart';
import 'flutter_video_frame_capture.dart';
import 'live_video_frame_playback_service.dart';
import 'media_cache_service.dart';
import 'desktop_disk_cache_session.dart';
import 'native_playback_service.dart';
import 'local_file_playback_service.dart';
import 'listening_playback_service.dart';
import 'playback_video_surface.dart';
import 'video_shot_service.dart';
import 'windows_dash_media_plan.dart';
import 'windows_playback_recovery_policy.dart';
import 'windows_playback_progress_store.dart';
import 'cache_lifecycle.dart';
import 'course_cache_playback_guard.dart';
import 'course_cache_library.dart';
import 'bilibili_wbi_signing_service.dart';

/// 使用 media_kit 与 Windows 系统能力实现 FocuBili 的桌面播放接口。
class WindowsPlaybackService
    implements
        PlaybackService,
        PlaybackVideoSurface,
        LiveVideoFramePlaybackService,
        ListeningPlaybackService,
        LocalTrackPlaybackService {
  /// 创建 Windows 播放服务并立即订阅底层播放器状态；测试可注入播放源服务。
  WindowsPlaybackService({
    BilibiliDesktopPlaybackSourceService? sourceService,
    BilibiliVideoShotService? videoShotService,
    Player? player,
    WindowsPlaybackProgressStore? progressStore,
    Future<String> Function()? bufferStateReader,
    this.courseCacheGuard,
    AppPlatform? appPlatform,
    DateTime Function()? clock,
  }) : _appPlatform = appPlatform ?? AppPlatformDetector.current,
       _sourceService = sourceService ?? BilibiliDesktopPlaybackSourceService(),
       _videoShotService = videoShotService ?? BilibiliVideoShotService.shared,
       _progressStore = progressStore ?? const WindowsPlaybackProgressStore(),
       _bufferStateReader = bufferStateReader,
       _clock = clock ?? DateTime.now,
       _player =
           player ??
           Player(
             configuration: const PlayerConfiguration(
               title: '焦点哔哩',
               bufferSize: 64 * 1024 * 1024,
             ),
           ) {
    _videoController = VideoController(
      _player,
      configuration: AppleVideoCapabilities.configuration,
    );
    WindowsMediaCacheRuntime.registerPlaybackSession();
    _subscribeToPlayer();
    CacheLifecycle.account.addListener(_handleCourseAccountChanged);
    _courseLibraryVersion = courseCacheGuard?.library.listVersion;
    courseCacheGuard?.library.addListener(_handleCourseLibraryChanged);
  }

  static const Duration _progressSaveInterval = Duration(seconds: 5);
  static const Duration _audioDecoderReadyTimeout = Duration(seconds: 5);
  static const Duration _audioAfterVideoReadyTimeout = Duration(seconds: 2);
  static const Duration _mediaErrorHealthCheckTimeout = Duration(seconds: 1);
  static const Duration _resumePositionTolerance = Duration(seconds: 1);
  static const Duration _resumePositionCorrectionTimeout = Duration(seconds: 2);
  static const Duration _resumePositionPollInterval = Duration(
    milliseconds: 100,
  );

  final AppPlatform _appPlatform;
  final BilibiliDesktopPlaybackSourceService _sourceService;
  final BilibiliVideoShotService _videoShotService;
  final WindowsPlaybackProgressStore _progressStore;
  final Future<String> Function()? _bufferStateReader;
  final DateTime Function() _clock;
  final Player _player;
  final CourseCachePlaybackGuard? courseCacheGuard;
  Timer? _courseExpiry;
  int? _courseLibraryVersion;
  Future<CourseCacheEntry> Function()? _activeCourseReceipt;
  late final VideoController _videoController;
  final ApplePlaybackSession _appleSession = ApplePlaybackSession();
  final LinuxMediaSession _linuxSession = LinuxMediaSession();
  final LinuxMiniPlayer _linuxMiniPlayer = LinuxMiniPlayer();
  final FlutterVideoFrameCapture _frameCapture = FlutterVideoFrameCapture();
  int _frameTimelineRevision = 0;
  int _frameSeeksInFlight = 0;
  final Stopwatch _sinceFrameSeek = Stopwatch()..start();
  final StreamController<PlaybackSnapshot> _stateController =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  VideoPreview? _currentVideo;
  VideoPart? _currentPart;
  bool _localSource = false;
  bool _audioOnly = false;
  String? _localVideoPath;
  String? _localAudioPath;
  Timer? _sleepTimer;
  Timer? _bufferTimer;
  bool _samplingBuffer = false;
  List<PlaybackBufferRange> _bufferedRanges = const [];
  DateTime? _sleepDeadline;

  /// 原地切换音频媒体，停止旧画面传输，保留当前位置和播放意图。
  @override
  Future<void> setAudioOnly(bool enabled) async {
    _ensureAvailable();
    if (_audioOnly == enabled) return;
    final video = _currentVideo;
    final part = _currentPart;
    if (video == null || part == null || _opening) {
      throw StateError('请等待当前视频加载完成。');
    }
    if (enabled &&
        !_localSource &&
        _mediaAttempts.every((item) => item.audioUrl.isEmpty)) {
      throw StateError('当前视频没有可用的独立音轨。');
    }
    final position = _player.state.position;
    final playing =
        _snapshot.phase != PlaybackPhase.ended && _shouldPlayAfterFallback;
    final previous = _audioOnly;
    final generation = _beginSourceRequest();
    if (video.isCourse) {
      _courseAccountRevision ??=
          _loadedCourseAccountRevision ?? CacheLifecycle.account.value;
    }
    _audioOnly = enabled;
    _opening = true;
    _shouldPlayAfterFallback = playing;
    try {
      // 冻结已捕获的位置；暂停返回后必须确认仍是这次切换，不能重开旧视频。
      await _player.pause();
      if (!_isCurrentSourceRequest(generation)) return;
      if (_localSource) {
        await _openLocalMedia(
          filePath: _localVideoPath!,
          audioFilePath: _localAudioPath,
          video: video,
          part: part,
          title: video.title,
          initialPosition: position,
          shouldPlay: _shouldPlayAfterFallback,
          sourceGeneration: generation,
        );
      } else {
        await _openCurrentSource(
          generation: generation,
          video: video,
          part: part,
          quality: _currentQuality,
          resumePosition: position,
          shouldPlay: _shouldPlayAfterFallback,
          reuseSources: true,
        );
      }
    } catch (_) {
      if (!_isCurrentSourceRequest(generation)) return;
      _audioOnly = previous;
      _opening = false;
      _emitPlayerState();
      rethrow;
    }
  }

  /// 后端定时暂停在最小化或系统锁屏时继续运行，关闭定时会撤销旧回调。
  @override
  Future<void> setSleepTimer(Duration? duration) async {
    _sleepTimer?.cancel();
    _sleepDeadline = duration == null ? null : DateTime.now().add(duration);
    if (duration != null) {
      _sleepTimer = Timer(duration, () {
        _sleepDeadline = null;
        if (!_disposed) unawaited(pause());
      });
    }
    _emitPlayerState();
  }

  PlaybackSnapshot _snapshot = const PlaybackSnapshot();
  List<PlaybackQuality> _availableQualities = const <PlaybackQuality>[
    PlaybackQuality(id: 64, label: '高清 720P'),
  ];
  int _currentQuality = 64;
  Duration _restoredPosition = Duration.zero;
  DateTime? _lastProgressSavedAt;
  Future<void> _progressSaveQueue = Future<void>.value();
  bool _disposed = false;
  bool _opening = false;
  bool _mediaLoaded = false;
  bool _restoringPosition = false;
  int? _recoveringGeneration;
  Future<void>? _cacheConfiguration;
  int? _courseAccountRevision;
  int? _loadedCourseAccountRevision;
  Future<void> _accountChangeStop = Future<void>.value();
  // Includes issued play commands: logout must stop after every media activation.
  final Set<Future<void>> _pendingMediaOpens = {};
  Future<void> Function()? _activeSessionValidator;
  Future<void> Function()? _loadedSessionValidator;

  /// 停掉底层已加载媒体后，再解除绑定在旧媒体上的课堂账号、校验器与到期保护。
  Future<void> _stopLoadedMedia() async {
    await _player.stop();
    _mediaLoaded = false;
    _loadedCourseAccountRevision = null;
    _loadedSessionValidator = null;
    _courseExpiry?.cancel();
    _courseExpiry = null;
    _activeCourseReceipt = null;
  }

  /// Wait before registering a media command. Course-account revocation may
  /// wait for commands already registered in [_pendingMediaOpens]; a command
  /// cannot join that set and then wait for the stop that drains it.
  Future<bool> _waitForAccountStop(int generation) async {
    while (_isCurrentSourceRequest(generation)) {
      final stop = _accountChangeStop;
      await stop;
      if (identical(stop, _accountChangeStop)) {
        return _isCurrentSourceRequest(generation);
      }
    }
    return false;
  }

  /// Checks authorization again before issuing a command on an existing source.
  Future<bool> _validateActiveSession(int generation) async {
    if (!_isCurrentSourceRequest(generation)) return false;
    final validate = _activeSessionValidator ?? _loadedSessionValidator;
    try {
      await validate?.call();
    } catch (error) {
      if (!_isCurrentSourceRequest(generation)) return false;
      _shouldPlayAfterFallback = false;
      _cachedSources = null;
      _mediaAttempts = const [];
      final stopped = _accountChangeStop.then((_) async {
        if (_isCurrentSourceRequest(generation)) {
          await _stopLoadedMedia();
        }
      });
      _accountChangeStop = stopped.catchError((Object _) {});
      await stopped;
      throw error is BilibiliPlaybackSessionException
          ? error
          : const BilibiliPlaybackSessionException('unknown');
    }
    return _isCurrentSourceRequest(generation);
  }

  Future<void> _openPlayerMedia(Media media, {required bool play}) async {
    final generation = _sourceGeneration;
    if (!await _waitForAccountStop(generation)) return;
    if (!await _validateActiveSession(generation)) return;
    final fence = Completer<void>();
    _pendingMediaOpens.add(fence.future);
    try {
      _mediaLoaded = true;
      _loadedCourseAccountRevision = _courseAccountRevision;
      _loadedSessionValidator = _activeSessionValidator;
      await _player.open(media, play: play);
      await _validateActiveSession(generation);
    } finally {
      fence.complete();
      _pendingMediaOpens.remove(fence.future);
    }
  }

  /// A later explicit pause wins even if an already-issued play finishes last.
  Future<void> _playPlayerMedia(int generation) async {
    if (!_isCurrentSourceRequest(generation) || !_shouldPlayAfterFallback) {
      return;
    }
    if (!await _waitForAccountStop(generation) || !_shouldPlayAfterFallback) {
      return;
    }
    if (!await _validateActiveSession(generation)) return;
    if (!_shouldPlayAfterFallback) return;
    final fence = Completer<void>();
    _pendingMediaOpens.add(fence.future);
    try {
      await _player.play();
      await _validateActiveSession(generation);
      if (_isCurrentSourceRequest(generation) && !_shouldPlayAfterFallback) {
        await _player.pause();
      }
    } finally {
      fence.complete();
      _pendingMediaOpens.remove(fence.future);
    }
  }

  void _scheduleCourseExpiry(Duration? delay, int generation) {
    _courseExpiry?.cancel();
    _courseExpiry = delay == null
        ? null
        : Timer(delay, () {
            if (!_disposed &&
                (_isCurrentSourceRequest(generation) ||
                    _loadedCourseAccountRevision != null)) {
              _handleCourseAccountChanged(message: '本次课程校验已到期，请返回离线缓存。');
            }
          });
  }

  void _handleCourseLibraryChanged() {
    final library = courseCacheGuard?.library;
    if (library == null || library.listVersion == _courseLibraryVersion) return;
    final version = _courseLibraryVersion = library.listVersion;
    final read = _activeCourseReceipt;
    final generation = _sourceGeneration;
    if (read == null ||
        (!_isCurrentSourceRequest(generation) &&
            _loadedCourseAccountRevision == null)) {
      return;
    }
    unawaited(() async {
      try {
        final fresh = await read();
        if (!_disposed &&
            _courseLibraryVersion == version &&
            (_isCurrentSourceRequest(generation) ||
                _loadedCourseAccountRevision != null)) {
          _scheduleCourseExpiry(library.untilExpiry(fresh), generation);
        }
      } catch (_) {
        if (!_disposed &&
            _courseLibraryVersion == version &&
            (_isCurrentSourceRequest(generation) ||
                _loadedCourseAccountRevision != null)) {
          _handleCourseAccountChanged(message: '课程缓存状态已变化，请返回离线缓存。');
        }
      }
    }());
  }

  /// 课程媒体只属于请求时的账号；切换立即撤销候选并串行停流。
  void _handleCourseAccountChanged({String message = '登录状态已变化，请重新打开课程。'}) {
    if (_disposed ||
        (_courseAccountRevision == null &&
            _loadedCourseAccountRevision == null)) {
      return;
    }
    // 若新源打开失败后旧课堂仍加载在底层播放器中，须继续阻断后续 play() 重启。
    _courseAccountRevision ??= _loadedCourseAccountRevision;
    final generation = ++_sourceGeneration;
    _activeCourseReceipt = null;
    _activeSessionValidator = null;
    _courseExpiry?.cancel();
    _courseExpiry = null;
    _bufferedRanges = const [];
    _mediaAttempts = const [];
    _activeMediaHeaders = const {};
    _activeAudioMedia = null;
    _externalAudioNeedsReload = false;
    _shouldPlayAfterFallback = false;
    _opening = true;
    _emitPlayerState(phaseOverride: PlaybackPhase.error, message: message);
    final pendingOpens = List<Future<void>>.of(_pendingMediaOpens);
    _accountChangeStop = _accountChangeStop
        .then((_) async {
          await Future.wait(pendingOpens);
          if (!_disposed) {
            await _stopLoadedMedia();
          }
        })
        .catchError((Object _) {});
    unawaited(
      _accountChangeStop.then((_) {
        if (!_disposed && generation == _sourceGeneration) {
          _opening = false;
          _emitPlayerState(
            phaseOverride: PlaybackPhase.error,
            message: '登录状态已变化，请重新打开课程。',
          );
        }
      }),
    );
  }

  DesktopDiskCacheSession? _diskCacheSession;
  bool _shouldPlayAfterFallback = true;
  int _sourceGeneration = 0;
  int _currentMediaAttemptIndex = 0;
  List<WindowsDashMediaAttempt> _mediaAttempts =
      const <WindowsDashMediaAttempt>[];
  PlaybackCodecPreference _codecPreference = PlaybackCodecPreference.compatible;
  bool _preferDataSaving = false;
  static const _sourceLifetime = Duration(minutes: 10);
  ({
    String bvid,
    int cid,
    int account,
    DateTime fetchedAt,
    DesktopPlaybackSources sources,
  })?
  _cachedSources;
  DesktopPlaybackSources? _activeSources;
  DesktopVideoAlternative? _activeVideoTrack;
  ({
    DesktopPlaybackSources sources,
    DesktopVideoAlternative? track,
    List<WindowsDashMediaAttempt> attempts,
  })?
  _cachedVideoAttempts;
  final Set<({int quality, String codec, int bandwidth})> _failedVideoTracks =
      {};
  int _sourceRefreshes = 0;
  WindowsPlaybackFailure _attemptFailure = WindowsPlaybackFailure.route;
  bool _acceptAttemptErrors = false;
  int _mediaAttemptRevision = 0;
  Map<String, String> _activeMediaHeaders = const <String, String>{};
  Media? _activeAudioMedia;
  String _activeAudioTrackToken = '';
  bool _externalAudioNeedsReload = false;
  Duration _pendingResumePositionAfterDecode = Duration.zero;

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
    if (Platform.isMacOS) {
      final preferences = await const PlaybackPreferencesService().load();
      if (_disposed) return null;
      await _player.setVolume(preferences.appVolume * 100);
    }
    await _appleSession.initialize(
      handle: _appleSession.enabled ? await _player.handle : null,
      play: play,
      pause: pause,
      seek: seekTo,
      onPictureInPictureChanged: (_) => _emitPlayerState(),
    );
    await _linuxSession.initialize(
      play: play,
      pause: pause,
      seek: seekTo,
      setRate: setPlaybackSpeed,
      setVolume: setMediaVolume,
    );
    await _configureWindowsMediaCache();
    _bufferTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_sampleBufferedRanges());
    });
    return _videoController.id.value;
  }

  /// 保存旧分P并打开目标分P；调用方未指定位置时读取该 CID 自己的 Windows 进度。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
    PlaybackCodecPreference? codecPreference,
    bool preferDataSaving = false,
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
    _courseAccountRevision = video.isCourse
        ? CacheLifecycle.account.value
        : null;
    await _accountChangeStop;
    if (!_isCurrentSourceRequest(generation)) return;
    await _saveCurrentProgress(force: true);
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    // 先暂停旧媒体并保留旧身份，避免加载新记录期间把旧视频位置写到新 BV。
    await _player.pause();
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    final SavedPlaybackState? savedState = initialPosition == null
        ? await _progressStore.loadPart(video.bvid, targetPart.cid)
        : null;
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    final effectiveCodec =
        codecPreference ??
        (await const PlaybackPreferencesService().loadRoutePreferences())
            .codecPreference;
    if (!_isCurrentSourceRequest(generation)) return;
    _codecPreference = effectiveCodec;
    _preferDataSaving = preferDataSaving;
    _cachedSources = null;
    _cachedVideoAttempts = null;
    _failedVideoTracks.clear();
    _currentVideo = video;
    _localSource = false;
    _currentPart = targetPart;
    _currentQuality = quality;
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

  /// 复用本地加载流程挂载独立音轨，保持缓存视频的续播和重播行为。
  @override
  Future<void> openLocalTracks({
    required String videoFilePath,
    required String audioFilePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
  }) => _openLocalMedia(
    filePath: videoFilePath,
    audioFilePath: audioFilePath,
    title: title,
    initialPosition: initialPosition,
    video: video,
    part: part,
  );

  /// 保持原有单文件接口，旧缓存及既有调用方无需新增参数。
  @override
  Future<void> openLocalFile({
    required String filePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
  }) => _openLocalMedia(
    filePath: filePath,
    title: title,
    initialPosition: initialPosition,
    video: video,
    part: part,
  );

  /// 本地音视频一起加载并校验解码和位置，之后才报告就绪。
  Future<void> _openLocalMedia({
    required String filePath,
    String? audioFilePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
    bool shouldPlay = true,
    int? sourceGeneration,
  }) async {
    _ensureAvailable();
    if (filePath.trim().isEmpty || (initialPosition?.isNegative ?? false)) {
      throw ArgumentError('Invalid local playback request');
    }
    if (audioFilePath != null && audioFilePath.trim().isEmpty) {
      throw ArgumentError('本地音频路径无效');
    }
    // A private-cache player is scoped to exactly one lesson. Decline an
    // unrelated request before invalidating the active account/expiry guard.
    final scoped = courseCacheGuard;
    if (scoped != null) {
      await scoped.validate(
        video,
        part ?? video?.initialPart,
        filePath,
        audioFilePath,
      );
    }
    final generation = sourceGeneration ?? _beginSourceRequest();
    if (sourceGeneration == null) {
      _courseAccountRevision = video?.isCourse == true
          ? CacheLifecycle.account.value
          : null;
    }
    if (!await _waitForAccountStop(generation)) return;
    final file = File(filePath);
    if (!await file.exists()) throw StateError('离线文件不存在');
    final audioFile = audioFilePath == null ? null : File(audioFilePath);
    if (audioFile != null && !await audioFile.exists()) {
      throw StateError('离线音频文件不存在');
    }
    final isCourse = video?.isCourse == true;
    final guard = courseCacheGuard;
    Future<CourseCacheEntry> Function()? nextCourseReceipt;
    CourseCacheEntry? nextCourseEntry;
    Future<void> Function()? nextSessionValidator;
    if (isCourse ||
        await CourseCachePlaybackGuard.isPrivateFile(file) ||
        audioFile != null &&
            await CourseCachePlaybackGuard.isPrivateFile(audioFile)) {
      if (!isCourse || guard == null) throw StateError('请从当前账号的「离线缓存」打开此章节。');
      Future<CourseCacheEntry> verify() => guard.validate(
        video,
        part ?? video?.initialPart,
        filePath,
        audioFilePath,
      );
      final receipt = await verify();
      if (!_isCurrentSourceRequest(generation)) return;
      final delay = guard.library.untilExpiry(receipt);
      if (delay != null && delay <= Duration.zero) {
        throw StateError('本次课程校验已到期。');
      }
      nextCourseReceipt = verify;
      nextCourseEntry = receipt;
      nextSessionValidator = () async {
        await verify();
      };
    }
    if (!_isCurrentSourceRequest(generation)) return;
    await _saveCurrentProgress(force: true);
    if (!_isCurrentSourceRequest(generation)) return;
    _opening = true;
    final targetPart = part ?? video?.initialPart;
    final saved = initialPosition == null && video != null && targetPart != null
        ? await _progressStore.loadPart(video.bvid, targetPart.cid)
        : null;
    if (!_isCurrentSourceRequest(generation)) return;
    _currentVideo = video;
    _currentPart = targetPart;
    _localSource = true;
    _localVideoPath = filePath;
    _localAudioPath = audioFilePath;
    _restoredPosition = initialPosition ?? saved?.position ?? Duration.zero;
    final resumePosition = _restoredPosition;
    _restoringPosition = resumePosition > Duration.zero;
    if (sourceGeneration == null) _shouldPlayAfterFallback = shouldPlay;
    final localAttempt = audioFile == null || _audioOnly
        ? null
        : WindowsDashMediaAttempt(
            videoUrl: file.absolute.path,
            audioUrl: audioFile.absolute.path,
            audioCodec: 'local',
          );
    _activeMediaHeaders = const {};
    _mediaAttempts = localAttempt == null ? const [] : [localAttempt];
    _activeAudioMedia = localAttempt?.createAudioMedia(_activeMediaHeaders);
    _availableQualities = const [];
    _currentQuality = 0;
    _currentMediaAttemptIndex = 0;
    _activeAudioTrackToken = localAttempt == null
        ? ''
        : _audioTrackTokenFor(generation);
    _snapshot = const PlaybackSnapshot();
    _emitPlayerState(
      phaseOverride: PlaybackPhase.loading,
      message: '正在打开离线视频…',
    );
    try {
      await _stopLoadedMedia();
      if (!_isCurrentSourceRequest(generation)) return;
      _activeCourseReceipt = nextCourseReceipt;
      _activeSessionValidator = nextSessionValidator;
      if (nextCourseEntry != null && guard != null) {
        final remaining = guard.library.untilExpiry(nextCourseEntry);
        if (remaining != null && remaining <= Duration.zero) {
          throw StateError('本次课程校验已到期。');
        }
        _scheduleCourseExpiry(remaining, generation);
      }
      await _applyMediaCachePolicy(generation, diskAllowed: !isCourse);
      if (!_isCurrentSourceRequest(generation)) return;
      await _openPlayerMedia(
        Media(
          (_audioOnly ? audioFile ?? file : file).absolute.path,
          start: resumePosition,
        ),
        play: false,
      );
      if (!_isCurrentSourceRequest(generation)) return;
      await _player.setVideoTrack(
        _audioOnly ? VideoTrack.no() : VideoTrack.auto(),
      );
      if (localAttempt != null) {
        await _player.setAudioTrack(
          localAttempt.createAudioTrack(
            _activeAudioMedia!,
            title: _activeAudioTrackToken,
          ),
        );
        if (!_isCurrentSourceRequest(generation)) return;
        _pendingResumePositionAfterDecode = resumePosition;
      }
      if (!await _waitForMediaReady(generation)) {
        if (!_isCurrentSourceRequest(generation)) return;
        throw StateError('本地媒体未能完成加载');
      }
      await _restoreResumePositionAfterDecode(
        generation,
        resumePosition,
        restorePlayback: false,
      );
      if (!_isCurrentSourceRequest(generation)) return;
      if (_isResumePositionBehindTarget(
        _clampResumePositionToMediaDuration(resumePosition),
      )) {
        throw StateError('本地媒体未能恢复当前位置');
      }
      if (_shouldPlayAfterFallback) await _playPlayerMedia(generation);
      if (!_isCurrentSourceRequest(generation)) return;
      if (localAttempt != null && _shouldPlayAfterFallback) {
        if (!await _waitForDecodedAudio(generation)) {
          if (!_isCurrentSourceRequest(generation)) return;
          throw StateError('本地音频未能完成加载');
        }
        await _restoreResumePositionAfterDecode(generation, resumePosition);
        if (!_isCurrentSourceRequest(generation)) return;
        _pendingResumePositionAfterDecode = Duration.zero;
      }
      _opening = false;
      _restoringPosition = false;
      _emitPlayerState(phaseOverride: PlaybackPhase.ready, clearMessage: true);
      _restoredPosition = Duration.zero;
    } catch (_) {
      if (_isCurrentSourceRequest(generation)) {
        _opening = false;
        _restoringPosition = false;
        _emitPlayerState(
          phaseOverride: PlaybackPhase.error,
          message: '无法打开离线视频。',
        );
      }
      rethrow;
    }
  }

  /// 等待当前媒体产生真实时长（视频还需解码画面），避免把收到加载命令误当成就绪。
  Future<bool> _waitForMediaReady(int generation) async {
    final deadline = DateTime.now().add(_audioDecoderReadyTimeout);
    while (_isCurrentSourceRequest(generation)) {
      if (_opening && _acceptAttemptErrors) _throwIfKnownMediaFailure();
      if (_player.state.duration > Duration.zero && _hasDecodedVideo()) {
        return true;
      }
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(_resumePositionPollInterval);
    }
    return false;
  }

  /// Resumes the current Windows media session.
  @override
  Future<void> play() async {
    _ensureAvailable();
    if (!_isCurrentSourceRequest(_sourceGeneration)) {
      throw StateError('登录状态已变化，请重新打开课程。');
    }
    _shouldPlayAfterFallback = true;
    _emitPlayerState();
    final int generation = _sourceGeneration;
    await _restartFromBeginningIfEnded();
    await _reloadExternalAudioAfterCompletion(generation);
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    await _playPlayerMedia(generation);
    if (_isCurrentSourceRequest(generation)) _emitPlayerState();
    if (_activeAudioMedia != null && _isCurrentSourceRequest(generation)) {
      if (!await _waitForDecodedAudio(generation)) {
        await _handleMediaError();
        return;
      }
      await _restoreResumePositionAfterDecode(
        generation,
        _pendingResumePositionAfterDecode,
      );
      if (_isCurrentSourceRequest(generation)) {
        _pendingResumePositionAfterDecode = Duration.zero;
      }
    }
  }

  /// 暂停当前 Windows 媒体并立即保存恢复位置。
  @override
  Future<void> pause() async {
    _ensureAvailable();
    _shouldPlayAfterFallback = false;
    // Already-buffering/ended mpv may not emit a playing event for pause().
    _emitPlayerState();
    await _player.pause();
    _emitPlayerState();
    await _saveCurrentProgress(force: true);
  }

  /// 把相对快进量加到当前位置，并同步暂停清晰度重开仍待复核的目标位置。
  @override
  Future<void> seekBy(Duration offset) async {
    _ensureAvailable();
    _frameTimelineRevision++;
    _frameSeeksInFlight++;
    try {
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
      final Duration targetPosition = Duration(
        milliseconds: targetMilliseconds,
      );
      await _player.seek(targetPosition);
      if (_pendingResumePositionAfterDecode > Duration.zero) {
        _pendingResumePositionAfterDecode = targetPosition;
      }
    } finally {
      _frameSeeksInFlight--;
      _sinceFrameSeek.reset();
    }
  }

  /// 跳转到指定绝对位置，并同步暂停清晰度重开仍待复核的目标位置。
  @override
  Future<void> seekTo(Duration position) async {
    _ensureAvailable();
    _frameTimelineRevision++;
    _frameSeeksInFlight++;
    try {
      final Duration duration = _player.state.duration;
      final int targetMilliseconds = position.inMilliseconds.clamp(
        0,
        duration > Duration.zero ? duration.inMilliseconds : 1 << 31,
      );
      _leaveEndedPhaseWhenSeekingBeforeEnd(
        Duration(milliseconds: targetMilliseconds),
        duration,
      );
      final Duration targetPosition = Duration(
        milliseconds: targetMilliseconds,
      );
      await _player.seek(targetPosition);
      if (_pendingResumePositionAfterDecode > Duration.zero) {
        _pendingResumePositionAfterDecode = targetPosition;
      }
    } finally {
      _frameSeeksInFlight--;
      _sinceFrameSeek.reset();
    }
  }

  /// 从完播状态再次点击播放时回到零点，并先广播 ready 以建立新的播放轮次。
  Future<void> _restartFromBeginningIfEnded() async {
    if (_snapshot.phase != PlaybackPhase.ended) {
      return;
    }
    await _player.seek(Duration.zero);
    _emitPlayerState(phaseOverride: PlaybackPhase.ready);
  }

  /// 完播后重新挂载当前本地或 CDN 音轨，避免第二轮只剩画面。
  Future<void> _reloadExternalAudioAfterCompletion(int generation) async {
    if (_audioOnly) {
      _externalAudioNeedsReload = false;
      return;
    }
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
    if (!await _validateActiveSession(generation)) return;
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

  /// 在高倍速时放宽 mpv 音频变速滤镜的静音阈值，再更新播放速度。
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    _ensureAvailable();
    if (!speed.isFinite || speed < 0.5 || speed > 5) {
      throw ArgumentError.value(speed, 'speed', '倍速必须在 0.5 到 5.0 之间。');
    }
    final PlatformPlayer? platformPlayer = _player.platform;
    if (speed > 2 && platformPlayer is NativePlayer) {
      try {
        // Explicit scaletempo2 replaces mpv's default filter; zero disables its
        // high-speed mute threshold while preserving the original speech pitch.
        await platformPlayer.setProperty('af', 'scaletempo2=max-speed=0');
      } catch (_) {
        // Older mpv builds can still play audibly without pitch correction.
        await platformPlayer.setProperty('audio-pitch-correction', 'no');
      }
    } else if (platformPlayer is NativePlayer) {
      // Restore normal pitch correction if an older mpv needed the fallback.
      await platformPlayer.setProperty('audio-pitch-correction', 'yes');
    }
    await _player.setRate(speed);
  }

  /// 保留进度和暂停意图，优先复用当前响应已经下发的确切清晰度。
  @override
  Future<void> selectQuality(int quality) async {
    _ensureAvailable();
    if (quality <= 0) {
      throw ArgumentError.value(quality, 'quality', '需要有效的清晰度编号。');
    }
    if (quality == _currentQuality ||
        _localSource ||
        _currentVideo == null ||
        _currentPart == null) {
      return;
    }
    final Duration position = _player.state.position;
    final bool shouldPlay =
        _snapshot.phase != PlaybackPhase.ended && _shouldPlayAfterFallback;
    final VideoPreview video = _currentVideo!;
    final VideoPart part = _currentPart!;
    final int generation = _beginSourceRequest();
    if (video.isCourse) {
      _courseAccountRevision ??=
          _loadedCourseAccountRevision ?? CacheLifecycle.account.value;
    }
    await _openCurrentSource(
      generation: generation,
      video: video,
      part: part,
      quality: quality,
      resumePosition: position,
      shouldPlay: shouldPlay,
      reuseSources: true,
    );
  }

  /// 从 Windows 本机偏好读取该视频最后分P和位置，接近结尾时从头开始。
  @override
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid) =>
      _progressStore.load(bvid);

  /// Windows 读取系统音量，macOS/Linux 读取播放器增益以支持外接音响。
  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async {
    // Linux ALSA may have no default Master mixer (PipeWire/headless systems).
    // Use this player's gain instead of a native mixer that can dereference null.
    if (Platform.isLinux || Platform.isMacOS) {
      return SystemPlaybackLevels(
        brightness: 1,
        volume: (_player.state.volume / 100).clamp(0, 1).toDouble(),
      );
    }
    double volume = 0.5;
    try {
      volume = await VolumeController.instance.getVolume();
    } catch (_) {
      volume = 0.5;
    }
    return SystemPlaybackLevels(
      // Windows 不再读取或写入物理显示器亮度，画面亮度由播放器覆盖层处理。
      brightness: 1,
      volume: volume.clamp(0, 1).toDouble(),
    );
  }

  /// 保留统一播放接口；Windows 的亮度实际由页面软件覆盖层绘制。
  @override
  Future<void> setScreenBrightness(double brightness) {
    _ensureAvailable();
    return Future<void>.value();
  }

  /// macOS/Linux 调整播放器增益，Windows 调整系统音量并隐藏系统浮层。
  @override
  Future<void> setMediaVolume(double volume) {
    _ensureAvailable();
    if (Platform.isLinux || Platform.isMacOS) {
      return _player.setVolume(volume.clamp(0, 1).toDouble() * 100);
    }
    VolumeController.instance.showSystemUI = false;
    return VolumeController.instance.setVolume(volume.clamp(0, 1).toDouble());
  }

  /// Windows 小窗模式将在窗口管理阶段实现；当前明确返回不支持，避免伪造成功状态。
  @override
  Future<bool> enterPictureInPicture(double aspectRatio) async {
    _ensureAvailable();
    if (Platform.isLinux) {
      final changed = await _linuxMiniPlayer.toggle(aspectRatio);
      _emitPlayerState();
      return changed;
    }
    final rect = _frameCapture.globalRect;
    return rect != null && await _appleSession.startPictureInPicture(rect);
  }

  /// 仅回读当前画面。Windows/macOS/Linux/iOS 均不调用可能终止进程
  /// 的原生 screenshot，也不以 B 站近似预览图冒充实际画面。
  @override
  Future<LiveVideoFrame?> captureLiveVideoFrame() async {
    final video = _currentVideo;
    final part = _currentPart;
    if (video == null || part == null) return null;
    final generation = _sourceGeneration;
    final timeline = _frameTimelineRevision;
    bool isCurrent() =>
        _isCurrentSourceRequest(generation) &&
        timeline == _frameTimelineRevision &&
        _frameSeeksInFlight == 0 &&
        _sinceFrameSeek.elapsed >= const Duration(milliseconds: 250) &&
        !_opening &&
        !_audioOnly &&
        !_player.state.buffering &&
        _snapshot.phase == PlaybackPhase.ready &&
        !_snapshot.isRestoringPosition;
    final sample = await _frameCapture.captureLivePng(
      readPosition: () => _player.state.position,
      isCurrent: isCurrent,
    );
    if (sample == null || !isCurrent()) return null;
    final output = await _persistCapturedFrame(sample.bytes);
    if (!isCurrent()) {
      try {
        await File(output).delete();
      } on FileSystemException {
        // Best effort for an unpublished, already cancelled frame.
      }
      return null;
    }
    return LiveVideoFrame(
      path: output,
      position: sample.position,
      bvid: video.bvid,
      cid: part.cid,
    );
  }

  /// 优先读取 Flutter 已绘制画面，失败时裁切 B 站时间点雪碧图，始终绕开会终止进程的原生截图。
  @override
  Future<String?> captureCurrentFrame() async {
    _ensureAvailable();
    List<int>? bytes = await _frameCapture.capturePngBytes(pixelRatio: 1.5);
    final VideoPreview? video = _currentVideo;
    final VideoPart? part = _currentPart;
    if ((bytes == null || bytes.isEmpty) &&
        !_localSource &&
        video != null &&
        part != null) {
      bytes = await _videoShotService.captureFramePngBytes(
        bvid: video.bvid,
        cid: part.cid,
        position: _player.state.position,
      );
    }
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return _persistCapturedFrame(bytes);
  }

  Future<String> _persistCapturedFrame(List<int> bytes) async {
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final Directory frameDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}video_frames',
    );
    await frameDirectory.create(recursive: true);
    final File output = File(
      '${frameDirectory.path}${Platform.pathSeparator}'
      'frame_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      await output.writeAsBytes(bytes, flush: true);
      return output.path;
    } on FileSystemException {
      try {
        await output.delete();
      } on FileSystemException {
        // A failed write need not have created a file.
      }
      rethrow;
    }
  }

  /// 保存最后进度、释放 media_kit 与全部订阅，不触碰 Windows 显示器亮度。
  @override
  Future<void> dispose() async {
    _sleepTimer?.cancel();
    _bufferTimer?.cancel();
    _courseExpiry?.cancel();
    if (_disposed) {
      return;
    }
    CacheLifecycle.account.removeListener(_handleCourseAccountChanged);
    courseCacheGuard?.library.removeListener(_handleCourseLibraryChanged);
    _activeCourseReceipt = null;
    await _accountChangeStop;
    try {
      try {
        await _saveCurrentProgress(force: true);
      } catch (_) {
        // 偏好设置写入失败不能阻止播放器、磁盘缓冲句柄和活跃会话标记释放。
      }
      _disposed = true;
      await _diskCacheSession?.stopMonitoring();
      for (final StreamSubscription<dynamic> subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      try {
        await _appleSession.dispose();
        await _linuxSession.dispose();
        await _linuxMiniPlayer.dispose();
      } finally {
        // Keep the lifetime lock if mpv disposal fails; its file handles may
        // still be live. A later process can reclaim them only after exit.
        await _player.dispose();
        await _diskCacheSession?.releaseAfterPlayerClosed();
      }
    } finally {
      _activeAudioMedia = null;
      WindowsMediaCacheRuntime.unregisterPlaybackSession();
      unawaited(
        WindowsMediaCacheService().maintain().catchError((Object _) {}),
      );
      if (!_stateController.isClosed) {
        await _stateController.close();
      }
    }
  }

  /// Shares one disk lease setup across initialization and concurrent opens.
  Future<void> _configureWindowsMediaCache() =>
      _cacheConfiguration ??= _createDiskCacheSession();

  /// Connects the lease to the native player's verified option interface.
  Future<void> _createDiskCacheSession() async {
    if (_disposed) return;
    final platformPlayer = _player.platform;
    if (platformPlayer is! NativePlayer) return;
    final session = DesktopDiskCacheSession(
      writeProperty: platformPlayer.setProperty,
      readProperty: platformPlayer.getProperty,
    );
    _diskCacheSession = session;
    await session.configure();
  }

  /// Applies the network and classroom budget after closing the old media.
  Future<void> _applyMediaCachePolicy(
    int generation, {
    required bool diskAllowed,
  }) async {
    await _configureWindowsMediaCache();
    if (!_isCurrentSourceRequest(generation)) return;
    await _diskCacheSession?.applyPlaybackPolicy(
      diskAllowed: diskAllowed,
      preferDataSaving: _preferDataSaving,
    );
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
      ..add(_player.stream.volume.listen((double _) => _emitPlayerState()))
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
      ..add(_player.stream.error.listen(_onPlayerError));
    if (_player.platform is NativePlayer) {
      _subscriptions.add(
        _player.stream.log.listen((log) {
          if (log.level == 'error' || log.level == 'fatal') {
            _onPlayerError(log.text, prefix: log.prefix, fromLog: true);
          }
        }),
      );
    }
  }

  /// Keeps typed error evidence for the current open and verifies later failures.
  void _onPlayerError(
    String message, {
    String prefix = '',
    bool fromLog = false,
  }) {
    if (!_acceptAttemptErrors || _disposed) return;
    final failure = WindowsPlaybackRecoveryPolicy.classify(
      message,
      prefix: prefix,
    );
    // A generic error must not overwrite an explicit decoder or status error.
    if (failure != WindowsPlaybackFailure.route) {
      if (_attemptFailure == WindowsPlaybackFailure.route ||
          failure == WindowsPlaybackFailure.accessDenied ||
          failure == WindowsPlaybackFailure.expired &&
              _attemptFailure == WindowsPlaybackFailure.videoDecoder) {
        _attemptFailure = failure;
      }
    } else if (fromLog) {
      return;
    }
    if (_opening) return;
    unawaited(
      _verifyPlayerError(
        generation: _sourceGeneration,
        mediaAttemptIndex: _currentMediaAttemptIndex,
        mediaAttemptRevision: _mediaAttemptRevision,
      ),
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
    bool reuseSources = false,
  }) async {
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    _opening = true;
    // 必须在网络等待前保存播放意图；等待期间的定时暂停不能被旧 shouldPlay 覆盖。
    _shouldPlayAfterFallback = shouldPlay;
    _restoringPosition = resumePosition > Duration.zero;
    _emitPlayerState(
      phaseOverride: PlaybackPhase.loading,
      message: resumePosition > Duration.zero ? '正在恢复上次播放位置…' : '正在请求播放数据…',
    );
    // Record the caller's intent above, not after this wait: a pause issued
    // while the revoked source is stopping must remain the final intent.
    if (!await _waitForAccountStop(generation)) return;
    try {
      if (!await _prepareNetworkSource(
        generation: generation,
        video: video,
        part: part,
        quality: quality,
        reuseSources: reuseSources,
      )) {
        return;
      }
      await _openFirstAvailableMedia(
        generation: generation,
        resumePosition: resumePosition,
      );
      if (!_isCurrentSourceRequest(generation)) {
        return;
      }
      _opening = false;
      _restoringPosition = false;
      _emitPlayerState(phaseOverride: PlaybackPhase.ready, clearMessage: true);
      _restoredPosition = Duration.zero;
    } catch (error) {
      if (!_isCurrentSourceRequest(generation)) {
        return;
      }
      _opening = false;
      _restoringPosition = false;
      _restoredPosition = Duration.zero;
      _acceptAttemptErrors = false;
      final String message = error is DesktopPlaybackSourceException
          ? error.message
          : error is BilibiliPlaybackSessionException
          ? error.toString()
          : error is WbiSigningException
          ? error.toString()
          : 'Windows 播放器暂时无法打开该视频，请重试。';
      _emitPlayerState(phaseOverride: PlaybackPhase.error, message: message);
      rethrow;
    }
  }

  /// Reuses a live response for this account and part, or fetches and validates one.
  Future<bool> _prepareNetworkSource({
    required int generation,
    required VideoPreview video,
    required VideoPart part,
    required int quality,
    required bool reuseSources,
  }) async {
    final account = CacheLifecycle.account.value;
    final now = _clock();
    final cached = _cachedSources;
    final age = cached == null ? null : now.difference(cached.fetchedAt);
    final reusable =
        reuseSources &&
        !video.isCourse &&
        cached != null &&
        cached.bvid == video.bvid &&
        cached.cid == part.cid &&
        cached.account == account &&
        !age!.isNegative &&
        age < _sourceLifetime;
    final cachedSelection = !reusable
        ? null
        : _activeSources?.actualQuality == quality
        ? _activeSources
        : cached.sources.forQuality(quality);
    final DesktopPlaybackSources sources;
    try {
      sources =
          cachedSelection ??
          (video.isCourse
              ? await _sourceService.loadCourse(
                  video: video,
                  part: part,
                  quality: quality,
                )
              : await _sourceService.loadForVideo(
                  video: video,
                  cid: part.cid,
                  quality: quality,
                  codecPreference: _codecPreference,
                  preferDataSaving: _preferDataSaving,
                  useDesktopUserAgentOverride: _appPlatform.isDesktop,
                ));
    } on BilibiliPlaybackSessionException {
      await _stopAfterAccessFailure(generation);
      rethrow;
    } on BilibiliRequestFailure catch (error) {
      if (video.isCourse ||
          const {-101, -401, -403}.contains(error.apiCode) ||
          const {401, 403, 451}.contains(error.httpStatus)) {
        await _stopAfterAccessFailure(generation);
      }
      rethrow;
    }
    if (!_isCurrentSourceRequest(generation)) return false;
    if (account != CacheLifecycle.account.value) {
      await _stopAfterAccessFailure(generation);
      throw const BilibiliPlaybackSessionException('changing');
    }
    _activeSessionValidator = sources.validateSession;
    if (!await _validateActiveSession(generation)) return false;
    if (cachedSelection == null && !video.isCourse) {
      _cachedSources = (
        bvid: video.bvid,
        cid: part.cid,
        account: account,
        fetchedAt: now,
        sources: sources,
      );
    }
    _activeSources = sources;
    _availableQualities = sources.qualities;
    _currentQuality = sources.actualQuality;
    _activeMediaHeaders = sources.mediaHeaders;
    if (_audioOnly) {
      _currentMediaAttemptIndex = 0;
      _mediaAttempts = [
        for (final url in sources.audioUrls)
          WindowsDashMediaAttempt(
            videoUrl: '',
            audioUrl: url,
            audioCodec: sources.audioCodecByUrl[url] ?? sources.audioCodec,
          ),
      ];
    } else {
      final preferred = sources.selectedVideo;
      final track =
          preferred != null &&
              _failedVideoTracks.contains(_videoTrackKey(preferred))
          ? _compatibleVideoTrack(sources)
          : preferred;
      _selectVideoAttempts(sources, track);
    }
    if (_mediaAttempts.isEmpty) {
      throw const DesktopPlaybackSourceException('播放数据没有返回可用的音视频线路。');
    }
    return true;
  }

  /// Uses representation metadata to avoid retrying a failed decoder after a URL refresh.
  ({int quality, String codec, int bandwidth}) _videoTrackKey(
    DesktopVideoAlternative track,
  ) => (
    quality: track.actualQuality,
    codec: track.codec.toLowerCase(),
    bandwidth: track.bandwidth,
  );

  /// Limits decoder fallback to an untried AVC representation at the same quality.
  DesktopVideoAlternative? _compatibleVideoTrack(
    DesktopPlaybackSources sources,
  ) => sources.videoAlternatives
      .where(
        (track) =>
            track.isAvc &&
            track.actualQuality == sources.actualQuality &&
            !_failedVideoTracks.contains(_videoTrackKey(track)),
      )
      .firstOrNull;

  /// Builds routes for one representation so network errors stay within that track.
  void _selectVideoAttempts(
    DesktopPlaybackSources sources,
    DesktopVideoAlternative? track,
  ) {
    _activeVideoTrack = track;
    _currentMediaAttemptIndex = 0;
    final cached = _cachedVideoAttempts;
    if (cached != null &&
        identical(cached.sources, sources) &&
        identical(cached.track, track)) {
      _mediaAttempts = cached.attempts;
      return;
    }
    final List<WindowsDashMediaAttempt> attempts =
        track == null && sources.selectedVideo != null
        ? const []
        : WindowsDashMediaPlan.build(sources, video: track);
    _mediaAttempts = attempts;
    _cachedVideoAttempts = (sources: sources, track: track, attempts: attempts);
  }

  /// Opens a candidate and handles typed failures within the same source request.
  Future<void> _openFirstAvailableMedia({
    required int generation,
    required Duration resumePosition,
    WindowsPlaybackFailure? previousFailure,
  }) async {
    var failure = previousFailure;
    while (_isCurrentSourceRequest(generation) &&
        _currentMediaAttemptIndex < _mediaAttempts.length) {
      if (failure != null && !await _recoverMediaAttempt(failure, generation)) {
        if (!_isCurrentSourceRequest(generation)) return;
        throw DesktopPlaybackSourceException(
          _currentVideo?.isCourse == true ||
                  failure == WindowsPlaybackFailure.accessDenied
              ? '媒体播放权限已失效，请重新打开视频。'
              : '主线路和备用线路均无法播放，请稍后重试。',
        );
      }
      if (!_isCurrentSourceRequest(generation)) return;
      try {
        await _openMediaAttempt(
          _mediaAttempts[_currentMediaAttemptIndex],
          generation: generation,
          resumePosition: resumePosition,
        );
        _throwIfKnownMediaFailure();
        _attemptFailure = WindowsPlaybackFailure.route;
        return;
      } on BilibiliPlaybackSessionException {
        rethrow;
      } catch (error) {
        if (!_isCurrentSourceRequest(generation)) return;
        failure = _attemptFailure != WindowsPlaybackFailure.route
            ? _attemptFailure
            : WindowsPlaybackRecoveryPolicy.classify(error.toString());
      }
    }
    throw const DesktopPlaybackSourceException('播放数据没有返回安全的媒体地址。');
  }

  /// Advances a CDN route, refreshes expired URLs once, or changes the failed decoder.
  Future<bool> _recoverMediaAttempt(
    WindowsPlaybackFailure failure,
    int generation,
  ) async {
    final video = _currentVideo;
    final part = _currentPart;
    if (failure == WindowsPlaybackFailure.accessDenied ||
        video?.isCourse == true && failure == WindowsPlaybackFailure.expired) {
      await _stopAfterAccessFailure(generation);
      return false;
    }
    if (failure == WindowsPlaybackFailure.expired) _cachedSources = null;
    if (failure == WindowsPlaybackFailure.expired &&
        video != null &&
        part != null &&
        _sourceRefreshes < WindowsPlaybackRecoveryPolicy.maxSourceRefreshes) {
      _sourceRefreshes++;
      _emitPlayerState(
        phaseOverride: PlaybackPhase.loading,
        message: '媒体地址已过期，正在刷新…',
      );
      return _prepareNetworkSource(
        generation: generation,
        video: video,
        part: part,
        quality: _currentQuality,
        reuseSources: false,
      );
    }
    if (failure == WindowsPlaybackFailure.videoDecoder && !_audioOnly) {
      final failed = _activeVideoTrack;
      final sources = _activeSources;
      if (failed == null || sources == null || _localSource) return false;
      _failedVideoTracks.add(_videoTrackKey(failed));
      final fallback = _compatibleVideoTrack(sources);
      if (fallback == null || failed.isAvc) return false;
      _selectVideoAttempts(sources, fallback);
      _emitPlayerState(
        phaseOverride: PlaybackPhase.loading,
        message: '视频解码失败，正在切换当前清晰度的 AVC 线路…',
      );
      return true;
    }
    if (_currentMediaAttemptIndex + 1 >= _mediaAttempts.length) return false;
    _currentMediaAttemptIndex++;
    _emitPlayerState(
      phaseOverride: PlaybackPhase.loading,
      message: '当前播放线路不可用，正在切换备用线路…',
    );
    return true;
  }

  /// Stops a denied stream before presenting the authorization error.
  Future<void> _stopAfterAccessFailure(int generation) async {
    if (!_isCurrentSourceRequest(generation)) return;
    _shouldPlayAfterFallback = false;
    _acceptAttemptErrors = false;
    _cachedSources = null;
    _mediaAttempts = const [];
    await _stopLoadedMedia();
  }

  /// Ends an open early when the current logs and player outputs confirm failure.
  void _throwIfKnownMediaFailure() {
    if (_attemptFailure == WindowsPlaybackFailure.expired ||
        _attemptFailure == WindowsPlaybackFailure.accessDenied ||
        _attemptFailure == WindowsPlaybackFailure.videoDecoder &&
            !_hasDecodedVideo()) {
      throw StateError('Media attempt failed');
    }
  }

  /// 打开一组视频和外部音频地址，先暂停并恢复位置，再挂载音轨和恢复用户原来的播放状态。
  Future<void> _openMediaAttempt(
    WindowsDashMediaAttempt attempt, {
    required int generation,
    required Duration resumePosition,
  }) async {
    if (!_isCurrentSourceRequest(generation)) return;
    // A backup is a different media instance even when its video/CID is unchanged.
    _bufferedRanges = const [];
    _mediaAttemptRevision++;
    _acceptAttemptErrors = false;
    _attemptFailure = WindowsPlaybackFailure.route;
    if (_audioOnly || _mediaLoaded) {
      await _stopLoadedMedia();
      if (!_isCurrentSourceRequest(generation)) return;
    }
    await _applyMediaCachePolicy(
      generation,
      diskAllowed: _currentVideo?.isCourse != true,
    );
    if (!_isCurrentSourceRequest(generation)) return;
    final start = resumePosition > Duration.zero ? resumePosition : null;
    if (_audioOnly) {
      final media = attempt.createAudioMedia(_activeMediaHeaders, start: start);
      _activeAudioMedia = media;
      _acceptAttemptErrors = true;
      await _openPlayerMedia(media, play: false);
      if (!_isCurrentSourceRequest(generation)) return;
      // open/seek 的 Future 只表示命令已接收。先等本次音轨元数据，
      // 再定位；首次真正解码也可能重置时间轴，因此仍保留一次解码后复核。
      _pendingResumePositionAfterDecode = resumePosition;
      if (!await _waitForMediaReady(generation)) {
        if (!_isCurrentSourceRequest(generation)) return;
        throw const DesktopPlaybackSourceException('独立音轨未能完成加载。');
      }
      await _restoreResumePositionAfterDecode(
        generation,
        resumePosition,
        restorePlayback: false,
      );
      if (!_isCurrentSourceRequest(generation)) return;
      if (_isResumePositionBehindTarget(
        _clampResumePositionToMediaDuration(resumePosition),
      )) {
        throw const DesktopPlaybackSourceException('独立音轨未能恢复当前位置。');
      }
      if (_shouldPlayAfterFallback) {
        await _playPlayerMedia(generation);
        if (!await _waitForDecodedAudio(generation)) {
          if (!_isCurrentSourceRequest(generation)) return;
          throw const DesktopPlaybackSourceException('独立音轨未能完成加载。');
        }
        await _restoreResumePositionAfterDecode(generation, resumePosition);
        if (!_isCurrentSourceRequest(generation)) return;
        if (_isResumePositionBehindTarget(
          _clampResumePositionToMediaDuration(resumePosition),
        )) {
          throw const DesktopPlaybackSourceException('独立音轨未能恢复当前位置。');
        }
        _pendingResumePositionAfterDecode = Duration.zero;
      }
      _externalAudioNeedsReload = false;
      return;
    }
    // 保留音频 Media 的强引用，避免 media_kit 的请求头缓存被垃圾回收清掉。
    _activeAudioMedia = attempt.audioUrl.isEmpty
        ? null
        : attempt.createAudioMedia(_activeMediaHeaders, start: start);
    _activeAudioTrackToken = _audioTrackTokenFor(generation);
    final AudioTrack audioTrack = _activeAudioMedia == null
        ? AudioTrack.auto()
        : attempt.createAudioTrack(
            _activeAudioMedia!,
            title: _activeAudioTrackToken,
          );
    // 显式暂停旧媒体，避免新视频准备期间沿用上一条线路的播放状态。
    await _player.pause();
    // 原生命令完成可能晚于换视频；每次继续修改播放器前都复核来源代次。
    if (!_isCurrentSourceRequest(generation)) return;
    _acceptAttemptErrors = true;
    await _openPlayerMedia(
      attempt.createVideoMedia(_activeMediaHeaders, start: start),
      play: false,
    );
    if (!_isCurrentSourceRequest(generation)) return;
    await _player.setVideoTrack(VideoTrack.auto());
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    if (resumePosition > Duration.zero) {
      // Media.start positions the initial request before the external audio mounts.
      _emitPlayerState(
        phaseOverride: PlaybackPhase.loading,
        message: '正在准备音视频…',
      );
    }
    if (!await _validateActiveSession(generation)) return;
    await _player.setAudioTrack(audioTrack);
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    _pendingResumePositionAfterDecode = resumePosition;
    // 外部音轨挂载可能改变底层时间轴；保持暂停并只在发生明显偏移时补一次跳转。
    await _player.pause();
    if (!_isCurrentSourceRequest(generation)) return;
    if (_needsResumePositionCorrection(resumePosition)) {
      await _player.seek(resumePosition);
    }
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    // Source loading can outlive a newer explicit play/pause choice.
    if (_shouldPlayAfterFallback) {
      await _playPlayerMedia(generation);
    } else {
      await _player.pause();
    }
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    // media_kit 的命令返回只代表已接收；实际播放时还要等音视频解码都建立，避免把残缺线路当成功。
    if (_shouldPlayAfterFallback) {
      if (!await _waitForDecodedAudio(generation)) {
        throw const DesktopPlaybackSourceException('当前音视频线路未能建立解码。');
      }
      await _restoreResumePositionAfterDecode(generation, resumePosition);
      if (_isCurrentSourceRequest(generation)) {
        _pendingResumePositionAfterDecode = Duration.zero;
      }
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

  /// 音频真正建立解码后再次检查时间轴；若被外部音轨拉回目标之前，则暂停、重试定位并恢复播放。
  Future<void> _restoreResumePositionAfterDecode(
    int generation,
    Duration resumePosition, {
    bool restorePlayback = true,
  }) async {
    if (!_isCurrentSourceRequest(generation) ||
        !_isResumePositionBehindTarget(resumePosition)) {
      return;
    }
    await _player.pause();
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    final Duration targetPosition = _clampResumePositionToMediaDuration(
      resumePosition,
    );
    final DateTime deadline = DateTime.now().add(
      _resumePositionCorrectionTimeout,
    );
    do {
      await _player.seek(targetPosition);
      if (!_isCurrentSourceRequest(generation)) {
        return;
      }
      await Future<void>.delayed(_resumePositionPollInterval);
    } while (_isResumePositionBehindTarget(targetPosition) &&
        DateTime.now().isBefore(deadline));
    if (!_isCurrentSourceRequest(generation)) {
      return;
    }
    if (!restorePlayback) return;
    if (_shouldPlayAfterFallback) {
      await _playPlayerMedia(generation);
    } else {
      await _player.pause();
    }
  }

  /// 只把明显落在目标之前视为恢复失败；正常播放超过目标位置不需要向后跳。
  bool _isResumePositionBehindTarget(Duration resumePosition) {
    if (resumePosition <= Duration.zero) {
      return false;
    }
    return _player.state.position + _resumePositionTolerance < resumePosition;
  }

  /// 使用播放器已经解析出的真实时长裁剪越界目标，避免外部明确位置或旧记录让纠偏永远无法完成。
  Duration _clampResumePositionToMediaDuration(Duration resumePosition) {
    final Duration duration = _player.state.duration;
    if (duration > Duration.zero && resumePosition > duration) {
      return duration;
    }
    return resumePosition;
  }

  /// 等待 media_kit 暴露当前线路的音视频解码结果；零散底层错误只作为线索，不抢先否定已成功的播放。
  Future<bool> _waitForDecodedAudio(int generation) async {
    final DateTime deadline = DateTime.now().add(_audioDecoderReadyTimeout);
    DateTime? videoReadyAt;
    while (_isCurrentSourceRequest(generation) &&
        DateTime.now().isBefore(deadline)) {
      if (_opening && _acceptAttemptErrors) _throwIfKnownMediaFailure();
      if (_hasDecodedVideo()) {
        if (await _hasDecodedAudio()) {
          return true;
        }
        videoReadyAt ??= DateTime.now();
        if (!DateTime.now().isBefore(
          videoReadyAt.add(_audioAfterVideoReadyTimeout),
        )) {
          return false;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _isCurrentSourceRequest(generation) &&
        _hasDecodedVideo() &&
        await _hasDecodedAudio();
  }

  /// 判断当前视频轨是否已经建立真实解码输出，避免只凭容器时长把纯音频或损坏视频当作成功。
  bool _hasDecodedVideo() {
    if (_audioOnly) return true;
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
    if (_audioOnly ||
        ((_localSource || _currentVideo?.isCourse == true) &&
            _activeAudioMedia == null)) {
      return _hasAudioOutput(params);
    }
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
    required int mediaAttemptRevision,
  }) async {
    /// Rejects delayed checks after a reopen, even if the route index repeats.
    bool isCurrent() =>
        _isCurrentMediaAttempt(generation, mediaAttemptIndex) &&
        mediaAttemptRevision == _mediaAttemptRevision &&
        !_opening;
    if (!isCurrent()) return;
    final DateTime deadline = DateTime.now().add(_mediaErrorHealthCheckTimeout);
    do {
      if (_attemptFailure == WindowsPlaybackFailure.accessDenied ||
          _attemptFailure == WindowsPlaybackFailure.expired &&
              _currentVideo?.isCourse == true) {
        break;
      }
      final bool hasDecodedAudio = await _hasDecodedAudio();
      if (!isCurrent()) return;
      final bool shouldSwitch =
          WindowsPlaybackRecoveryPolicy.shouldSwitchAfterPlayerError(
            isOpening: _opening,
            isBuffering: _player.state.buffering,
            hasVideoOutput: _hasDecodedVideo(),
            hasDecodedAudio: hasDecodedAudio,
          );
      if (!shouldSwitch) {
        _attemptFailure = WindowsPlaybackFailure.route;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    if (!isCurrent()) return;
    await _handleMediaError(
      expectedGeneration: generation,
      expectedMediaAttemptIndex: mediaAttemptIndex,
    );
  }

  /// Coalesces recovery for this generation and preserves the playback intent.
  Future<void> _handleMediaError({
    int? expectedGeneration,
    int? expectedMediaAttemptIndex,
  }) async {
    if (_disposed || _recoveringGeneration == _sourceGeneration) {
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
    final int generation = _sourceGeneration;
    _recoveringGeneration = generation;
    final Duration resumePosition =
        _pendingResumePositionAfterDecode > Duration.zero
        ? _pendingResumePositionAfterDecode
        : _player.state.position;
    final failure =
        _attemptFailure == WindowsPlaybackFailure.videoDecoder &&
            _hasDecodedVideo()
        ? WindowsPlaybackFailure.route
        : _attemptFailure;
    _opening = true;
    _restoringPosition = resumePosition > Duration.zero;
    _emitPlayerState(
      phaseOverride: PlaybackPhase.loading,
      message: '正在尝试恢复播放…',
    );
    try {
      await _openFirstAvailableMedia(
        generation: generation,
        resumePosition: resumePosition,
        previousFailure: failure,
      );
      if (!_isCurrentSourceRequest(generation)) return;
      _opening = false;
      _restoringPosition = false;
      _emitPlayerState(phaseOverride: PlaybackPhase.ready, clearMessage: true);
    } catch (error) {
      if (!_isCurrentSourceRequest(generation)) return;
      _opening = false;
      _restoringPosition = false;
      _acceptAttemptErrors = false;
      _emitPlayerState(
        phaseOverride: PlaybackPhase.error,
        message:
            error is DesktopPlaybackSourceException ||
                error is BilibiliPlaybackSessionException ||
                error is WbiSigningException
            ? error.toString()
            : 'Windows 播放器遇到媒体错误，请重试或切换清晰度。',
      );
    } finally {
      if (_recoveringGeneration == generation) _recoveringGeneration = null;
    }
  }

  /// 开始新的播放源请求并让先前仍在等待网络的分P或清晰度请求立即失效。
  int _beginSourceRequest() {
    _sourceGeneration += 1;
    _acceptAttemptErrors = false;
    _attemptFailure = WindowsPlaybackFailure.route;
    _sourceRefreshes = 0;
    _activeSessionValidator = null;
    if (_loadedCourseAccountRevision == null) {
      _courseExpiry?.cancel();
      _courseExpiry = null;
      _activeCourseReceipt = null;
    }
    _bufferedRanges = const [];
    _restoringPosition = false;
    _restoredPosition = Duration.zero;
    _activeAudioTrackToken = '';
    _externalAudioNeedsReload = false;
    _pendingResumePositionAfterDecode = Duration.zero;
    return _sourceGeneration;
  }

  /// 判断异步播放源结果是否仍属于用户最后一次选择，避免旧分P覆盖新分P。
  bool _isCurrentSourceRequest(int generation) {
    return !_disposed &&
        generation == _sourceGeneration &&
        (_courseAccountRevision == null ||
            _courseAccountRevision == CacheLifecycle.account.value);
  }

  /// 同时核对播放源代次和线路序号，阻止旧错误的延迟核验切换已经成功的新线路。
  bool _isCurrentMediaAttempt(int generation, int mediaAttemptIndex) {
    return _isCurrentSourceRequest(generation) &&
        mediaAttemptIndex == _currentMediaAttemptIndex;
  }

  /// 把 media_kit 即时状态转换为项目统一快照，并计算稳定视频宽高比。
  Future<void> _sampleBufferedRanges() async {
    if (_disposed || _opening || _samplingBuffer) return;
    final platform = _player.platform;
    final read = _bufferStateReader;
    if (read == null && platform is! NativePlayer) return;
    final generation = _sourceGeneration;
    final attempt = _currentMediaAttemptIndex;
    _samplingBuffer = true;
    try {
      final raw = await (read != null
          ? read()
          : (platform as NativePlayer).getProperty('demuxer-cache-state'));
      if (!_isCurrentMediaAttempt(generation, attempt) || _opening) return;
      _bufferedRanges = playbackBufferRangesFromMpv(
        raw,
        duration: _player.state.duration,
      );
      _emitPlayerState();
    } catch (_) {
      if (_isCurrentMediaAttempt(generation, attempt)) {
        _bufferedRanges = const [];
        _emitPlayerState();
      }
    } finally {
      _samplingBuffer = false;
    }
  }

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
    if (phaseOverride == null &&
        phase != PlaybackPhase.ended &&
        phase != PlaybackPhase.error) {
      if (_opening || _player.state.buffering) {
        phase = PlaybackPhase.loading;
      } else if (_player.state.duration > Duration.zero || width > 0) {
        phase = PlaybackPhase.ready;
      }
    }
    _snapshot = PlaybackSnapshot(
      phase: phase,
      isPlaying: _player.state.playing,
      playRequested: _shouldPlayAfterFallback,
      audioOnly: _audioOnly,
      isInPictureInPicture:
          _appleSession.isInPictureInPicture || _linuxMiniPlayer.active,
      sleepTimerRemaining: _sleepDeadline == null
          ? Duration.zero
          : Duration(
              milliseconds: _sleepDeadline!
                  .difference(DateTime.now())
                  .inMilliseconds
                  .clamp(0, 604800000),
            ),
      position: _player.state.position,
      duration: _player.state.duration,
      bufferedRanges: _opening
          ? const []
          : _localSource && _player.state.duration > Duration.zero
          ? [
              PlaybackBufferRange(
                start: Duration.zero,
                end: _player.state.duration,
              ),
            ]
          : _bufferedRanges,
      speed: _player.state.rate,
      currentQuality: _currentQuality,
      availableQualities: _availableQualities,
      videoAspectRatio: width > 0 && height > 0 ? width / height : 16 / 9,
      restoredPosition: _restoredPosition,
      isRestoringPosition: _restoringPosition,
      message: clearMessage ? null : (message ?? _snapshot.message),
    );
    _appleSession.update(
      title: _currentVideo?.title ?? '焦点哔哩',
      position: _snapshot.position,
      duration: _snapshot.duration,
      playing: _snapshot.isPlaying,
      speed: _snapshot.speed,
    );
    _linuxSession.update(
      title: _currentVideo?.title ?? '焦点哔哩',
      volume: (_player.state.volume / 100).clamp(0, 1).toDouble(),
      trackId: '${_currentVideo?.bvid ?? 'none'}_${_currentPart?.cid ?? 0}',
      position: _snapshot.position,
      duration: _snapshot.duration,
      playing: _snapshot.isPlaying,
      speed: _snapshot.speed,
    );
    _stateController.add(_snapshot);
  }

  /// 保存稳定进度；待解码时仅允许暂停或退出用目标位置强制保存，避免写入瞬态零值。
  Future<void> _saveCurrentProgress({bool force = false}) async {
    if (_disposed ||
        _opening ||
        _restoringPosition ||
        _currentVideo == null ||
        _currentPart == null) {
      return;
    }
    final Duration pendingResumePosition = _pendingResumePositionAfterDecode;
    if (!force && pendingResumePosition > Duration.zero) {
      return;
    }
    final Duration duration = _player.state.duration;
    if (duration <= Duration.zero) {
      return;
    }
    final DateTime now = DateTime.now();
    if (!force &&
        _lastProgressSavedAt != null &&
        now.difference(_lastProgressSavedAt!) < _progressSaveInterval) {
      return;
    }
    _lastProgressSavedAt = now;
    final WindowsPlaybackProgressSnapshot progress =
        WindowsPlaybackProgressSnapshot(
          bvid: _currentVideo!.bvid,
          cid: _currentPart!.cid,
          pageNumber: _currentPart!.pageNumber,
          position: pendingResumePosition > Duration.zero
              ? pendingResumePosition
              : _player.state.position,
          duration: duration,
        );
    _progressSaveQueue = _progressSaveQueue.then((_) async {
      try {
        await _progressStore.save(progress);
      } catch (_) {
        // 本机偏好写入失败不能中断播放；队列继续处理下一次更新。
      }
    });
    await _progressSaveQueue;
  }

  /// 在服务已释放后阻止晚到的页面操作继续访问底层播放器。
  void _ensureAvailable() {
    if (_disposed) {
      throw StateError('Windows 播放器已经释放。');
    }
  }
}
