import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/common/watch_history_badge.dart';
import '../../features/notes/video_note_composer.dart';
import '../../features/profile/user_profile_page.dart';
import '../../models/video_note.dart';
import '../../models/video_preview.dart';
import '../../models/video_shot_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../services/device_status_service.dart';
import '../../services/native_playback_service.dart';
import '../../services/player_overlay_service.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/watch_history_service.dart';
import '../../services/video_shot_service.dart';
import '../../services/video_note_service.dart';
import '../../models/player_overlay_data.dart';
import '../../models/danmaku_preferences.dart';
import '../../services/danmaku_preferences_service.dart';

/// 标识一次竖向滑动正在调整亮度、音量，或因底部手势区而不做处理。
enum _VerticalAdjustmentMode { none, brightness, volume }

/// 标识播放器画面应保留比例、裁切填充，还是按容器比例拉伸。
enum _VideoFitMode { contain, cover, stretch }

/// 标识播放器右上角“更多”菜单中可执行的本地播放器设置。
enum _PlayerMoreMenuAction {
  subtitles,
  danmakuSettings,
  fitContain,
  fitCover,
  fitStretch,
}

/// 标识合集展开列表的四种本地排序方式，不改变服务端原始合集顺序。
enum _CollectionEntryOrder { original, newest, oldest, mostPlayed }

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
    this.bilibiliService,
    this.publicContentService,
    this.videoShotService,
    this.videoNoteService,
    this.danmakuPreferencesService,
    this.initialPartCid,
    this.initialPosition,
  });

  final VideoPreview video;
  final PlaybackService? playbackService;
  final WatchHistoryService? watchHistoryService;
  final DeviceStatusService? deviceStatusService;
  final PlayerOverlayService? playerOverlayService;
  final BilibiliService? bilibiliService;
  final BilibiliPublicContentService? publicContentService;
  final VideoShotService? videoShotService;
  final VideoNoteService? videoNoteService;
  final DanmakuPreferencesService? danmakuPreferencesService;
  final int? initialPartCid;
  final Duration? initialPosition;

  /// 创建播放器状态，保存播放、进度、控制层和全屏状态。
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 管理原生视频纹理、播放状态、手势、控制层和系统全屏状态。
class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  static const Duration _controlsAutoHideDelay = Duration(seconds: 5);
  static const Duration _transientHintDuration = Duration(seconds: 3);
  static const Duration _resumeNoticeDuration = _transientHintDuration;
  static const Duration _notesPanelAnimationDuration = Duration(
    milliseconds: 280,
  );
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
  late final BilibiliService _bilibiliService;
  late final BilibiliPublicContentService _publicContentService;
  late final VideoShotService _videoShotService;
  late final VideoNoteService _videoNoteService;
  late VideoPreview _activeVideo;
  late VideoPart _currentPart;
  final List<VideoPreview> _collectionVideoBackStack = <VideoPreview>[];
  final ScrollController _partScrollController = ScrollController();
  final ScrollController _collectionPreviewScrollController =
      ScrollController();
  final TextEditingController _noteTitleController = TextEditingController();
  final TextEditingController _noteBodyController = TextEditingController();
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
  Timer? _playerNoticeTimer;
  Timer? _fullscreenStatusTimer;
  Timer? _notesPanelAnimationTimer;
  double _playbackSpeed = 1;
  int _currentQuality = 64;
  int? _pendingQualitySelection;
  bool _qualitySelectionSawLoading = false;
  String? _playerNotice;
  List<PlaybackQuality> _availableQualities = const <PlaybackQuality>[
    PlaybackQuality(id: 64, label: '高清 720P'),
  ];
  bool _partSelectorExpanded = false;
  bool _partsAscending = true;
  DanmakuPreferences _danmakuPreferences = DanmakuPreferences();
  bool _danmakuPreferencesChangedByUser = false;
  bool _danmakuPersistenceWarningShown = false;
  _VideoFitMode _videoFitMode = _VideoFitMode.contain;
  bool _temporaryDoubleSpeedActive = false;
  bool _horizontalScrubbing = false;
  bool _isRetrying = false;
  bool _descriptionExpanded = false;
  String? _openingCollectionBvid;
  double _speedBeforeLongPress = 1;
  double _horizontalScrubStartProgress = 0;
  double _horizontalScrubTargetProgress = 0;
  double _horizontalScrubStartX = 0;
  double _horizontalSeekSecondsPerPixel = 0;
  double _horizontalSeekMaximumOffsetSeconds = 0;
  VideoShotPreview? _videoShotPreview;
  bool _videoShotLoading = false;
  int _videoShotRequestToken = 0;
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
  late final AnimationController _danmakuFrameController;
  final _DanmakuLanePlanner _danmakuLanePlanner = _DanmakuLanePlanner();
  Duration _danmakuPositionAnchor = Duration.zero;
  List<VideoNote> _currentVideoNotes = const <VideoNote>[];
  VideoNote? _editingVideoNote;
  Duration _notePosition = Duration.zero;
  int _notePartCid = 0;
  bool _notesOpen = false;
  bool _notesOverlayMounted = false;
  bool _notesLoading = false;
  bool _noteSaving = false;
  bool _includeCurrentFrame = false;
  String? _noteFramePath;
  bool _fullscreenNoteListCollapsed = false;
  Duration? _pendingInitialPosition;
  Map<String, WatchHistoryEntry> _watchHistoryByBvid =
      const <String, WatchHistoryEntry>{};
  String? _locatedCollectionPreviewBvid;
  late final DanmakuPreferencesService _danmakuPreferencesService;

  /// 返回配置中的弹幕开关，统一旧播放器代码和持久化模型之间的状态来源。
  bool get _danmakuEnabled => _danmakuPreferences.enabled;

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
    _danmakuFrameController = AnimationController(
      vsync: this,
      duration: const Duration(hours: 1),
    );
    _activeVideo = widget.video;
    _currentPart = _activeVideo.initialPart;
    _notePartCid = _currentPart.cid;
    _playbackService = widget.playbackService ?? NativePlaybackService();
    _watchHistoryService = widget.watchHistoryService ?? WatchHistoryService();
    _deviceStatusService =
        widget.deviceStatusService ?? const NativeDeviceStatusService();
    _playerOverlayService =
        widget.playerOverlayService ?? NativePlayerOverlayService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoShotService = widget.videoShotService ??
        (widget.playbackService == null
            ? BilibiliVideoShotService()
            : const EmptyVideoShotService());
    _videoNoteService = widget.videoNoteService ?? VideoNoteService();
    _danmakuPreferencesService =
        widget.danmakuPreferencesService ?? DanmakuPreferencesService();
    _pendingInitialPosition = widget.initialPosition;
    _playbackSubscription = _playbackService.states.listen(
      _applyPlaybackSnapshot,
    );
    unawaited(_loadWatchHistoryBadges());
    unawaited(_loadDanmakuPreferences());
    unawaited(_initializeNativePlayback());
  }

  /// 启动时恢复全局弹幕配置；旧用户或读取失败由服务返回默认值，页面仍可正常播放。
  Future<void> _loadDanmakuPreferences() async {
    final DanmakuPreferences preferences =
        await _danmakuPreferencesService.load();
    if (!mounted || _danmakuPreferencesChangedByUser) {
      return;
    }
    setState(() => _danmakuPreferences = preferences);
    _danmakuLanePlanner.clear();
    if (preferences.enabled) {
      _ensureDanmakuSegmentsForPosition(_playbackSnapshot.position);
      _syncDanmakuAnimation(_playbackSnapshot);
    }
  }

  /// 读取本机观看记录并按 BV 号索引，供合集封面显示“上次看过”。
  Future<void> _loadWatchHistoryBadges() async {
    final List<WatchHistoryEntry> entries =
        await _watchHistoryService.loadHistory();
    if (!mounted) {
      return;
    }
    setState(() {
      _watchHistoryByBvid = <String, WatchHistoryEntry>{
        for (final WatchHistoryEntry entry in entries) entry.bvid: entry,
      };
    });
  }

  /// 请求 Android 创建 Media3 视频纹理，再直接请求公开视频的播放数据。
  Future<void> _initializeNativePlayback() async {
    try {
      final SavedPlaybackState? savedState =
          await _playbackService.loadSavedPlaybackState(_activeVideo.bvid);
      final SystemPlaybackLevels levels =
          await _playbackService.getSystemPlaybackLevels();
      final VideoPart restoredPart = _findInitialPart(savedState);
      final bool restoredPartMatched = widget.initialPartCid == null &&
          savedState != null &&
          restoredPart.cid == savedState.cid;
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPart = restoredPart;
        _brightness = levels.brightness;
        _volume = levels.volume;
      });
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
      for (final VideoPart part in _activeVideo.parts) {
        if (part.cid == savedState.cid) {
          return part;
        }
      }
    }
    return _activeVideo.initialPart;
  }

  /// 优先定位外部笔记指定的分P，没有指定或编号失效时再恢复本机观看分P。
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
    final Duration? requestedInitialPosition = _pendingInitialPosition;
    final bool shouldSeekToInitialPosition = requestedInitialPosition != null &&
        snapshot.phase == PlaybackPhase.ready;
    final bool shouldShowResumeNotice = requestedInitialPosition == null &&
        snapshot.phase == PlaybackPhase.ready &&
        snapshot.restoredPosition > Duration.zero &&
        _shownRestoredCid != _currentPart.cid;
    if (shouldSeekToInitialPosition) {
      _pendingInitialPosition = null;
    }
    final int? pendingQuality = _pendingQualitySelection;
    final bool sawQualityLoading = pendingQuality != null &&
        (_qualitySelectionSawLoading ||
            snapshot.phase == PlaybackPhase.loading);
    final bool qualitySelectionFinished = pendingQuality != null &&
        sawQualityLoading &&
        (snapshot.phase == PlaybackPhase.ready ||
            snapshot.phase == PlaybackPhase.error);
    final bool qualitySelectionFailed = qualitySelectionFinished &&
        (snapshot.phase == PlaybackPhase.error ||
            snapshot.currentQuality != pendingQuality);
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
        _qualitySelectionSawLoading = false;
      } else if (pendingQuality != null) {
        _qualitySelectionSawLoading = sawQualityLoading;
      }
      if (snapshot.isInPictureInPicture) {
        _showControls = false;
      } else if (leftPictureInPicture) {
        _showControls = true;
      }
    });
    _syncDanmakuAnimation(snapshot);
    if (qualitySelectionFailed) {
      _showMembershipQualityNotice();
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
    }
    if (_danmakuEnabled && snapshot.phase == PlaybackPhase.ready) {
      _ensureDanmakuSegmentsForPosition(snapshot.position);
    }
    if (!snapshot.isPlaying || snapshot.isInPictureInPicture) {
      _stopControlsAutoHideTimer();
    } else if (_showControls && _controlsTimer == null) {
      _restartControlsAutoHideTimer();
    }
  }

  /// 在播放器首次就绪后跳转到笔记要求的时间点，失败时保留可操作的播放页面。
  Future<void> _seekToRequestedInitialPosition(Duration position) async {
    try {
      await _playbackService.seekTo(position);
      if (mounted) {
        _showTransientSnackBar(
          '已跳转到笔记位置：${formatVideoNotePosition(position)}',
        );
      }
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('视频已打开，但暂时无法跳转到笔记时间点。');
      }
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
      final WatchHistoryEntry entry = WatchHistoryEntry(
        bvid: _activeVideo.bvid,
        title: _activeVideo.title,
        ownerName: _activeVideo.ownerName,
        lastPartTitle: _currentPart.title,
        lastPartPageNumber: _currentPart.pageNumber,
        watchedAt: DateTime.now(),
        thumbnailUrl: _activeVideo.thumbnailUrl,
        lastPosition: safePosition,
      );
      final List<WatchHistoryEntry> updated =
          await _watchHistoryService.record(entry);
      if (mounted) {
        setState(() {
          _watchHistoryByBvid = <String, WatchHistoryEntry>{
            for (final WatchHistoryEntry item in updated) item.bvid: item,
          };
        });
      }
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

  /// 离开页面前取消重试状态、订阅和计时器，释放原生资源并恢复竖屏与系统栏。
  @override
  void dispose() {
    _flushCurrentWatchHistoryProgress();
    _isRetrying = false;
    _controlsTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _resumeNoticeTimer?.cancel();
    _playerNoticeTimer?.cancel();
    _fullscreenStatusTimer?.cancel();
    _notesPanelAnimationTimer?.cancel();
    _danmakuFrameController.dispose();
    _partScrollController.dispose();
    _collectionPreviewScrollController.dispose();
    _noteTitleController.dispose();
    _noteBodyController.dispose();
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
        _syncDanmakuAnimation(_playbackSnapshot.copyWith(speed: speed));
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
    unawaited(_loadVideoShotPreview());
  }

  /// 首次横向拖动时按需读取当前分P预览图，并用请求编号忽略切视频后的晚到结果。
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

  /// 切换分P或视频时清除旧截图，避免把上一支视频的画面当成新进度预览。
  void _resetVideoShotPreview() {
    _videoShotRequestToken += 1;
    _videoShotPreview = null;
    _videoShotLoading = false;
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
      if (mounted) {
        setState(() => _playbackSpeed = speed);
        _syncDanmakuAnimation(_playbackSnapshot.copyWith(speed: speed));
      }
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
    if (quality == _currentQuality || _pendingQualitySelection == quality) {
      return;
    }
    _showPlayerControls();
    setState(() {
      _pendingQualitySelection = quality;
      _qualitySelectionSawLoading = false;
      _playerNotice = null;
    });
    _playerNoticeTimer?.cancel();
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

  /// 用播放器内三秒悬浮提示说明高画质切换失败通常与大会员权限有关。
  void _showMembershipQualityNotice([String? details]) {
    if (!mounted) {
      return;
    }
    final String suffix =
        details == null || details.trim().isEmpty ? '' : '（${details.trim()}）';
    _showPlayerNotice('画质切换失败：可能未开通大会员或当前账号无此画质权限$suffix');
  }

  /// 在播放器画面内部显示三秒悬浮提示，避免系统 SnackBar 遮住底部播放栏。
  void _showPlayerNotice(String message) {
    _playerNoticeTimer?.cancel();
    setState(() => _playerNotice = message);
    _playerNoticeTimer = Timer(_transientHintDuration, () {
      if (mounted) {
        setState(() => _playerNotice = null);
      }
    });
  }

  /// 保存旧分P进度后打开新分P，并等待新分P就绪后更新同一 BV 号的观看记录。
  Future<void> _changePart(VideoPart part) async {
    if (part.cid == _currentPart.cid) {
      if (_partSelectorExpanded) {
        _closePartSelector();
      }
      return;
    }
    _flushCurrentWatchHistoryProgress();
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    _resetVideoShotPreview();
    setState(() {
      _currentPart = part;
      _progress = 0;
      _showControls = true;
      _resumeNotice = null;
      _partSelectorExpanded = false;
    });
    _shownRestoredCid = null;
    _recordedHistoryPartCid = null;
    _lastHistorySavedPosition = Duration.zero;
    _resumeNoticeTimer?.cancel();
    try {
      await _playbackService.openVideo(
        _activeVideo,
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
    return SizedBox(
      height: 34,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }

  /// 创建播放器上下栏共用的紧凑图标按钮，缩小视觉占位但保留清晰的点击区域。
  Widget _buildCompactPlayerIconButton({
    Key? key,
    required VoidCallback onPressed,
    required IconData icon,
    required String tooltip,
  }) {
    return IconButton(
      key: key,
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white),
      tooltip: tooltip,
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    );
  }

  /// 创建仅在全屏多分P视频出现的底栏“选集”按钮，普通竖屏改用详情列表。
  Widget _buildPartSelectorControl() {
    if (!_fullscreen || _activeVideo.parts.length <= 1) {
      return const SizedBox.shrink();
    }
    return TextButton(
      key: const Key('part-selector-button'),
      // 选集按钮函数只在横屏显示右侧双列面板。
      onPressed: _openPartSelector,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: const Size(38, 34),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('选集', style: TextStyle(fontSize: 11)),
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

  /// 按当前正序或倒序设置返回用于界面的分P列表副本。
  List<VideoPart> _orderedParts() {
    final List<VideoPart> parts = List<VideoPart>.of(_activeVideo.parts)
      ..sort(
        (VideoPart left, VideoPart right) =>
            left.pageNumber.compareTo(right.pageNumber),
      );
    return _partsAscending ? parts : parts.reversed.toList(growable: false);
  }

  /// 在非全屏详情页恢复横向分P列表，用户不必先进入全屏才能选择分P。
  Widget _buildPartSelector() {
    final List<VideoPart> parts = _orderedParts();
    if (parts.length <= 1) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '选集 · 共 ${parts.length} 集',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const Spacer(),
            TextButton.icon(
              key: const Key('detail-part-selector-expand'),
              onPressed: _openPartSelector,
              icon: const Icon(Icons.grid_view_rounded, size: 17),
              label: const Text('展开'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 58,
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

  /// 打开铺满播放器下方空间的双列选集面板并定位当前分P。
  void _openPartSelector() {
    _stopControlsAutoHideTimer();
    setState(() {
      _partSelectorExpanded = true;
      _showControls = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateCurrentPart());
  }

  /// 关闭展开选集面板，恢复视频信息和单行横向选集。
  void _closePartSelector() {
    setState(() => _partSelectorExpanded = false);
    _restartControlsAutoHideTimer();
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
    _reanchorDanmakuForViewportChange();
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
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      _reanchorDanmakuForViewportChange();
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
      height: 15,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Text(
              _formatFullscreenClock(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                height: 1,
              ),
            ),
            Positioned(
              right: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.battery_full_rounded,
                    color: Colors.white70,
                    size: 12,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    batteryText,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      height: 1,
                    ),
                  ),
                ],
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

  /// 处理顶部返回按钮：先关闭笔记，再退出全屏或返回上一支合集视频。
  void _handleBackPressed() {
    if (_notesOpen) {
      _closeVideoNotes();
    } else if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_collectionVideoBackStack.isNotEmpty) {
      unawaited(_restorePreviousCollectionVideo());
    } else {
      Navigator.of(context).pop();
    }
  }

  /// 接收系统返回结果：依次关闭笔记、全屏和合集内部页面，再允许离开播放页。
  void _handlePopInvoked(bool didPop) {
    if (didPop) {
      return;
    }
    if (_notesOpen) {
      _closeVideoNotes();
    } else if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_collectionVideoBackStack.isNotEmpty) {
      unawaited(_restorePreviousCollectionVideo());
    }
  }

  /// 切换顶部弹幕按钮；实际的片段加载、动画启停和持久化统一交给配置应用函数。
  void _toggleDanmaku() {
    _applyDanmakuPreferences(
      _danmakuPreferences.copyWith(enabled: !_danmakuEnabled),
    );
    _showPlayerControls();
  }

  /// 立即应用已归一化配置；开关会启停当前动画，屏蔽规则会先清队列再加载。
  void _applyDanmakuPreferences(DanmakuPreferences preferences) {
    final bool enabledChanged =
        preferences.enabled != _danmakuPreferences.enabled;
    final bool blockingRulesChanged = !listEquals(
      preferences.blockedKeywords,
      _danmakuPreferences.blockedKeywords,
    );
    _danmakuPreferencesChangedByUser = true;
    setState(() => _danmakuPreferences = preferences);
    _danmakuLanePlanner.clear();
    unawaited(_persistDanmakuPreferences(preferences));

    if (blockingRulesChanged) {
      // 清空已经进入缓存的旧条目并重新请求，使新增屏蔽词立即生效且不留下占轨条目。
      _clearDanmakuForPart();
    }
    if (!preferences.enabled) {
      _danmakuFrameController.stop();
      _danmakuFrameController.value = 0;
      return;
    }
    if (enabledChanged) {
      // 重新开启时允许曾经失败的分段重试，避免本次播放会话一直空白。
      _failedDanmakuSegments.clear();
    }
    if (enabledChanged || blockingRulesChanged) {
      _ensureDanmakuSegmentsForPosition(_playbackSnapshot.position);
      _syncDanmakuAnimation(_playbackSnapshot);
    }
  }

  /// 异步保存当前配置；失败时会话内仍使用新值，并只提示一次“下次启动可能无法恢复”。
  Future<void> _persistDanmakuPreferences(
    DanmakuPreferences preferences,
  ) async {
    final bool saved = await _danmakuPreferencesService.save(preferences);
    if (!mounted) {
      return;
    }
    if (saved) {
      _danmakuPersistenceWarningShown = false;
      return;
    }
    if (!_danmakuPersistenceWarningShown) {
      _danmakuPersistenceWarningShown = true;
      _showTransientSnackBar('弹幕设置已应用，但保存失败；下次启动可能恢复默认值');
    }
  }

  /// 以最新原生位置作为弹幕时间锚点，并在播放期间用 Flutter 帧时钟平滑补齐帧间位移。
  void _syncDanmakuAnimation(PlaybackSnapshot snapshot) {
    _danmakuPositionAnchor = snapshot.position;
    _danmakuFrameController.stop();
    _danmakuFrameController.value = 0;
    if (_danmakuEnabled &&
        snapshot.phase == PlaybackPhase.ready &&
        snapshot.isPlaying &&
        !snapshot.isInPictureInPicture) {
      _danmakuFrameController.forward();
    }
  }

  /// 计算两次原生进度快照之间的平滑弹幕时间，避免旋转时退回到旧锚点。
  Duration _currentDanmakuTimelinePosition() {
    if (!_danmakuFrameController.isAnimating) {
      return _danmakuPositionAnchor;
    }
    final int realElapsedMicroseconds = (_danmakuFrameController.value *
            _danmakuFrameController.duration!.inMicroseconds)
        .round();
    return DanmakuTimeline.advance(
      positionAnchor: _danmakuPositionAnchor,
      realElapsed: Duration(microseconds: realElapsedMicroseconds),
      playbackSpeed: _playbackSpeed,
    );
  }

  /// 横竖屏尺寸变化前后重新建立时间锚点和车道，防止每次切换都累计向左偏移。
  void _reanchorDanmakuForViewportChange() {
    final Duration currentPosition = _currentDanmakuTimelinePosition();
    _danmakuFrameController.stop();
    _danmakuFrameController.value = 0;
    _danmakuPositionAnchor = currentPosition;
    _danmakuLanePlanner.clear();
    if (_danmakuEnabled &&
        _playbackSnapshot.phase == PlaybackPhase.ready &&
        _playbackSnapshot.isPlaying &&
        !_playbackSnapshot.isInPictureInPicture) {
      _danmakuFrameController.forward();
    }
  }

  /// 清理旧分P的弹幕内存与晚到请求，避免切P后在新视频上绘制旧视频文字。
  void _clearDanmakuForPart() {
    _danmakuRequestToken += 1;
    _danmakuFrameController.stop();
    _danmakuFrameController.value = 0;
    _danmakuPositionAnchor = Duration.zero;
    _danmakuSegments.clear();
    _loadingDanmakuSegments.clear();
    _failedDanmakuSegments.clear();
    _danmakuLanePlanner.clear();
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
      bvid: _activeVideo.bvid,
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
      // 屏蔽在进入缓存和车道规划队列前完成，命中的条目不会隐藏后仍占用轨道。
      _danmakuSegments[result.segmentIndex] = result.entries
          .where((DanmakuEntry entry) =>
              !_danmakuPreferences.blocks(entry.content))
          .toList(growable: false);
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
        child: RepaintBoundary(
          child: SizedBox.expand(
            child: CustomPaint(
              key: const Key('danmaku-canvas'),
              painter: _DanmakuPainter(
                entries: _currentDanmakuEntries(),
                positionAnchor: _danmakuPositionAnchor,
                playbackSpeed: _playbackSpeed,
                frameController: _danmakuFrameController,
                lanePlanner: _danmakuLanePlanner,
                preferences: _danmakuPreferences,
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
      bvid: _activeVideo.bvid,
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
      bvid: _activeVideo.bvid,
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
        bottom: 76,
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
      bottom: _showControls ? 76 : 28,
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

  /// 打开弹幕编辑面板；所有滑块、开关和关键词输入都逐次回写父页面，因此当前画面无需重开即可更新。
  Future<void> _showDanmakuSettings() async {
    final TextEditingController keywordsController = TextEditingController(
      text: _danmakuPreferences.blockedKeywords.join('，'),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            final DanmakuPreferences value = _danmakuPreferences;

            /// 同时刷新播放器和面板；模型会把输入截断到文案标注的合法范围，持久化失败不撤回会话值。
            void update(DanmakuPreferences next) {
              _applyDanmakuPreferences(next);
              setSheetState(() {});
            }

            /// 创建带单位、当前值与范围文案的滑块行，透明度等比例值不会被误显示为“0–1”。
            Widget sliderRow({
              required String label,
              required String valueLabel,
              required String rangeLabel,
              required double value,
              required double min,
              required double max,
              required int divisions,
              required ValueChanged<double> onChanged,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('$label：$valueLabel（范围：$rangeLabel）'),
                  Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: onChanged,
                  ),
                ],
              );
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  20,
                  16 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Text(
                        '弹幕设置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SwitchListTile(
                        key: const Key('danmaku-settings-enabled'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('启用弹幕'),
                        value: value.enabled,
                        onChanged: (bool enabled) =>
                            update(value.copyWith(enabled: enabled)),
                      ),
                      sliderRow(
                        label: '透明度',
                        valueLabel: '${(value.opacity * 100).round()}%',
                        rangeLabel: '20%–100%',
                        value: value.opacity,
                        min: DanmakuPreferences.minOpacity,
                        max: DanmakuPreferences.maxOpacity,
                        divisions: 8,
                        onChanged: (double item) =>
                            update(value.copyWith(opacity: item)),
                      ),
                      sliderRow(
                        label: '字号',
                        valueLabel: '${value.fontSize.round()} 逻辑像素',
                        rangeLabel: '10–30 逻辑像素',
                        value: value.fontSize,
                        min: DanmakuPreferences.minFontSize,
                        max: DanmakuPreferences.maxFontSize,
                        divisions: 20,
                        onChanged: (double item) =>
                            update(value.copyWith(fontSize: item)),
                      ),
                      sliderRow(
                        label: '轨道数量',
                        valueLabel: '${value.laneCount} 条',
                        rangeLabel: '1–24 条',
                        value: value.laneCount.toDouble(),
                        min: DanmakuPreferences.minLaneCount.toDouble(),
                        max: DanmakuPreferences.maxLaneCount.toDouble(),
                        divisions: 23,
                        onChanged: (double item) =>
                            update(value.copyWith(laneCount: item.round())),
                      ),
                      sliderRow(
                        label: '滚动时长',
                        valueLabel:
                            '${value.scrollDurationSeconds.round()} 秒/穿屏（越小越快）',
                        rangeLabel: '3–20 秒/穿屏',
                        value: value.scrollDurationSeconds,
                        min: DanmakuPreferences.minScrollDurationSeconds,
                        max: DanmakuPreferences.maxScrollDurationSeconds,
                        divisions: 17,
                        onChanged: (double item) => update(
                          value.copyWith(scrollDurationSeconds: item),
                        ),
                      ),
                      TextField(
                        key: const Key('danmaku-blocked-keywords'),
                        controller: keywordsController,
                        decoration: const InputDecoration(
                          labelText: '屏蔽关键词',
                          helperText: '用逗号或换行分隔；忽略大小写、首尾空格和重复项',
                        ),
                        keyboardType: TextInputType.multiline,
                        minLines: 1,
                        maxLines: 3,
                        onChanged: (String text) => update(
                          value.copyWith(
                            blockedKeywords: text.split(RegExp(r'[,，\n]')),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    keywordsController.dispose();
  }

  /// 根据菜单操作打开字幕或弹幕设置，或切换播放器画面比例。
  void _handleMoreSettingsSelection(_PlayerMoreMenuAction action) {
    switch (action) {
      case _PlayerMoreMenuAction.subtitles:
        unawaited(_showSubtitleSelector());
        return;
      case _PlayerMoreMenuAction.danmakuSettings:
        unawaited(_showDanmakuSettings());
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

  /// 保存用户选择的画面比例，并用三秒提示确认该设置只作用于渲染层。
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

  /// 构建“更多”菜单，提供真实可用的字幕选择和画面比例设置。
  List<PopupMenuEntry<_PlayerMoreMenuAction>> _buildMoreSettingsMenu() {
    return <PopupMenuEntry<_PlayerMoreMenuAction>>[
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
        key: Key('danmaku-settings-menu-item'),
        value: _PlayerMoreMenuAction.danmakuSettings,
        child: Row(children: <Widget>[
          Icon(Icons.tune_rounded),
          SizedBox(width: 8),
          Text('弹幕设置'),
        ]),
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

  /// 创建原生 Texture 视频画面，并在横竖屏中统一应用用户选择的比例模式。
  Widget _buildVideoOutput() {
    final int? textureId = _textureId;
    if (textureId != null) {
      final double aspectRatio = _playbackSnapshot.videoAspectRatio > 0
          ? _playbackSnapshot.videoAspectRatio
          : 16 / 9;
      final Widget texture = RepaintBoundary(
        child: Texture(textureId: textureId),
      );
      return _buildFittedVideoOutput(texture, aspectRatio);
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

  /// 按当前画面比例模式返回保留黑边、裁切填充或拉伸后的 Texture 布局。
  Widget _buildFittedVideoOutput(Widget texture, double aspectRatio) {
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

  /// 将公开统计格式化为紧凑的万或亿单位。
  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.clamp(0, 1 << 31).toString();
  }

  /// 将发布日期格式化为年月日和小时分钟；接口没有日期时返回“日期未知”。
  String _formatPublishedAt(DateTime? value) {
    if (value == null) {
      return '日期未知';
    }
    final String month = value.month.toString().padLeft(2, '0');
    final String day = value.day.toString().padLeft(2, '0');
    final String hour = value.hour.toString().padLeft(2, '0');
    final String minute = value.minute.toString().padLeft(2, '0');
    return '${value.year}-$month-$day $hour:$minute';
  }

  /// 把当前 BV 号复制到系统剪贴板，并用轻量提示确认操作成功。
  Future<void> _copyBvid() async {
    await Clipboard.setData(ClipboardData(text: _activeVideo.bvid));
    if (mounted) {
      _showTransientSnackBar('已复制 ${_activeVideo.bvid}');
    }
  }

  /// 读取当前 BV 的全部笔记，并按视频时间点更新播放器内列表。
  Future<void> _loadCurrentVideoNotes() async {
    try {
      final List<VideoNote> notes =
          await _videoNoteService.loadNotesForVideo(_activeVideo.bvid);
      if (!mounted) {
        return;
      }
      setState(() {
        _currentVideoNotes = notes;
        _notesLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _notesLoading = false);
      _showTransientSnackBar('暂时无法读取本机笔记。');
    }
  }

  /// 打开笔记工作区，并为新笔记锁定按钮按下时的视频位置。
  Future<void> _openVideoNotes() async {
    _stopControlsAutoHideTimer();
    _notesPanelAnimationTimer?.cancel();
    if (_fullscreen) {
      setState(() {
        _notesOverlayMounted = true;
        _notesOpen = false;
        _notesLoading = true;
        _showControls = true;
        _fullscreenNoteListCollapsed = false;
      });
      // 下一帧打开函数让面板先在屏幕右侧完成布局，再平滑滑入可见区域。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _notesOverlayMounted) {
          setState(() => _notesOpen = true);
        }
      });
    } else {
      setState(() {
        _notesOverlayMounted = false;
        _notesOpen = true;
        _notesLoading = true;
        _showControls = true;
        _fullscreenNoteListCollapsed = false;
      });
    }
    _startNewVideoNote();
    await _loadCurrentVideoNotes();
    _restartControlsAutoHideTimer();
  }

  /// 清空编辑器并把当前真实播放位置作为下一条笔记的时间点。
  void _startNewVideoNote() {
    if (!mounted) {
      return;
    }
    setState(() {
      _editingVideoNote = null;
      _noteTitleController.clear();
      _noteBodyController.clear();
      _notePosition = _playbackSnapshot.position;
      _notePartCid = _currentPart.cid;
      _includeCurrentFrame = false;
      _noteFramePath = null;
    });
  }

  /// 关闭播放器内笔记工作区；全屏时等待右滑动画完成后再移除面板。
  void _closeVideoNotes() {
    if (!_notesOpen && !_notesOverlayMounted) {
      return;
    }
    _notesPanelAnimationTimer?.cancel();
    setState(() {
      _notesOpen = false;
      _noteSaving = false;
      _showControls = true;
      _fullscreenNoteListCollapsed = false;
    });
    if (_fullscreen && _notesOverlayMounted) {
      _notesPanelAnimationTimer = Timer(_notesPanelAnimationDuration, () {
        if (mounted && !_notesOpen) {
          setState(() => _notesOverlayMounted = false);
        }
      });
    } else if (_notesOverlayMounted) {
      setState(() => _notesOverlayMounted = false);
    }
    _restartControlsAutoHideTimer();
  }

  /// 按 CID 查找笔记锁定的分P；旧数据缺失时退回当前分P。
  VideoPart _findVideoNotePart(int cid) {
    for (final VideoPart part in _activeVideo.parts) {
      if (part.cid == cid) {
        return part;
      }
    }
    return _currentPart;
  }

  /// 选择已有笔记，填入编辑器并让播放器跳转到该笔记的时间点。
  Future<void> _selectVideoNote(VideoNote note) async {
    final VideoPart targetPart = _findVideoNotePart(note.partCid);
    setState(() {
      _editingVideoNote = note;
      _noteTitleController.text = note.title;
      _noteBodyController.text = note.body;
      _notePosition = note.position;
      _notePartCid = targetPart.cid;
      _includeCurrentFrame = note.framePath != null;
      _noteFramePath = note.framePath;
    });
    try {
      if (targetPart.cid != _currentPart.cid) {
        await _changePart(targetPart);
      }
      await _playbackService.seekTo(note.position);
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('暂时无法跳转到这个笔记的时间点。');
      }
    }
  }

  /// 更新“插入当前画面”选择，取消时只影响本次保存，不立即删除旧文件。
  void _setIncludeCurrentFrame(bool selected) {
    setState(() => _includeCurrentFrame = selected);
  }

  /// 等待原生播放器把目标时间点真正渲染到 Surface，再执行截图。
  Future<void> _waitForNoteFramePosition(Duration target) async {
    for (int attempt = 0; attempt < 30; attempt += 1) {
      final int difference =
          (_playbackSnapshot.position - target).inMilliseconds.abs();
      if (_playbackSnapshot.phase == PlaybackPhase.ready && difference <= 350) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 暂停并跳到笔记锁定的分P和时间点截图，完成后恢复用户原来的播放位置。
  Future<String?> _captureFrameAtNotePosition() async {
    final VideoPart returnPart = _currentPart;
    final Duration returnPosition = _playbackSnapshot.position;
    final bool shouldResume = _playing;
    final VideoPart targetPart = _findVideoNotePart(_notePartCid);
    if (shouldResume) {
      await _playbackService.pause();
    }
    try {
      if (targetPart.cid != _currentPart.cid) {
        await _changePart(targetPart);
        await _playbackService.pause();
      }
      await _playbackService.seekTo(_notePosition);
      await _waitForNoteFramePosition(_notePosition);
      return await _playbackService.captureCurrentFrame();
    } finally {
      if (returnPart.cid != _currentPart.cid) {
        await _changePart(returnPart);
        await _playbackService.pause();
      }
      await _playbackService.seekTo(returnPosition);
      if (shouldResume) {
        await _playbackService.play();
      }
    }
  }

  /// 保存标题、正文、自动记录时间、视频位置和可选画面，再刷新当前视频笔记。
  Future<void> _saveVideoNote() async {
    final String title = _noteTitleController.text.trim();
    if (title.isEmpty) {
      _showTransientSnackBar('请先填写笔记标题。');
      return;
    }
    setState(() => _noteSaving = true);
    String? framePath = _includeCurrentFrame ? _noteFramePath : null;
    try {
      if (_includeCurrentFrame && framePath == null) {
        framePath = await _captureFrameAtNotePosition();
        if (framePath == null) {
          throw PlatformException(
            code: 'frame_capture_failed',
            message: '没有取得当前视频画面。',
          );
        }
      }
      final DateTime now = DateTime.now();
      final VideoNote? existing = _editingVideoNote;
      final VideoPart notePart = _findVideoNotePart(_notePartCid);
      final VideoNote note = existing == null
          ? VideoNote(
              id: '${_activeVideo.bvid}-${now.microsecondsSinceEpoch}',
              bvid: _activeVideo.bvid,
              videoTitle: _activeVideo.title,
              ownerName: _activeVideo.ownerName,
              partCid: notePart.cid,
              partPageNumber: notePart.pageNumber,
              partTitle: notePart.title,
              title: title,
              body: _noteBodyController.text.trim(),
              createdAt: now,
              updatedAt: now,
              position: _notePosition,
              videoCoverUrl: _activeVideo.thumbnailUrl,
              framePath: framePath,
            )
          : existing.copyWith(
              title: title,
              body: _noteBodyController.text.trim(),
              updatedAt: now,
              position: _notePosition,
              framePath: framePath,
              clearFrame: !_includeCurrentFrame,
            );
      await _videoNoteService.saveNote(note);
      if (!mounted) {
        return;
      }
      setState(() {
        _editingVideoNote = note;
        _noteFramePath = note.framePath;
        _noteSaving = false;
        _notesLoading = true;
      });
      await _loadCurrentVideoNotes();
      if (mounted) {
        _showTransientSnackBar('笔记已保存到本机。');
      }
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _noteSaving = false);
      _showTransientSnackBar(error.message ?? '截取当前视频画面失败。');
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _noteSaving = false);
      _showTransientSnackBar('保存笔记失败，请稍后再试。');
    }
  }

  /// 删除正在编辑的笔记及其画面文件，并回到新的当前时间点草稿。
  Future<void> _deleteEditingVideoNote() async {
    final VideoNote? note = _editingVideoNote;
    if (note == null) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除“${note.title}”吗？此操作无法撤销。'),
        actions: <Widget>[
          TextButton(
            // 取消删除函数关闭确认框并保留播放器中的笔记。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认删除函数把决定返回播放器，再由本机服务清理笔记和截图。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _noteSaving = true);
    try {
      await _videoNoteService.deleteNote(note.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _noteSaving = false;
        _notesLoading = true;
      });
      _startNewVideoNote();
      await _loadCurrentVideoNotes();
      if (mounted) {
        _showTransientSnackBar('笔记已删除。');
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _noteSaving = false);
      _showTransientSnackBar('删除笔记失败，请稍后再试。');
    }
  }

  /// 创建低流量缓存封面或头像，失败时显示固定占位图标。
  Widget _buildDetailImage(
    String url, {
    required double width,
    required double height,
    required BoxFit fit,
    IconData placeholderIcon = Icons.image_outlined,
  }) {
    if (url.isEmpty) {
      return _buildDetailImagePlaceholder(
        width,
        height,
        placeholderIcon,
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: const <String, String>{
        'Referer': 'https://www.bilibili.com/',
      },
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: 480,
      maxWidthDiskCache: 720,
      placeholder: (BuildContext context, String value) =>
          _buildDetailImagePlaceholder(width, height, placeholderIcon),
      errorWidget: (BuildContext context, String value, Object error) =>
          _buildDetailImagePlaceholder(width, height, placeholderIcon),
    );
  }

  /// 创建详情远程图片加载中或失败时使用的固定尺寸占位。
  Widget _buildDetailImagePlaceholder(
    double width,
    double height,
    IconData icon,
  ) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceVariant,
        child: Icon(icon),
      ),
    );
  }

  /// 暂停当前视频后打开 UP 主公开主页，返回时按进入前状态恢复播放。
  Future<void> _openOwnerProfile() async {
    if (_activeVideo.ownerMid <= 0) {
      _showPlayerNotice('暂时没有这个 UP 主的主页编号');
      return;
    }
    final bool shouldResume = _playing;
    if (shouldResume) {
      await _playbackService.pause();
    }
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 用户主页构建函数传入已有昵称头像，并复用公开内容服务。
        builder: (BuildContext context) => UserProfilePage(
          mid: _activeVideo.ownerMid,
          initialName: _activeVideo.ownerName,
          initialAvatarUrl: _activeVideo.ownerAvatarUrl,
          publicContentService: _publicContentService,
          videoService: _bilibiliService,
          watchHistoryService: _watchHistoryService,
        ),
      ),
    );
    if (mounted && shouldResume && !_playing) {
      await _playbackService.play();
    }
  }

  /// 查询合集条目的完整详情，再在当前原生播放器中切换，避免旧页面销毁新播放器。
  Future<void> _openCollectionVideo(VideoCollectionEntry entry) async {
    if (_openingCollectionBvid != null || entry.bvid == _activeVideo.bvid) {
      return;
    }
    setState(() => _openingCollectionBvid = entry.bvid);
    try {
      final VideoPreview video = await _bilibiliService.lookupVideo(entry.bvid);
      final VideoPreview previousVideo = _activeVideo;
      await _switchActiveVideo(video);
      _collectionVideoBackStack.add(previousVideo);
    } catch (error) {
      if (mounted) {
        _showPlayerNotice('无法打开合集视频：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _openingCollectionBvid = null);
      }
    }
  }

  /// 复用现有纹理打开另一支视频，并完整重置旧视频的分P、字幕、弹幕和历史状态。
  Future<void> _switchActiveVideo(VideoPreview video) async {
    _notesPanelAnimationTimer?.cancel();
    _flushCurrentWatchHistoryProgress();
    await _playbackService.pause();
    final SavedPlaybackState? savedState =
        await _playbackService.loadSavedPlaybackState(video.bvid);
    VideoPart targetPart = video.initialPart;
    if (savedState != null) {
      for (final VideoPart part in video.parts) {
        if (part.cid == savedState.cid) {
          targetPart = part;
          break;
        }
      }
    }
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    _resetVideoShotPreview();
    if (!mounted) {
      return;
    }
    setState(() {
      _activeVideo = video;
      _currentPart = targetPart;
      _playbackSnapshot = _playbackSnapshot.copyWith(
        phase: PlaybackPhase.loading,
        isPlaying: false,
        position: Duration.zero,
        duration: Duration.zero,
        restoredPosition: Duration.zero,
        clearMessage: true,
      );
      _progress = 0;
      _showControls = true;
      _partSelectorExpanded = false;
      _descriptionExpanded = false;
      _resumeNotice = null;
      _notesOpen = false;
      _notesLoading = false;
      _noteSaving = false;
      _currentVideoNotes = const <VideoNote>[];
      _editingVideoNote = null;
      _noteTitleController.clear();
      _noteBodyController.clear();
      _notePartCid = targetPart.cid;
      _includeCurrentFrame = false;
      _noteFramePath = null;
      _fullscreenNoteListCollapsed = false;
      _notesOverlayMounted = false;
      _locatedCollectionPreviewBvid = null;
    });
    _shownRestoredCid = null;
    _recordedHistoryPartCid = null;
    _lastHistorySavedPosition = Duration.zero;
    _resumeNoticeTimer?.cancel();
    await _playbackService.openVideo(
      video,
      part: targetPart,
      quality: _currentQuality,
    );
    if (savedState != null && video.parts.length > 1) {
      _showPartRestoreSnackBar(targetPart.pageNumber);
    }
  }

  /// 裁切雪碧图中的一格并按统一宽度缩放，避免下载大量独立截图。
  Widget _buildVideoShotFrame(VideoShotFrame frame) {
    const double displayWidth = 176;
    final double scale = displayWidth / frame.frameWidth;
    final double displayHeight = frame.frameHeight * scale;
    final double sheetWidth = frame.frameWidth * frame.sheetColumns * scale;
    final double sheetHeight = frame.frameHeight * frame.sheetRows * scale;
    return ClipRRect(
      key: const Key('video-shot-frame'),
      borderRadius: BorderRadius.circular(8),
      child: ClipRect(
        child: SizedBox(
          width: displayWidth,
          height: displayHeight,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              Positioned(
                left: -frame.column * frame.frameWidth * scale,
                top: -frame.row * frame.frameHeight * scale,
                width: sheetWidth,
                height: sheetHeight,
                child: CachedNetworkImage(
                  imageUrl: frame.imageUrl,
                  width: sheetWidth,
                  height: sheetHeight,
                  fit: BoxFit.fill,
                  errorWidget:
                      (BuildContext context, String url, Object error) =>
                          const ColoredBox(color: Colors.black26),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建横向拖动中央预览卡；无截图时仍显示准确目标时间。
  Widget _buildSeekFeedback() {
    final Duration target = Duration(
      milliseconds:
          (_displayDuration.inMilliseconds * _horizontalScrubTargetProgress)
              .round(),
    );
    final VideoShotFrame? frame =
        _horizontalScrubbing ? _videoShotPreview?.frameFor(target) : null;
    return Center(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _seekFeedback == null ? 0 : 1,
          duration: const Duration(milliseconds: 160),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (frame != null) _buildVideoShotFrame(frame),
                  if (_horizontalScrubbing && _videoShotLoading) ...<Widget>[
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    _seekFeedback ?? '',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 从合集内部返回栈取出上一支视频，使返回键符合“回到切换前视频”的预期。
  Future<void> _restorePreviousCollectionVideo() async {
    if (_openingCollectionBvid != null || _collectionVideoBackStack.isEmpty) {
      return;
    }
    final VideoPreview previousVideo = _collectionVideoBackStack.removeLast();
    setState(() => _openingCollectionBvid = previousVideo.bvid);
    try {
      await _switchActiveVideo(previousVideo);
    } catch (error) {
      _collectionVideoBackStack.add(previousVideo);
      if (mounted) {
        _showPlayerNotice('无法返回上一支合集视频：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _openingCollectionBvid = null);
      }
    }
  }

  /// 打开当前合集的底部列表，让用户在同一播放器内选择其他独立视频。
  Future<void> _showCollectionSheet(VideoCollection collection) async {
    final VideoCollectionEntry? selected =
        await showModalBottomSheet<VideoCollectionEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // 合集面板构建函数提供搜索、排序、当前位置与本机观看标记。
      builder: (BuildContext sheetContext) => _CollectionPickerSheet(
        collection: collection,
        currentBvid: _activeVideo.bvid,
        watchHistoryByBvid: _watchHistoryByBvid,
      ),
    );
    if (selected != null && mounted && selected.bvid != _activeVideo.bvid) {
      await _openCollectionVideo(selected);
    }
  }

  /// 创建只读互动统计项，不伪装未实现的点赞、投币或收藏写操作。
  Widget _buildReadOnlyStat(IconData icon, String label, int value) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 25),
          const SizedBox(height: 4),
          Text(
            value > 0 ? _formatCount(value) : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 创建标题、播放统计、简介和 BV 编号信息区，不显示评论或发弹幕入口。
  Widget _buildVideoDescription() {
    final VideoStats stats = _activeVideo.stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _activeVideo.title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: <Widget>[
            _DetailMeta(
              icon: Icons.play_circle_outline_rounded,
              text: '${_formatCount(stats.viewCount)}播放',
            ),
            _DetailMeta(
              icon: Icons.subtitles_outlined,
              text: '${_formatCount(stats.danmakuCount)}弹幕',
            ),
            _DetailMeta(
              icon: Icons.calendar_today_outlined,
              text: _formatPublishedAt(_activeVideo.publishedAt),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: '长按复制 BV 号',
          child: InkWell(
            key: const Key('copy-bvid'),
            // BV 文字长按函数只复制 BV 号，旁边显示的 AV 号不会混入剪贴板。
            onLongPress: () => unawaited(_copyBvid()),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _activeVideo.aid > 0
                    ? '${_activeVideo.bvid}  AV${_activeVideo.aid}'
                    : _activeVideo.bvid,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        if (_activeVideo.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          InkWell(
            // 简介点击函数在两行摘要和完整文字之间切换。
            onTap: () => setState(
              () => _descriptionExpanded = !_descriptionExpanded,
            ),
            child: Text(
              _activeVideo.description,
              maxLines: _descriptionExpanded ? null : 3,
              overflow: _descriptionExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
          ),
        ],
        if (_activeVideo.tags.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Wrap(
            key: const Key('video-tags'),
            spacing: 8,
            runSpacing: 6,
            children: _activeVideo.tags
                .map(
                  (String tag) => Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(tag),
                  ),
                )
                .toList(growable: false),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: <Widget>[
            _buildReadOnlyStat(
                Icons.thumb_up_alt_outlined, '点赞', stats.likeCount),
            _buildReadOnlyStat(Icons.paid_outlined, '投币', stats.coinCount),
            _buildReadOnlyStat(
                Icons.star_border_rounded, '收藏', stats.favoriteCount),
            _buildReadOnlyStat(Icons.share_outlined, '分享', stats.shareCount),
          ],
        ),
      ],
    );
  }

  /// 将合集视频时长格式化为分秒或时分秒，供封面右下角紧凑显示。
  String _formatCollectionDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 1 << 31).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 将合集条目的发布日期格式化为年月日，日期缺失时返回稳定占位文字。
  String _formatCollectionPublishedDate(DateTime? value) {
    if (value == null) {
      return '日期未知';
    }
    final DateTime local = value.toLocal();
    return '${local.year}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  /// 在合集预览首次出现或切换视频后，把横向列表平滑定位到当前视频。
  void _scheduleCollectionPreviewLocation(VideoCollection collection) {
    final String currentBvid = _activeVideo.bvid;
    if (_locatedCollectionPreviewBvid == currentBvid) {
      return;
    }
    final int currentIndex = collection.indexOfBvid(currentBvid);
    if (currentIndex < 0) {
      return;
    }
    _locatedCollectionPreviewBvid = currentBvid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_collectionPreviewScrollController.hasClients) {
        _locatedCollectionPreviewBvid = null;
        return;
      }
      final ScrollPosition position =
          _collectionPreviewScrollController.position;
      final double target =
          (currentIndex * 340.0).clamp(0, position.maxScrollExtent).toDouble();
      if ((position.pixels - target).abs() < 1) {
        return;
      }
      _collectionPreviewScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// 创建一条横向合集视频预览，封面、标题和统计密度参考移动端视频列表。
  Widget _buildCollectionPreviewRow(VideoCollectionEntry entry) {
    final bool current = entry.bvid == _activeVideo.bvid;
    final bool opening = _openingCollectionBvid == entry.bvid;
    final WatchHistoryEntry? watchHistory = _watchHistoryByBvid[entry.bvid];
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: current
          ? colors.primaryContainer.withOpacity(0.32)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('collection-preview-${entry.bvid}'),
        // 合集视频行点击函数在当前播放器中切换到所选视频。
        onTap: current || opening
            ? null
            : () => unawaited(_openCollectionVideo(entry)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: <Widget>[
                    _buildDetailImage(
                      entry.thumbnailUrl,
                      width: 156,
                      height: 88,
                      fit: BoxFit.cover,
                      placeholderIcon: Icons.video_library_outlined,
                    ),
                    if (watchHistory != null && !current)
                      Positioned(
                        left: 5,
                        top: 5,
                        child: WatchHistoryBadge(
                          entry: watchHistory,
                          showPosition: false,
                        ),
                      ),
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            _formatCollectionDuration(entry.duration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (current)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black45,
                          child: Center(
                            child: Text(
                              '正在播放',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      )
                    else if (opening)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black38,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 88,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _PartTitleMarquee(
                        key: Key('collection-title-${entry.bvid}'),
                        text: entry.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatCollectionPublishedDate(entry.publishedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.play_circle_outline_rounded,
                            size: 15,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _formatCount(entry.stats.viewCount),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.subtitles_outlined,
                            size: 15,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _formatCount(entry.stats.danmakuCount),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.more_vert_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建当前视频所属 UGC 合集入口和横向滑动的视频预览，恢复原来的紧凑布局。
  Widget _buildCollectionPanel(VideoCollection collection) {
    final int currentIndex = collection.indexOfBvid(_activeVideo.bvid);
    _scheduleCollectionPreviewLocation(collection);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('video-collection-card'),
            // 合集头部点击函数打开完整合集选择面板。
            onTap: () => unawaited(_showCollectionSheet(collection)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.collections_bookmark_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '合集 · ${collection.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    currentIndex >= 0
                        ? '${currentIndex + 1}/${collection.totalCount}'
                        : '${collection.totalCount}支',
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 100,
          child: ListView.separated(
            key: const Key('collection-preview-list'),
            controller: _collectionPreviewScrollController,
            scrollDirection: Axis.horizontal,
            cacheExtent: 680,
            itemCount: collection.entries.length,
            // 分隔函数为相邻合集预览保留固定的横向间距。
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(width: 10),
            // 构建函数复用带封面与统计的预览行，并限制成可横向滑动的紧凑卡片。
            itemBuilder: (BuildContext context, int index) => SizedBox(
              width: 330,
              child: _buildCollectionPreviewRow(collection.entries[index]),
            ),
          ),
        ),
      ],
    );
  }

  /// 创建播放器笔记编辑器，并把保存、删除、画面选择等操作连接到本机服务。
  Widget _buildVideoNoteComposer({required bool compact}) {
    return VideoNoteComposer(
      titleController: _noteTitleController,
      bodyController: _noteBodyController,
      position: _notePosition,
      createdAt: _editingVideoNote?.createdAt,
      includeFrame: _includeCurrentFrame,
      framePath: _noteFramePath,
      saving: _noteSaving,
      onIncludeFrameChanged: _setIncludeCurrentFrame,
      // 保存函数自动写入记录时间、视频时间点和用户选择的当前画面。
      onSave: () => unawaited(_saveVideoNote()),
      onNew: _startNewVideoNote,
      onClose: _closeVideoNotes,
      onDelete: _editingVideoNote == null
          ? null
          : () => unawaited(_deleteEditingVideoNote()),
      compact: compact,
      borderless: true,
    );
  }

  /// 创建竖屏笔记顶部的横向时间点列表，点按后跳转视频并编辑该笔记。
  Widget _buildPortraitVideoNoteStrip() {
    if (_notesLoading) {
      return const SizedBox(
        height: 52,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_currentVideoNotes.isEmpty) {
      return const SizedBox(
        height: 52,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('这个视频还没有笔记，先写下第一条吧。'),
        ),
      );
    }
    return SizedBox(
      height: 56,
      child: ListView.separated(
        key: const Key('portrait-video-note-list'),
        scrollDirection: Axis.horizontal,
        itemCount: _currentVideoNotes.length,
        // 分隔函数给横向笔记卡片保留稳定间距。
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 8),
        // 构建函数显示笔记标题与视频时间点，并标出当前编辑项。
        itemBuilder: (BuildContext context, int index) {
          final VideoNote note = _currentVideoNotes[index];
          final bool selected = note.id == _editingVideoNote?.id;
          return SizedBox(
            width: 146,
            child: Card(
              margin: EdgeInsets.zero,
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: InkWell(
                key: Key('portrait-video-note-${note.id}'),
                borderRadius: BorderRadius.circular(12),
                // 竖屏笔记卡点击函数跳转到笔记位置并填入编辑器。
                onTap: () => unawaited(_selectVideoNote(note)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        formatVideoNotePosition(note.position),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 创建播放器下方的竖屏笔记工作区，打开后页面不再使用可折叠播放器。
  Widget _buildPortraitVideoNotesPanel() {
    return Material(
      key: const Key('portrait-video-notes-panel'),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Column(
          children: <Widget>[
            _buildPortraitVideoNoteStrip(),
            const SizedBox(height: 5),
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: _buildVideoNoteComposer(compact: false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建全屏笔记本左侧的竖向笔记列表，标题溢出时自动横向滚动。
  Widget _buildFullscreenVideoNoteList() {
    if (_notesLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_currentVideoNotes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('暂无笔记'),
        ),
      );
    }
    return ListView.separated(
      key: const Key('fullscreen-video-note-list'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      itemCount: _currentVideoNotes.length,
      // 分隔函数给全屏笔记时间线保留紧凑间距。
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 6),
      // 构建函数显示可自动滚动的标题和视频时间点，并支持点击跳转。
      itemBuilder: (BuildContext context, int index) {
        final VideoNote note = _currentVideoNotes[index];
        final bool selected = note.id == _editingVideoNote?.id;
        final ColorScheme colors = Theme.of(context).colorScheme;
        return Material(
          color:
              selected ? colors.primary.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            key: Key('fullscreen-video-note-${note.id}'),
            borderRadius: BorderRadius.circular(9),
            // 全屏笔记点击函数跳转到对应视频位置并载入标题、正文和画面。
            onTap: () => unawaited(_selectVideoNote(note)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 3,
                    height: 32,
                    decoration: BoxDecoration(
                      color: selected ? colors.primary : colors.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          height: 18,
                          child: _AutoScrollingText(
                            text: note.title,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          formatVideoNotePosition(note.position),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 收起或展开全屏笔记列表，让用户按需要把横向空间让给正文编辑器。
  void _toggleFullscreenNoteList() {
    setState(() {
      _fullscreenNoteListCollapsed = !_fullscreenNoteListCollapsed;
    });
  }

  /// 创建更宽且紧凑的半透明全屏笔记本，为无边框正文保留主要编辑空间。
  Widget _buildFullscreenVideoNotesPanel(double playerWidth) {
    return Positioned(
      key: const Key('fullscreen-video-notes-panel'),
      top: 10,
      right: 10,
      bottom: 10,
      width: playerWidth * 0.64,
      child: AnimatedSlide(
        key: const Key('fullscreen-video-notes-slide'),
        offset: _notesOpen ? Offset.zero : const Offset(1.08, 0),
        duration: _notesPanelAnimationDuration,
        curve: _notesOpen ? Curves.easeOutCubic : Curves.easeInCubic,
        child: Material(
          key: const Key('fullscreen-video-notes-material'),
          elevation: 18,
          color: Theme.of(context).colorScheme.surface.withOpacity(0.9),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            bottom: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: _fullscreenNoteListCollapsed ? 46 : playerWidth * 0.17,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (_fullscreenNoteListCollapsed) ...<Widget>[
                        const SizedBox(height: 6),
                        IconButton(
                          key: const Key('expand-fullscreen-note-list'),
                          // 展开按钮函数恢复左侧笔记标题和时间点列表。
                          onPressed: _toggleFullscreenNoteList,
                          icon: const Icon(Icons.chevron_right_rounded),
                          tooltip: '展开笔记列表',
                        ),
                        Text(
                          '${_currentVideoNotes.length}',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ] else ...<Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(5, 6, 8, 3),
                          child: Row(
                            children: <Widget>[
                              IconButton(
                                key: const Key('collapse-fullscreen-note-list'),
                                // 收起按钮函数仅保留一条窄边栏，为标题和正文增加空间。
                                onPressed: _toggleFullscreenNoteList,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(
                                  width: 32,
                                  height: 32,
                                ),
                                padding: EdgeInsets.zero,
                                iconSize: 20,
                                icon: const Icon(Icons.chevron_left_rounded),
                                tooltip: '收起笔记列表',
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  '笔记',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ),
                              Text(
                                '${_currentVideoNotes.length}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                        Expanded(child: _buildFullscreenVideoNoteList()),
                      ],
                    ],
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: _buildVideoNoteComposer(compact: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 创建全屏右侧中部的半透明记笔记按钮，打开后由半屏笔记本替代。
  Widget _buildFullscreenVideoNoteButton() {
    return Positioned(
      key: const Key('fullscreen-note-button'),
      right: 12,
      top: 0,
      bottom: 0,
      child: Center(
        child: Material(
          color: Colors.black.withOpacity(0.58),
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            // 全屏记笔记按钮函数打开工作区并锁定当前播放时间点。
            onTap: () => unawaited(_openVideoNotes()),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.edit_note_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 5),
                  Text('记笔记', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 创建可进入公开主页的 UP 主资料卡，不提供关注或私信写操作。
  Widget _buildOwnerPanel() {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const Key('video-owner-card'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: ClipOval(
          child: _buildDetailImage(
            _activeVideo.ownerAvatarUrl,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            placeholderIcon: Icons.person_rounded,
          ),
        ),
        title: Text(
          _activeVideo.ownerName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          _activeVideo.ownerMid > 0 ? 'UID：${_activeVideo.ownerMid}' : 'UP 主',
        ),
        trailing: _activeVideo.ownerMid > 0
            ? const Icon(Icons.chevron_right_rounded)
            : null,
        // UP 主卡点击函数暂停视频后进入公开主页。
        onTap: _activeVideo.ownerMid > 0
            ? () => unawaited(_openOwnerProfile())
            : null,
      ),
    );
  }

  /// 创建可放入统一页面滚动中的简介区，并在普通竖屏保留分P和合集内容。
  Widget _buildNonFullscreenDetails() {
    final VideoCollection? collection = _activeVideo.collection;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                '简介',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('portrait-note-button'),
                // 竖屏记笔记按钮函数在播放器下方打开编辑区，并固定播放器高度。
                onPressed: () => unawaited(_openVideoNotes()),
                icon: const Icon(Icons.edit_note_rounded, size: 20),
                label: const Text('记笔记'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 12),
          _buildVideoDescription(),
          if (_activeVideo.parts.length > 1) ...<Widget>[
            const SizedBox(height: 18),
            _buildPartSelector(),
          ],
          if (collection != null) ...<Widget>[
            const SizedBox(height: 20),
            _buildCollectionPanel(collection),
          ],
          const SizedBox(height: 20),
          _buildOwnerPanel(),
        ],
      ),
    );
  }

  /// 创建播放器与详情共用的竖向滚动，向上滑动时按距离连续压缩播放器直到完全隐藏。
  Widget _buildCollapsingPlayerBody({
    required Widget player,
    required double playerHeight,
  }) {
    return CustomScrollView(
      key: const Key('collapsing-player-scroll'),
      slivers: <Widget>[
        SliverPersistentHeader(
          delegate: _CollapsingPlayerHeaderDelegate(
            maximumHeight: playerHeight,
            child: player,
          ),
        ),
        SliverToBoxAdapter(child: _buildNonFullscreenDetails()),
      ],
    );
  }

  /// 创建播放器画面、手势、可点击错误重试层、控制层以及非全屏时的视频信息区域。
  @override
  Widget build(BuildContext context) {
    final bool inPictureInPicture = _playbackSnapshot.isInPictureInPicture;
    // 错误或选集展开时关闭底层画面手势，避免父级手势抢走重试与选集按钮点击。
    final bool enableSurfaceGestures =
        _playbackSnapshot.phase != PlaybackPhase.error &&
            !_partSelectorExpanded;
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
            // 全屏竖向手势开始函数判断左侧亮度、右侧音量和上下安全区；竖屏把手势交给页面滚动。
            onVerticalDragStart: _fullscreen && enableSurfaceGestures
                ? (DragStartDetails details) => _startVerticalAdjustment(
                      details,
                      constraints.biggest,
                      MediaQuery.of(context).viewPadding.top,
                      MediaQuery.of(context).viewPadding.bottom,
                    )
                : null,
            // 全屏竖向手势更新函数实时调整窗口亮度或媒体音量。
            onVerticalDragUpdate: _fullscreen && enableSurfaceGestures
                ? (DragUpdateDetails details) =>
                    _updateVerticalAdjustment(details, constraints.maxHeight)
                : null,
            // 全屏竖向手势结束函数恢复控制栏自动隐藏计时。
            onVerticalDragEnd: _fullscreen && enableSurfaceGestures
                ? _finishVerticalAdjustment
                : null,
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
                  _buildSeekFeedback(),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    left: 24,
                    right: 24,
                    bottom: _showControls ? 58 : 10,
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
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    top: _fullscreen ? 72 : 52,
                    left: 24,
                    right: 24,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _playerNotice == null ? 0 : 1,
                        duration: const Duration(milliseconds: 160),
                        child: Center(
                          child: DecoratedBox(
                            key: _playerNotice == null
                                ? null
                                : const Key('player-floating-notice'),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.82),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 7,
                              ),
                              child: Text(
                                _playerNotice ?? '',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
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
                              height: _fullscreen ? 62 : 44,
                              child: SafeArea(
                                key: const Key('top-player-bar'),
                                top: false,
                                bottom: false,
                                minimum: const EdgeInsets.only(
                                  top: 2,
                                  left: 2,
                                  right: 8,
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
                                          _buildCompactPlayerIconButton(
                                            // 返回按钮函数在全屏时先退出全屏，否则关闭播放器页面。
                                            onPressed: _handleBackPressed,
                                            icon: Icons.arrow_back_rounded,
                                            tooltip: '返回',
                                          ),
                                          if (_fullscreen)
                                            Expanded(
                                              child: _AutoScrollingText(
                                                text: _activeVideo.title,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          if (!_fullscreen) const Spacer(),
                                          _buildCompactPlayerIconButton(
                                            key:
                                                const Key('picture-in-picture'),
                                            // 画中画按钮函数调用 Android 原生小窗能力。
                                            onPressed: () => unawaited(
                                                _enterPictureInPicture()),
                                            icon: Icons
                                                .picture_in_picture_alt_rounded,
                                            tooltip: '画中画',
                                          ),
                                          _buildCompactPlayerIconButton(
                                            key: const Key('danmaku-toggle'),
                                            // 弹幕按钮函数开启或关闭当前分P的真实弹幕绘制与预取。
                                            onPressed: _toggleDanmaku,
                                            icon: _danmakuEnabled
                                                ? Icons.subtitles_rounded
                                                : Icons.subtitles_off_rounded,
                                            tooltip: _danmakuEnabled
                                                ? '关闭弹幕'
                                                : '开启弹幕',
                                          ),
                                          SizedBox(
                                            width: 38,
                                            height: 38,
                                            child: PopupMenuButton<
                                                _PlayerMoreMenuAction>(
                                              key: const Key(
                                                  'more-settings-menu'),
                                              tooltip: '更多选项',
                                              padding: EdgeInsets.zero,
                                              iconSize: 22,
                                              icon: const Icon(
                                                Icons.more_vert_rounded,
                                                color: Colors.white,
                                              ),
                                              // 更多菜单选择函数更新字幕或 Flutter 画面比例，不改变播放源。
                                              onSelected:
                                                  _handleMoreSettingsSelection,
                                              // 更多菜单构建函数只展示已经真实接入的选项。
                                              itemBuilder:
                                                  (BuildContext context) =>
                                                      _buildMoreSettingsMenu(),
                                            ),
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
                                minimum: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 1.2,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 3.5,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                          overlayRadius: 8,
                                        ),
                                      ),
                                      child: SizedBox(
                                        height: 15,
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
                                    ),
                                    SizedBox(
                                      height: 34,
                                      child: Row(
                                        children: <Widget>[
                                          _buildCompactPlayerIconButton(
                                            key: const Key('play-pause-button'),
                                            // 左下角播放按钮函数向原生播放器发送播放或暂停命令。
                                            onPressed: _togglePlayback,
                                            icon: _playing
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            tooltip: _playing ? '暂停' : '播放',
                                          ),
                                          const SizedBox(width: 2),
                                          Text(
                                            _formatProgress(),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                            ),
                                          ),
                                          const Spacer(),
                                          _buildPartSelectorControl(),
                                          SizedBox(
                                            height: 34,
                                            child: PopupMenuButton<int>(
                                              key: const Key('quality-menu'),
                                              initialValue: _currentQuality,
                                              tooltip: '清晰度',
                                              padding: EdgeInsets.zero,
                                              // 清晰度菜单选择函数保留进度后重新请求播放源。
                                              onSelected: (int quality) =>
                                                  unawaited(
                                                _changeQuality(quality),
                                              ),
                                              // 清晰度菜单构建函数使用原生接口实际返回的档位。
                                              itemBuilder:
                                                  (BuildContext context) {
                                                return _availableQualities
                                                    .map(
                                                      (PlaybackQuality
                                                              quality) =>
                                                          PopupMenuItem<int>(
                                                        key: Key(
                                                          'quality-${quality.id}',
                                                        ),
                                                        value: quality.id,
                                                        child:
                                                            Text(quality.label),
                                                      ),
                                                    )
                                                    .toList(growable: false);
                                              },
                                              child: _buildControlMenuLabel(
                                                _currentQualityLabel(),
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            height: 34,
                                            child: PopupMenuButton<double>(
                                              key: const Key('speed-menu'),
                                              initialValue: _playbackSpeed,
                                              tooltip: '播放倍速',
                                              padding: EdgeInsets.zero,
                                              // 倍速菜单选择函数把用户选择交给原生播放器。
                                              onSelected: (double speed) =>
                                                  unawaited(
                                                _changePlaybackSpeed(speed),
                                              ),
                                              // 倍速菜单构建函数生成固定且容易理解的五档速度。
                                              itemBuilder:
                                                  (BuildContext context) {
                                                return _playbackSpeeds
                                                    .map(
                                                      (double speed) =>
                                                          PopupMenuItem<double>(
                                                        key:
                                                            Key('speed-$speed'),
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
                                          ),
                                          _buildCompactPlayerIconButton(
                                            // 全屏按钮函数切换横屏沉浸状态。
                                            onPressed: () => unawaited(
                                              _toggleFullscreen(),
                                            ),
                                            icon: _fullscreen
                                                ? Icons.fullscreen_exit_rounded
                                                : Icons.fullscreen_rounded,
                                            tooltip:
                                                _fullscreen ? '退出全屏' : '进入全屏',
                                          ),
                                        ],
                                      ),
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
                  if (_partSelectorExpanded && _fullscreen)
                    Positioned(
                      key: const Key('fullscreen-part-selector'),
                      top: 0,
                      right: 0,
                      bottom: 0,
                      width: constraints.maxWidth * 0.56,
                      child: Material(
                        elevation: 16,
                        color: Theme.of(context).colorScheme.surface,
                        child: _buildExpandedPartSelector(),
                      ),
                    ),
                  if (_fullscreen &&
                      !_notesOpen &&
                      !_partSelectorExpanded &&
                      _showControls &&
                      !inPictureInPicture)
                    _buildFullscreenVideoNoteButton(),
                  if (_fullscreen && _notesOverlayMounted)
                    _buildFullscreenVideoNotesPanel(constraints.maxWidth),
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
    final Widget pageBody;
    if (fullscreenLayout) {
      pageBody = SizedBox.expand(child: player);
    } else if (_notesOpen) {
      pageBody = Column(
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            height: playerHeight,
            child: player,
          ),
          Expanded(child: _buildPortraitVideoNotesPanel()),
        ],
      );
    } else if (_partSelectorExpanded) {
      pageBody = Column(
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            height: playerHeight,
            child: player,
          ),
          Expanded(child: _buildExpandedPartSelector()),
        ],
      );
    } else {
      pageBody = _buildCollapsingPlayerBody(
        player: player,
        playerHeight: playerHeight,
      );
    }
    final Scaffold pageScaffold = Scaffold(
      backgroundColor: fullscreenLayout ? Colors.black : null,
      body: SafeArea(
        top: !fullscreenLayout,
        left: !fullscreenLayout,
        right: !fullscreenLayout,
        bottom: false,
        child: pageBody,
      ),
    );
    return PopScope(
      canPop: !_notesOpen && !_fullscreen && _collectionVideoBackStack.isEmpty,
      // 系统返回函数保证先退出全屏或返回上一支合集视频，再离开页面。
      onPopInvoked: _handlePopInvoked,
      child: pageScaffold,
    );
  }
}

/// 让播放器随详情页滚动连续改变高度，收起后不保留占位空间。
/// 展示完整合集，并在本机完成搜索、排序和当前视频定位。
class _CollectionPickerSheet extends StatefulWidget {
  /// 创建合集选择器；观看记录仅用于封面标记，不会改变合集数据。
  const _CollectionPickerSheet({
    required this.collection,
    required this.currentBvid,
    required this.watchHistoryByBvid,
  });

  final VideoCollection collection;
  final String currentBvid;
  final Map<String, WatchHistoryEntry> watchHistoryByBvid;

  /// 创建保存搜索文字、排序选项和滚动位置的面板状态。
  @override
  State<_CollectionPickerSheet> createState() => _CollectionPickerSheetState();
}

/// 管理合集展开面板的过滤、排序和当前位置滚动。
class _CollectionPickerSheetState extends State<_CollectionPickerSheet> {
  static const double _entryExtent = 76;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  _CollectionEntryOrder _order = _CollectionEntryOrder.original;
  String _keyword = '';

  /// 面板出现后自动滚到当前播放视频，避免长合集总是从第一条开始。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _locateCurrent(animated: false);
    });
  }

  /// 释放搜索输入框和列表滚动控制器，避免关闭面板后继续占用资源。
  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 根据关键词筛选标题或 BV 号，再复制排序，绝不修改原始合集列表。
  List<VideoCollectionEntry> _visibleEntries() {
    final String normalizedKeyword = _keyword.trim().toLowerCase();
    final List<VideoCollectionEntry> entries =
        widget.collection.entries.where((VideoCollectionEntry entry) {
      if (normalizedKeyword.isEmpty) {
        return true;
      }
      return entry.title.toLowerCase().contains(normalizedKeyword) ||
          entry.bvid.toLowerCase().contains(normalizedKeyword);
    }).toList(growable: true);
    switch (_order) {
      case _CollectionEntryOrder.original:
        break;
      case _CollectionEntryOrder.newest:
        entries.sort(_compareNewest);
        break;
      case _CollectionEntryOrder.oldest:
        entries.sort(_compareOldest);
        break;
      case _CollectionEntryOrder.mostPlayed:
        entries.sort(
          (VideoCollectionEntry left, VideoCollectionEntry right) =>
              right.stats.viewCount.compareTo(left.stats.viewCount),
        );
        break;
    }
    return entries;
  }

  /// 按发布时间从新到旧比较；缺少日期的条目放到列表末尾。
  int _compareNewest(
    VideoCollectionEntry left,
    VideoCollectionEntry right,
  ) {
    if (left.publishedAt == null && right.publishedAt == null) {
      return 0;
    }
    if (left.publishedAt == null) {
      return 1;
    }
    if (right.publishedAt == null) {
      return -1;
    }
    return right.publishedAt!.compareTo(left.publishedAt!);
  }

  /// 按发布时间从旧到新比较；缺少日期的条目仍放到列表末尾。
  int _compareOldest(
    VideoCollectionEntry left,
    VideoCollectionEntry right,
  ) {
    if (left.publishedAt == null && right.publishedAt == null) {
      return 0;
    }
    if (left.publishedAt == null) {
      return 1;
    }
    if (right.publishedAt == null) {
      return -1;
    }
    return left.publishedAt!.compareTo(right.publishedAt!);
  }

  /// 更新搜索关键词并立即刷新结果，不发送网络请求。
  void _updateKeyword(String value) {
    setState(() => _keyword = value);
  }

  /// 清空搜索条件，并让当前视频重新出现在可见结果中。
  void _clearSearch() {
    _searchController.clear();
    setState(() => _keyword = '');
  }

  /// 切换本地排序方式，并保持搜索结果继续可用。
  void _changeOrder(_CollectionEntryOrder order) {
    setState(() => _order = order);
  }

  /// 清除可能挡住当前项的搜索词，再滚动到当前播放视频。
  void _locateCurrent({bool animated = true}) {
    if (_keyword.isNotEmpty) {
      _clearSearch();
    }
    final List<VideoCollectionEntry> entries = _visibleEntries();
    final int index = entries.indexWhere(
      (VideoCollectionEntry entry) => entry.bvid == widget.currentBvid,
    );
    if (index < 0) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final ScrollPosition position = _scrollController.position;
      final double target =
          (index * _entryExtent).clamp(0, position.maxScrollExtent).toDouble();
      if (animated) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  /// 返回排序菜单中对初学者友好的中文名称。
  String _orderLabel(_CollectionEntryOrder order) {
    switch (order) {
      case _CollectionEntryOrder.original:
        return '合集顺序';
      case _CollectionEntryOrder.newest:
        return '最新发布';
      case _CollectionEntryOrder.oldest:
        return '最早发布';
      case _CollectionEntryOrder.mostPlayed:
        return '最多播放';
    }
  }

  /// 将公开视频统计压缩为万或亿，避免副标题被数字挤满。
  String _formatCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      return '${(value / 10000).toStringAsFixed(1)}万';
    }
    return value.toString();
  }

  /// 将封面时长格式化成分秒或时分秒。
  String _formatDuration(Duration duration) {
    final int seconds = duration.inSeconds.clamp(0, 1 << 31).toInt();
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  /// 创建固定比例封面，加载失败时显示视频占位图标而不撑坏列表。
  Widget _buildThumbnail(VideoCollectionEntry entry, bool current) {
    final WatchHistoryEntry? history = widget.watchHistoryByBvid[entry.bvid];
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: <Widget>[
          if (entry.thumbnailUrl.isEmpty)
            const SizedBox(
              width: 96,
              height: 54,
              child: ColoredBox(
                color: Colors.black26,
                child: Icon(Icons.video_library_outlined),
              ),
            )
          else
            CachedNetworkImage(
              imageUrl: entry.thumbnailUrl,
              width: 96,
              height: 54,
              fit: BoxFit.cover,
              errorWidget: (BuildContext context, String url, Object error) =>
                  const SizedBox(
                width: 96,
                height: 54,
                child: ColoredBox(
                  color: Colors.black26,
                  child: Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
          if (history != null && !current)
            Positioned(
              left: 3,
              top: 3,
              child: WatchHistoryBadge(
                entry: history,
                showPosition: false,
              ),
            ),
          Positioned(
            right: 3,
            bottom: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(
                  _formatDuration(entry.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 创建单条合集视频，点击后把选择结果交回播放器页面。
  Widget _buildEntry(VideoCollectionEntry entry) {
    final bool current = entry.bvid == widget.currentBvid;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: current
            ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.45)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          key: Key('collection-sheet-${entry.bvid}'),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: _buildThumbnail(entry, current),
          title: Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            current ? '正在播放' : '${_formatCount(entry.stats.viewCount)}播放',
            maxLines: 1,
          ),
          trailing: Icon(
            current ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
          ),
          // 条目点击函数关闭合集面板，并把所选视频返回给播放器切换。
          onTap: current ? null : () => Navigator.of(context).pop(entry),
        ),
      ),
    );
  }

  /// 创建带标题、搜索框、排序按钮、定位按钮和惰性长列表的合集面板。
  @override
  Widget build(BuildContext context) {
    final List<VideoCollectionEntry> entries = _visibleEntries();
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.84,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '合集 · ${widget.collection.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text('${entries.length}/${widget.collection.entries.length}'),
                  IconButton(
                    key: const Key('collection-locate-current'),
                    tooltip: '定位到正在播放',
                    // 定位按钮函数会清空搜索，并滚动到当前播放视频。
                    onPressed: _locateCurrent,
                    icon: const Icon(Icons.my_location_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('collection-search-field'),
                      controller: _searchController,
                      onChanged: _updateKeyword,
                      decoration: InputDecoration(
                        hintText: '搜索标题或 BV 号',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _keyword.isEmpty
                            ? null
                            : IconButton(
                                // 清空按钮函数恢复完整合集结果。
                                onPressed: _clearSearch,
                                icon: const Icon(Icons.close_rounded),
                              ),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<_CollectionEntryOrder>(
                    key: const Key('collection-sort-button'),
                    tooltip: '排序',
                    initialValue: _order,
                    // 排序选择函数只重新排列当前面板，不修改合集本身。
                    onSelected: _changeOrder,
                    itemBuilder: (BuildContext context) =>
                        _CollectionEntryOrder.values
                            .map(
                              (_CollectionEntryOrder order) =>
                                  PopupMenuItem<_CollectionEntryOrder>(
                                value: order,
                                child: Text(_orderLabel(order)),
                              ),
                            )
                            .toList(growable: false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(Icons.sort_rounded),
                          const SizedBox(width: 5),
                          Text(_orderLabel(_order)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('没有找到匹配的视频'))
                    : Scrollbar(
                        controller: _scrollController,
                        child: ListView.builder(
                          key: const Key('collection-sheet-list'),
                          controller: _scrollController,
                          itemExtent: _entryExtent,
                          itemCount: entries.length,
                          // 长列表构建函数只创建屏幕附近的条目，781 条也能继续滑动。
                          itemBuilder: (BuildContext context, int index) =>
                              _buildEntry(entries[index]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollapsingPlayerHeaderDelegate extends SliverPersistentHeaderDelegate {
  /// 创建最大高度固定、最小高度为零的播放器折叠头。
  const _CollapsingPlayerHeaderDelegate({
    required this.maximumHeight,
    required this.child,
  });

  final double maximumHeight;
  final Widget child;

  /// 返回完全收起后的高度，使详情内容能够占满整个屏幕。
  @override
  double get minExtent => 0;

  /// 返回播放器初始展开高度，由真实视频比例和屏幕尺寸共同决定。
  @override
  double get maxExtent => maximumHeight;

  /// 按当前 Sliver 高度裁切并重排播放器，形成连续收起效果。
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ClipRect(child: SizedBox.expand(child: child));
  }

  /// 仅在播放器高度或实例变化时重新创建折叠布局。
  @override
  bool shouldRebuild(covariant _CollapsingPlayerHeaderDelegate oldDelegate) {
    return maximumHeight != oldDelegate.maximumHeight ||
        child != oldDelegate.child;
  }
}

/// 在视频简介区紧凑显示一个图标和一段公开元数据。
class _DetailMeta extends StatelessWidget {
  /// 创建不可点击的只读详情元数据。
  const _DetailMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  /// 创建水平排列的图标与文字。
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 16),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
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

/// 保存一条已经完成车道规划的弹幕，绘制阶段不再重复测量文字或争抢车道。
class _DanmakuLayoutItem {
  /// 创建包含原始弹幕、物理车道和已测量文字宽度的渲染项。
  const _DanmakuLayoutItem({
    required this.entry,
    required this.lane,
    required this.textWidth,
  });

  final DanmakuEntry entry;
  final int lane;
  final double textWidth;
}

/// 缓存当前弹幕片段在指定画布尺寸下的车道规划，减少逐帧布局运算。
class _DanmakuLanePlanner {
  List<DanmakuEntry>? _cachedEntries;
  Size? _cachedSize;
  DanmakuPreferences? _cachedPreferences;
  List<_DanmakuLayoutItem> _cachedItems = const <_DanmakuLayoutItem>[];

  /// 清除旧分P或旧尺寸的规划结果，确保新视频不会复用错误车道。
  void clear() {
    _cachedEntries = null;
    _cachedSize = null;
    _cachedPreferences = null;
    _cachedItems = const <_DanmakuLayoutItem>[];
  }

  /// 按时间顺序为弹幕寻找空闲车道；没有空闲车道时丢弃该条，避免文字叠成一团。
  List<_DanmakuLayoutItem> plan(
    List<DanmakuEntry> entries,
    Size size,
    DanmakuPreferences preferences,
  ) {
    if (identical(_cachedEntries, entries) &&
        _cachedSize == size &&
        identical(_cachedPreferences, preferences)) {
      return _cachedItems;
    }
    final double laneHeight = preferences.fontSize + 9;
    final int laneCount = (size.height / laneHeight)
        .floor()
        .clamp(1, preferences.laneCount)
        .toInt();
    final List<int> scrollingLaneFreeAt = List<int>.filled(laneCount, 0);
    final List<int> topFixedLaneFreeAt = List<int>.filled(laneCount, 0);
    final List<int> bottomFixedLaneFreeAt = List<int>.filled(laneCount, 0);
    final List<DanmakuEntry> ordered = List<DanmakuEntry>.from(entries)
      ..sort(
        (DanmakuEntry left, DanmakuEntry right) =>
            left.position.compareTo(right.position),
      );
    final List<_DanmakuLayoutItem> items = <_DanmakuLayoutItem>[];
    for (final DanmakuEntry entry in ordered) {
      final double textWidth = _measureTextWidth(
        entry.content,
        size.width,
        preferences,
      );
      final int startedAt = entry.position.inMilliseconds;
      final int lane;
      if (entry.mode == 5) {
        lane = _findFixedLane(
          laneFreeAt: topFixedLaneFreeAt,
          startedAt: startedAt,
          fromBottom: false,
        );
      } else if (entry.mode == 4) {
        lane = _findFixedLane(
          laneFreeAt: bottomFixedLaneFreeAt,
          startedAt: startedAt,
          fromBottom: true,
        );
      } else {
        final int preferredLane =
            (startedAt ~/ 100 + entry.content.hashCode).abs() % laneCount;
        lane = _findScrollingLane(
          laneFreeAt: scrollingLaneFreeAt,
          startedAt: startedAt,
          preferredLane: preferredLane,
        );
      }
      if (lane < 0) {
        continue;
      }
      if (entry.mode == 4 || entry.mode == 5) {
        final List<int> fixedLanes =
            entry.mode == 4 ? bottomFixedLaneFreeAt : topFixedLaneFreeAt;
        fixedLanes[lane] = startedAt + 4000;
      } else {
        final int minimumGapMilliseconds = ((textWidth + 28) /
                (size.width + textWidth) *
                (preferences.scrollDurationSeconds * 1000))
            .ceil();
        scrollingLaneFreeAt[lane] = startedAt + minimumGapMilliseconds;
      }
      items.add(
        _DanmakuLayoutItem(
          entry: entry,
          lane: lane,
          textWidth: textWidth,
        ),
      );
    }
    _cachedEntries = entries;
    _cachedSize = size;
    _cachedPreferences = preferences;
    _cachedItems = List<_DanmakuLayoutItem>.unmodifiable(items);
    return _cachedItems;
  }

  /// 测量单行弹幕的真实宽度并限制极端长文本，保证移动速度与碰撞判断一致。
  double _measureTextWidth(
    String text,
    double canvasWidth,
    DanmakuPreferences preferences,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: _DanmakuPainter.textStyleFor(preferences),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: canvasWidth * 0.92);
    return painter.width;
  }

  /// 从期望车道开始循环寻找尾部已经离开起点的滚动弹幕车道。
  int _findScrollingLane({
    required List<int> laneFreeAt,
    required int startedAt,
    required int preferredLane,
  }) {
    for (int offset = 0; offset < laneFreeAt.length; offset += 1) {
      final int lane = (preferredLane + offset) % laneFreeAt.length;
      if (laneFreeAt[lane] <= startedAt) {
        return lane;
      }
    }
    return -1;
  }

  /// 从顶部或底部寻找空闲固定弹幕车道，四秒内被占用的车道不会重复使用。
  int _findFixedLane({
    required List<int> laneFreeAt,
    required int startedAt,
    required bool fromBottom,
  }) {
    for (int offset = 0; offset < laneFreeAt.length; offset += 1) {
      final int lane = fromBottom ? laneFreeAt.length - 1 - offset : offset;
      if (laneFreeAt[lane] <= startedAt) {
        return lane;
      }
    }
    return -1;
  }
}

/// 在整个播放器画面上平滑绘制真实弹幕，不受上下控制栏的布局内边距影响。
class _DanmakuPainter extends CustomPainter {
  static const Duration _fixedDisplayDuration = Duration(seconds: 4);
  static const int _maximumVisibleEntries = 48;

  /// 按配置生成绘制样式；字号单位为 Flutter 逻辑像素，透明度限制在 20% 至 100%。
  static TextStyle textStyleFor(DanmakuPreferences preferences) => TextStyle(
        color: Colors.white.withOpacity(preferences.opacity),
        fontSize: preferences.fontSize,
        fontWeight: FontWeight.w600,
        shadows: const <Shadow>[
          Shadow(color: Colors.black, blurRadius: 2),
        ],
      );

  /// 创建使用逐帧控制器重绘的弹幕画笔，原生播放器状态只负责校准时间锚点。
  _DanmakuPainter({
    required this.entries,
    required this.positionAnchor,
    required this.playbackSpeed,
    required this.frameController,
    required this.lanePlanner,
    required this.preferences,
  }) : super(repaint: frameController);

  final List<DanmakuEntry> entries;
  final Duration positionAnchor;
  final double playbackSpeed;
  final AnimationController frameController;
  final _DanmakuLanePlanner lanePlanner;
  final DanmakuPreferences preferences;

  /// 将帧间真实时间乘当前倍速后加到播放器锚点，使弹幕与倍速播放保持同一时间轴。
  Duration _currentPosition() {
    final int realElapsedMicroseconds =
        (frameController.value * frameController.duration!.inMicroseconds)
            .round();
    return DanmakuTimeline.advance(
      positionAnchor: positionAnchor,
      realElapsed: Duration(microseconds: realElapsedMicroseconds),
      playbackSpeed: playbackSpeed,
    );
  }

  /// 绘制当前可见弹幕；车道无空间的高密度条目已经在规划阶段被安全丢弃。
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || entries.isEmpty) {
      return;
    }
    final Duration position = _currentPosition();
    final List<_DanmakuLayoutItem> items =
        lanePlanner.plan(entries, size, preferences);
    final int firstCandidate = _firstCandidateIndex(
      items,
      position - const Duration(seconds: 14),
    );
    int paintedEntries = 0;
    for (int index = firstCandidate; index < items.length; index += 1) {
      final _DanmakuLayoutItem item = items[index];
      if (item.entry.position > position ||
          paintedEntries >= _maximumVisibleEntries) {
        break;
      }
      final Duration elapsed = position - item.entry.position;
      final double x = _horizontalOffsetForItem(item, elapsed, size.width);
      if (x > size.width || x + item.textWidth < 0) {
        continue;
      }
      if ((item.entry.mode == 4 || item.entry.mode == 5) &&
          elapsed > _fixedDisplayDuration) {
        continue;
      }
      final TextPainter textPainter = TextPainter(
        text: TextSpan(
          text: item.entry.content,
          style: textStyleFor(preferences).copyWith(
              color:
                  _colorForEntry(item.entry).withOpacity(preferences.opacity)),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: size.width * 0.92);
      final double maximumTop = (size.height - textPainter.height)
          .clamp(0, double.infinity)
          .toDouble();
      final double y = (item.lane * (preferences.fontSize + 9))
          .clamp(0, maximumTop)
          .toDouble();
      textPainter.paint(canvas, Offset(x, y));
      paintedEntries += 1;
    }
  }

  /// 使用二分查找跳过远早于当前时间的条目，降低长弹幕片段的逐帧遍历开销。
  int _firstCandidateIndex(
    List<_DanmakuLayoutItem> items,
    Duration threshold,
  ) {
    int lower = 0;
    int upper = items.length;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      if (items[middle].entry.position < threshold) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    return lower;
  }

  /// 按固定视频时长让弹幕完整穿过整个画布，横屏再宽也不会只挤在左半边。
  double _horizontalOffsetForItem(
    _DanmakuLayoutItem item,
    Duration elapsed,
    double canvasWidth,
  ) {
    if (item.entry.mode == 4 || item.entry.mode == 5) {
      return (canvasWidth - item.textWidth) / 2;
    }
    return DanmakuTimeline.horizontalOffset(
      elapsed: elapsed,
      canvasWidth: canvasWidth,
      textWidth: item.textWidth,
      reverse: item.entry.mode == 6,
      travelDuration: Duration(
          milliseconds: (preferences.scrollDurationSeconds * 1000).round()),
    );
  }

  /// 把 B 站返回的 RGB 整数颜色转换为带不透明 Alpha 的 Flutter 颜色。
  Color _colorForEntry(DanmakuEntry entry) {
    return Color(0xFF000000 | (entry.color & 0xFFFFFF));
  }

  /// 当片段列表或原生时间锚点改变时重绘；连续移动由动画控制器直接驱动。
  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return oldDelegate.positionAnchor != positionAnchor ||
        oldDelegate.playbackSpeed != playbackSpeed ||
        !identical(oldDelegate.preferences, preferences) ||
        !identical(oldDelegate.entries, entries) ||
        oldDelegate.lanePlanner != lanePlanner;
  }
}
