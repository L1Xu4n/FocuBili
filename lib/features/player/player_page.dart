import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../core/layout/adaptive_layout.dart';
import '../../core/layout/device_orientation_policy.dart';
import '../../features/common/watch_history_badge.dart';
import '../../features/focus/focus_timer_controller.dart';
import '../../features/focus/focus_timer_scope.dart';
import '../../features/focus/focus_interruption_dialog.dart';
import '../../features/focus/player_focus_sheet.dart';
import '../../features/focus/player_focus_onboarding.dart';
import '../../features/notes/video_note_composer.dart';
import '../../features/profile/user_profile_page.dart';
import '../../models/video_note.dart';
import '../../models/video_preview.dart';
import '../../models/player_enhancement.dart';
import '../../models/video_shot_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../models/learning_list_entry.dart';
import '../../services/device_status_service.dart';
import '../../services/external_link_service.dart';
import '../../services/native_playback_service.dart';
import '../../services/player_overlay_service.dart';
import '../../services/problem_diagnostics_service.dart';
import '../../services/bilibili_public_content_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/watch_history_service.dart';
import '../../services/learning_list_service.dart';
import '../../services/video_shot_service.dart';
import '../../services/video_note_service.dart';
import '../../models/player_overlay_data.dart';
import '../../models/danmaku_preferences.dart';
import '../../models/danmaku_launch_scheduler.dart';
import '../../models/danmaku_presentation_window.dart';
import '../../models/danmaku_timeline_index.dart';
import '../../models/focus_session.dart';
import '../../models/playback_preferences.dart';
import '../../services/danmaku_preferences_service.dart';
import '../../services/playback_preferences_service.dart';
import '../../services/bilibili_player_enhancement_service.dart';
import 'enhancements/interactive_video_overlay.dart';
import 'enhancements/playback_completion_overlay.dart';
import 'enhancements/player_enhancement_controller.dart';
import 'enhancements/video_chapter_widgets.dart';
import 'widgets/player_control_widgets.dart';

part 'player_collection_sheet.dart';
part 'player_layout_widgets.dart';
part 'player_danmaku_rendering.dart';

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

/// 标识播放器首次跳转来自笔记还是专注记录，以显示准确提示文案。
enum PlayerInitialPositionSource { note, focus, learning, externalLink }

/// 标识播放页希望 Android 系统栏采用的三种可见状态。
enum _PlayerSystemUiLayout { standard, landscapePlayer, fullscreen }

/// 新架构的原生播放器页面，提供简洁的 App 风格控制层。
class PlayerPage extends StatefulWidget {
  /// 创建播放器页面，并允许测试替换原生播放和本地观看记录服务。
  const PlayerPage({
    super.key,
    required this.video,
    this.playbackService,
    this.watchHistoryService,
    this.learningListService,
    this.deviceStatusService,
    this.playerOverlayService,
    this.bilibiliService,
    this.publicContentService,
    this.videoShotService,
    this.videoNoteService,
    this.danmakuPreferencesService,
    this.playbackPreferencesService,
    this.playerEnhancementService,
    this.focusTimerController,
    this.externalLinkLauncher,
    this.initialPartCid,
    this.initialPosition,
    this.initialPositionSource = PlayerInitialPositionSource.note,
  });

  final VideoPreview video;
  final PlaybackService? playbackService;
  final WatchHistoryService? watchHistoryService;
  final LearningListService? learningListService;
  final DeviceStatusService? deviceStatusService;
  final PlayerOverlayService? playerOverlayService;
  final BilibiliService? bilibiliService;
  final BilibiliPublicContentService? publicContentService;
  final VideoShotService? videoShotService;
  final VideoNoteService? videoNoteService;
  final DanmakuPreferencesService? danmakuPreferencesService;
  final PlaybackPreferencesService? playbackPreferencesService;
  final BilibiliPlayerEnhancementService? playerEnhancementService;
  final FocusTimerController? focusTimerController;
  final ExternalLinkLauncher? externalLinkLauncher;
  final int? initialPartCid;
  final Duration? initialPosition;
  final PlayerInitialPositionSource initialPositionSource;

  /// 创建播放器状态，保存播放、进度、控制层和全屏状态。
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 管理原生视频纹理、播放状态、手势、控制层和系统全屏状态。
class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const Duration _controlsAutoHideDelay = Duration(seconds: 5);
  static const Duration _transientHintDuration = Duration(seconds: 3);
  static const Duration _resumeNoticeDuration = _transientHintDuration;
  static const Duration _notesPanelAnimationDuration = Duration(
    milliseconds: 280,
  );
  static const Duration _noteAutoSaveDelay = Duration(milliseconds: 800);
  static const AnimationStyle _playerPopupMenuAnimationStyle = AnimationStyle(
    duration: Duration(milliseconds: 100),
    reverseDuration: Duration(milliseconds: 80),
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  static const Duration _watchHistoryProgressSaveInterval = Duration(
    seconds: 15,
  );
  static const double _fullscreenBottomGestureExclusionHeight = 72;
  static const double _fullscreenTopGestureExclusionHeight = 56;
  static const double _fullscreenHorizontalGestureSideExclusionWidth = 48;
  static const double _horizontalSeekTravelWidthRatio = 0.75;
  static const double _minimumHorizontalSeekRangeSeconds = 120;
  static const double _maximumHorizontalSeekRangeSeconds = 600;
  static const String _subtitleOffValue = '__focubili_subtitle_off__';
  static const Duration _danmakuNextSegmentPreloadThreshold = Duration(
    seconds: 30,
  );
  static const int _maximumCachedDanmakuSegments = 3;
  static const int _maximumDanmakuSegmentRetries = 3;
  static const double _expandedPartItemHeight = 76;
  static const List<double> _playbackSpeeds = <double>[
    0.75,
    1,
    1.25,
    1.5,
    2,
    3,
  ];

  late final PlaybackService _playbackService;
  late final WatchHistoryService _watchHistoryService;
  late final LearningListService _learningListService;
  late final DeviceStatusService _deviceStatusService;
  late final PlayerOverlayService _playerOverlayService;
  late final BilibiliService _bilibiliService;
  late final BilibiliPublicContentService _publicContentService;
  late final VideoShotService _videoShotService;
  late final VideoNoteService _videoNoteService;
  late final ProblemDiagnosticsService _problemDiagnosticsService;
  late VideoPreview _activeVideo;
  late VideoPart _currentPart;
  final List<VideoPreview> _collectionVideoBackStack = <VideoPreview>[];
  final ScrollController _partScrollController = ScrollController();
  final ScrollController _collectionPreviewScrollController =
      ScrollController();
  final TextEditingController _noteTitleController = TextEditingController();
  final TextEditingController _noteBodyController = TextEditingController();
  final Map<String, TapGestureRecognizer> _descriptionMentionRecognizers =
      <String, TapGestureRecognizer>{};
  final Map<String, TapGestureRecognizer> _descriptionLinkRecognizers =
      <String, TapGestureRecognizer>{};
  StreamSubscription<PlaybackSnapshot>? _playbackSubscription;
  PlaybackSnapshot _playbackSnapshot = const PlaybackSnapshot();
  int? _textureId;
  bool _fullscreen = false;
  bool _controlsLocked = false;
  bool _fullscreenEnteredByOrientation = false;
  bool _suppressAutoFullscreenUntilPortrait = false;
  bool _restoreOrientationChoicesOnPortrait = false;
  bool _orientationSyncScheduled = false;
  bool _showControls = true;
  bool _isDraggingProgress = false;
  double _progress = 0;
  Offset? _lastDoubleTapPosition;
  String? _seekFeedback;
  String? _resumeNotice;
  Timer? _controlsTimer;
  Timer? _interactivePromptTimer;
  Timer? _seekFeedbackTimer;
  Timer? _focusSeekTransitionTimer;
  Timer? _resumeNoticeTimer;
  Timer? _playerNoticeTimer;
  Timer? _playerStatusTimer;
  Timer? _notesPanelAnimationTimer;
  Timer? _noteAutoSaveTimer;
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
  bool _temporarySpeedActive = false;
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
  LearningListEntry? _learningListEntry;
  bool _learningListLoading = false;
  String? _addingLearningBvid;
  int? _recordedLearningListPartCid;
  Duration _lastLearningListSavedPosition = Duration.zero;
  bool _learningProgressSaveInFlight = false;
  bool _completionPromptVisible = false;
  bool _completionLearningFinished = false;
  bool _interactivePromptVisible = false;
  bool _interactiveChoiceOpening = false;
  DateTime _playerClock = DateTime.now();
  int? _batteryPercent;
  DeviceNetworkType _networkType = DeviceNetworkType.other;
  bool _playerStatusSyncScheduled = false;
  bool _pendingPlayerStatusVisible = false;
  int _preferredOpeningQuality = PreferredPlaybackQuality.p720.id;
  bool _defaultQualityPending = true;
  SubtitleTrackLoadResult? _subtitleTrackResult;
  SubtitleTrack? _selectedSubtitleTrack;
  List<SubtitleCue> _subtitleCues = const <SubtitleCue>[];
  bool _subtitleTracksLoading = false;
  bool _subtitleCuesLoading = false;
  int _subtitleRequestToken = 0;
  final Map<int, List<DanmakuEntry>> _rawDanmakuSegments =
      <int, List<DanmakuEntry>>{};
  final Map<int, List<DanmakuEntry>> _danmakuSegments =
      <int, List<DanmakuEntry>>{};
  final Set<int> _loadingDanmakuSegments = <int>{};
  final Map<int, int> _danmakuSegmentFailureCounts = <int, int>{};
  final Map<int, DateTime> _danmakuSegmentRetryAfter = <int, DateTime>{};
  int _danmakuRequestToken = 0;
  late final AnimationController _danmakuFrameController;
  final _DanmakuLanePlanner _danmakuLanePlanner = _DanmakuLanePlanner();
  final DanmakuPresentationWindow _danmakuPresentationWindow =
      DanmakuPresentationWindow();
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
  int _noteDraftRevision = 0;
  Duration? _pendingInitialPosition;
  Map<String, WatchHistoryEntry> _watchHistoryByBvid =
      const <String, WatchHistoryEntry>{};
  String? _locatedCollectionPreviewBvid;
  late final DanmakuPreferencesService _danmakuPreferencesService;
  late final PlaybackPreferencesService _playbackPreferencesService;
  late final PlayerEnhancementController _playerEnhancementController;
  PlaybackPreferences _playbackPreferences = const PlaybackPreferences();
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
  bool _systemUiSyncScheduled = false;
  _PlayerSystemUiLayout? _pendingSystemUiLayout;
  _PlayerSystemUiLayout? _appliedSystemUiLayout;

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
    WidgetsBinding.instance.addObserver(this);
    _danmakuFrameController = AnimationController(
      vsync: this,
      duration: const Duration(hours: 1),
    );
    _activeVideo = widget.video;
    _currentPart = _activeVideo.initialPart;
    _notePartCid = _currentPart.cid;
    _playbackService = widget.playbackService ?? NativePlaybackService();
    _watchHistoryService = widget.watchHistoryService ?? WatchHistoryService();
    _learningListService = widget.learningListService ?? LearningListService();
    _deviceStatusService =
        widget.deviceStatusService ?? const NativeDeviceStatusService();
    _playerOverlayService =
        widget.playerOverlayService ?? NativePlayerOverlayService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoShotService =
        widget.videoShotService ??
        (widget.playbackService == null
            ? BilibiliVideoShotService()
            : const EmptyVideoShotService());
    _videoNoteService = widget.videoNoteService ?? VideoNoteService();
    _problemDiagnosticsService = ProblemDiagnosticsService();
    _danmakuPreferencesService =
        widget.danmakuPreferencesService ?? DanmakuPreferencesService();
    _playbackPreferencesService =
        widget.playbackPreferencesService ?? const PlaybackPreferencesService();
    _playerEnhancementController = PlayerEnhancementController(
      service:
          widget.playerEnhancementService ??
          (widget.playbackService == null
              ? BilibiliPublicPlayerEnhancementService()
              : const EmptyPlayerEnhancementService()),
    )..addListener(_handlePlayerEnhancementChanged);
    _pendingInitialPosition = widget.initialPosition;
    _playbackSubscription = _playbackService.states.listen(
      _applyPlaybackSnapshot,
    );
    unawaited(_loadWatchHistoryBadges());
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_loadDanmakuPreferences());
    if (widget.playbackService == null) {
      unawaited(_allowPlayerOrientations());
    }
    unawaited(_initializeNativePlayback());
  }

  /// 响应独立增强控制器变化，刷新章节界面，并处理已完播或即将到结尾的互动选择。
  void _handlePlayerEnhancementChanged() {
    if (!mounted) {
      return;
    }
    final PlaybackSnapshot snapshot = _playbackSnapshot;
    setState(() {
      if (snapshot.phase == PlaybackPhase.ended &&
          !_interactiveChoiceOpening &&
          _playerEnhancementController.handlesPlaybackCompletion) {
        _interactivePromptVisible = true;
        _completionPromptVisible = false;
        _showControls = true;
      }
    });
    _scheduleInteractiveChoicePrompt(snapshot);
  }

  /// 根据真实总时长安排选项计时器，让结尾前的毫秒提前量不会被半秒状态刷新跳过。
  void _scheduleInteractiveChoicePrompt(PlaybackSnapshot snapshot) {
    _interactivePromptTimer?.cancel();
    _interactivePromptTimer = null;
    if (!mounted ||
        snapshot.phase != PlaybackPhase.ready ||
        !snapshot.isPlaying ||
        snapshot.isInPictureInPicture ||
        _interactivePromptVisible ||
        _interactiveChoiceOpening) {
      return;
    }
    final Duration? delay = _playerEnhancementController.interactiveChoiceDelay(
      position: snapshot.position,
      duration: snapshot.duration,
    );
    if (delay == null) {
      return;
    }
    if (delay <= Duration.zero) {
      unawaited(_presentInteractiveChoice(snapshot));
      return;
    }
    _interactivePromptTimer = Timer(delay, () {
      _interactivePromptTimer = null;
      unawaited(_presentInteractiveChoice(_playbackSnapshot));
    });
  }

  /// 显示已经到时的互动选项，并按接口要求暂停当前节点而不替用户选择分支。
  Future<void> _presentInteractiveChoice(PlaybackSnapshot snapshot) async {
    if (!mounted ||
        snapshot.phase != PlaybackPhase.ready ||
        !snapshot.isPlaying ||
        _interactivePromptVisible ||
        _interactiveChoiceOpening ||
        !_playerEnhancementController.canPresentInteractiveChoice) {
      return;
    }
    _interactivePromptTimer?.cancel();
    _interactivePromptTimer = null;
    _playerEnhancementController.markInteractiveChoicePresented();
    setState(() {
      _interactivePromptVisible = true;
      _completionPromptVisible = false;
      _showControls = true;
    });
    if (!_playerEnhancementController.interactiveNode!.pauseVideoForChoice ||
        !snapshot.isPlaying) {
      return;
    }
    try {
      await _playbackService.pause();
    } catch (_) {
      if (mounted) {
        _showPlayerNotice('已到达剧情选择点，请选择下一步。');
      }
    }
  }

  /// 请求当前 BV 与 CID 的章节及互动信息，旧请求由控制器令牌自动丢弃。
  Future<void> _loadPlayerEnhancements() {
    return _playerEnhancementController.load(
      bvid: _activeVideo.bvid,
      cid: _currentPart.cid,
    );
  }

  /// 绑定应用级专注控制器，使从首页或播放器发起的专注都能触发结束联动。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindFocusController(
      widget.focusTimerController ?? FocusTimerScope.maybeOf(context),
    );
    _scheduleOrientationSync();
  }

  /// 设备尺寸或旋转发生变化时，在下一帧根据横竖屏同步播放器全屏状态。
  @override
  void didChangeMetrics() {
    _scheduleOrientationSync();
  }

  /// 播放页存活期间让手机可旋转全屏，并让 Android 平板继续保持横屏工作台。
  Future<void> _allowPlayerOrientations() async {
    final List<FlutterView> views = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .toList();
    if (views.isEmpty) {
      return;
    }
    final List<DeviceOrientation> orientations =
        DeviceOrientationPolicy.playerOrientations(
          logicalSize: DeviceOrientationPolicy.logicalSizeForView(views.first),
          isAndroid: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
        );
    if (orientations.isNotEmpty) {
      await SystemChrome.setPreferredOrientations(orientations);
    }
  }

  /// 把多次系统尺寸变化合并到一帧处理，避免旋转动画中反复进出全屏。
  void _scheduleOrientationSync() {
    if (widget.playbackService != null || _orientationSyncScheduled) {
      return;
    }
    _orientationSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _orientationSyncScheduled = false;
      _syncFullscreenWithOrientation();
    });
  }

  /// 把构建期得到的横屏状态延后到帧末同步，避免在 build 中直接修改 Android 系统栏。
  void _schedulePlayerSystemUiSync({required bool landscapeLayout}) {
    if (widget.playbackService != null) {
      return;
    }
    _pendingSystemUiLayout = _fullscreen
        ? _PlayerSystemUiLayout.fullscreen
        : landscapeLayout
        ? _PlayerSystemUiLayout.landscapePlayer
        : _PlayerSystemUiLayout.standard;
    if (_systemUiSyncScheduled) {
      return;
    }
    _systemUiSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _systemUiSyncScheduled = false;
      final _PlayerSystemUiLayout? target = _pendingSystemUiLayout;
      if (target != null) {
        unawaited(_applyPlayerSystemUiLayout(target));
      }
    });
  }

  /// 应用播放页系统栏模式：横屏仅隐藏顶部状态栏，全屏同时隐藏顶部和底部系统栏。
  Future<void> _applyPlayerSystemUiLayout(_PlayerSystemUiLayout target) async {
    if (!mounted || _appliedSystemUiLayout == target) {
      return;
    }
    switch (target) {
      case _PlayerSystemUiLayout.standard:
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      case _PlayerSystemUiLayout.landscapePlayer:
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: const <SystemUiOverlay>[SystemUiOverlay.bottom],
        );
      case _PlayerSystemUiLayout.fullscreen:
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (mounted) {
      _appliedSystemUiLayout = target;
    }
  }

  /// 临时打开普通系统栏供 UP 主页使用，并让播放页返回后重新计算横屏系统栏状态。
  Future<void> _showStandardSystemUiForNestedRoute() async {
    if (widget.playbackService != null) {
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _appliedSystemUiLayout = null;
  }

  /// 横屏自动进入全屏、竖屏退出自动全屏；笔记打开时不自动改变布局。
  void _syncFullscreenWithOrientation() {
    if (!mounted) {
      return;
    }
    if (AdaptiveLayout.usesWorkspace(MediaQuery.sizeOf(context))) {
      _suppressAutoFullscreenUntilPortrait = false;
      _restoreOrientationChoicesOnPortrait = false;
      if (_fullscreen && _fullscreenEnteredByOrientation) {
        unawaited(
          _setFullscreen(
            false,
            updateOrientation: false,
            enteredByOrientation: true,
          ),
        );
      }
      return;
    }
    final Orientation orientation = MediaQuery.orientationOf(context);
    if (orientation == Orientation.portrait) {
      _suppressAutoFullscreenUntilPortrait = false;
      if (_restoreOrientationChoicesOnPortrait) {
        _restoreOrientationChoicesOnPortrait = false;
        unawaited(_allowPlayerOrientations());
      }
      if (_fullscreen && _fullscreenEnteredByOrientation) {
        unawaited(
          _setFullscreen(
            false,
            updateOrientation: false,
            enteredByOrientation: true,
          ),
        );
      }
      return;
    }
    if (!_fullscreen && !_notesOpen && !_suppressAutoFullscreenUntilPortrait) {
      unawaited(
        _setFullscreen(
          true,
          updateOrientation: false,
          enteredByOrientation: true,
        ),
      );
    }
  }

  /// 读取设备里保存的手势和默认清晰度；异常时返回当前安全默认配置。
  Future<PlaybackPreferences> _loadPlaybackPreferences() async {
    try {
      final PlaybackPreferences preferences = await _playbackPreferencesService
          .load();
      if (mounted) {
        setState(() => _playbackPreferences = preferences);
      }
      return preferences;
    } catch (_) {
      // 本地配置损坏不影响视频播放，默认配置已经是可用的安全回退。
      return _playbackPreferences;
    }
  }

  /// 读取当前网络类型；系统通道异常时按更保守的移动网络配置处理。
  Future<DeviceNetworkType> _loadNetworkTypeSafely() async {
    if (widget.playbackService != null && widget.deviceStatusService == null) {
      return DeviceNetworkType.other;
    }
    try {
      return await _deviceStatusService.loadNetworkType();
    } catch (_) {
      return DeviceNetworkType.other;
    }
  }

  /// 读取当前电量；替换了原生播放器却未提供设备服务时直接返回未知，避免调用不存在的平台通道。
  Future<int?> _loadBatteryPercentSafely() async {
    if (widget.playbackService != null && widget.deviceStatusService == null) {
      return null;
    }
    try {
      return await _deviceStatusService.loadBatteryPercent();
    } catch (_) {
      return null;
    }
  }

  /// 根据 Wi-Fi、有线或移动网络返回本次打开视频应请求的默认清晰度。
  int _preferredQualityForNetwork(
    PlaybackPreferences preferences,
    DeviceNetworkType networkType,
  ) {
    return switch (networkType) {
      DeviceNetworkType.wifi ||
      DeviceNetworkType.ethernet => preferences.wifiDefaultQuality.id,
      DeviceNetworkType.mobile ||
      DeviceNetworkType.offline ||
      DeviceNetworkType.other => preferences.mobileDefaultQuality.id,
    };
  }

  /// 测试或父组件更换注入控制器时，解绑旧实例并监听新实例。
  @override
  void didUpdateWidget(covariant PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusTimerController != widget.focusTimerController) {
      _bindFocusController(
        widget.focusTimerController ?? FocusTimerScope.maybeOf(context),
      );
    }
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
      final bool visualStateChanged =
          _observedFocusSessionId != active.id ||
          _observedFocusStatus != active.status;
      _observedFocusSessionId = active.id;
      _observedFocusStatus = active.status;
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

  /// 启动时恢复全局弹幕配置；旧用户或读取失败由服务返回默认值，页面仍可正常播放。
  Future<void> _loadDanmakuPreferences() async {
    final DanmakuPreferences preferences = await _danmakuPreferencesService
        .load();
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
    final List<WatchHistoryEntry> entries = await _watchHistoryService
        .loadHistory();
    if (!mounted) {
      return;
    }
    setState(() {
      _watchHistoryByBvid = <String, WatchHistoryEntry>{
        for (final WatchHistoryEntry entry in entries) entry.bvid: entry,
      };
    });
  }

  /// 读取当前视频分 P 是否已在学习清单中，避免同一视频的其他 P 覆盖当前任务状态。
  Future<void> _loadCurrentLearningListEntry() async {
    final String requestedBvid = _activeVideo.bvid;
    final int requestedPartCid = _currentPart.cid;
    if (mounted) {
      setState(() => _learningListLoading = true);
    }
    final List<LearningListEntry> entries = await _learningListService
        .loadEntries();
    if (!mounted ||
        _activeVideo.bvid != requestedBvid ||
        _currentPart.cid != requestedPartCid) {
      return;
    }
    final LearningListEntry? matched = _learningListService.findEntryForPart(
      entries,
      requestedBvid,
      requestedPartCid,
    );
    setState(() {
      _learningListEntry = matched;
      _learningListLoading = false;
      _recordedLearningListPartCid = matched?.partCid;
      _lastLearningListSavedPosition = matched?.position ?? Duration.zero;
    });
  }

  /// 将当前分 P 加入学习清单；播放器已就绪时优先保存真实进度。
  Future<void> _addCurrentVideoToLearningList() async {
    if (_addingLearningBvid != null) {
      return;
    }
    final VideoPreview video = _activeVideo;
    final VideoPart part = _currentPart;
    final String bvid = video.bvid;
    final bool hasLivePlayback = _playbackSnapshot.phase == PlaybackPhase.ready;
    setState(() => _addingLearningBvid = bvid);
    try {
      final List<LearningListEntry> entries = await _learningListService
          .addVideo(
            video,
            part: part,
            position: hasLivePlayback ? _playbackSnapshot.position : null,
            status: hasLivePlayback && _playing
                ? LearningListStatus.learning
                : null,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != part.cid) {
        return;
      }
      final LearningListEntry? entry = _entryForPart(entries, bvid, part.cid);
      setState(() {
        _learningListEntry = entry;
        _recordedLearningListPartCid = entry?.partCid;
        _lastLearningListSavedPosition = entry?.position ?? Duration.zero;
      });
      _showTransientSnackBar('已将 P${part.pageNumber} 加入学习清单');
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('加入学习清单失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 处理详情顶部学习清单按钮：未加入时加入，已加入时先询问是否取消。
  Future<void> _handleCurrentVideoLearningListTap() async {
    if (_learningListLoading || _addingLearningBvid != null) {
      return;
    }
    if (_currentLearningListEntry == null) {
      await _addCurrentVideoToLearningList();
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('取消加入学习清单'),
        content: Text(
          '确定把“${_activeVideo.title}”的 P${_currentPart.pageNumber} 移出学习清单吗？观看记录和笔记不会被删除。',
        ),
        actions: <Widget>[
          TextButton(
            // 保留按钮函数只关闭确认框，不修改学习清单。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('保留'),
          ),
          FilledButton(
            // 取消加入按钮函数把确认结果交回播放器，再执行本机移除操作。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('取消加入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _removeCurrentVideoFromLearningList();
  }

  /// 从本机学习清单移除当前分 P，不影响同视频其他 P、观看记录或笔记。
  Future<void> _removeCurrentVideoFromLearningList() async {
    if (_addingLearningBvid != null) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    final int partCid = _currentPart.cid;
    setState(() => _addingLearningBvid = bvid);
    try {
      await _learningListService.remove(bvid, partCid: partCid);
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != partCid) {
        return;
      }
      setState(() {
        _learningListEntry = null;
        _recordedLearningListPartCid = null;
        _lastLearningListSavedPosition = Duration.zero;
      });
      _showTransientSnackBar('已将当前分 P 移出学习清单');
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('取消加入学习清单失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 查询合集条目的完整资料后加入学习清单；当前正在播放的视频无需重复查询。
  Future<void> _addCollectionVideoToLearningList(
    VideoCollectionEntry entry,
  ) async {
    if (_addingLearningBvid != null) {
      return;
    }
    final String bvid = entry.bvid;
    setState(() => _addingLearningBvid = bvid);
    try {
      final bool currentVideo = bvid == _activeVideo.bvid;
      final VideoPreview video = currentVideo
          ? _activeVideo
          : await _bilibiliService.lookupVideo(bvid);
      final bool hasLivePlayback =
          currentVideo && _playbackSnapshot.phase == PlaybackPhase.ready;
      final List<LearningListEntry> entries = await _learningListService
          .addVideo(
            video,
            part: hasLivePlayback ? _currentPart : null,
            position: hasLivePlayback ? _playbackSnapshot.position : null,
            status: hasLivePlayback && _playing
                ? LearningListStatus.learning
                : null,
          );
      if (!mounted) {
        return;
      }
      if (_activeVideo.bvid == bvid) {
        final LearningListEntry? learningEntry = _entryForPart(
          entries,
          bvid,
          _currentPart.cid,
        );
        setState(() {
          _learningListEntry = learningEntry;
          _recordedLearningListPartCid = learningEntry?.partCid;
          _lastLearningListSavedPosition =
              learningEntry?.position ?? Duration.zero;
        });
      }
      _showPlayerNotice('已加入学习清单');
    } catch (_) {
      if (mounted) {
        _showPlayerNotice('加入学习清单失败，请检查网络后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 从服务返回的任务列表中取出指定 BV 与 CID，避免同视频不同 P 读到错误任务。
  LearningListEntry? _entryForPart(
    List<LearningListEntry> entries,
    String bvid,
    int partCid,
  ) {
    return _learningListService.findEntryForPart(entries, bvid, partCid);
  }

  /// 只返回与画面当前 BV 和 CID 完全一致的任务，异步旧结果不会污染其他分 P 按钮。
  LearningListEntry? get _currentLearningListEntry {
    final LearningListEntry? entry = _learningListEntry;
    if (entry == null ||
        !entry.matchesPart(_activeVideo.bvid, _currentPart.cid)) {
      return null;
    }
    return entry;
  }

  /// 在播放状态真实变化或进度跨过保存间隔时，把当前任务写回学习清单。
  void _recordLearningListProgressWhenNeeded(PlaybackSnapshot snapshot) {
    final LearningListEntry? entry = _currentLearningListEntry;
    if (entry == null ||
        entry.status == LearningListStatus.completed ||
        snapshot.phase != PlaybackPhase.ready) {
      return;
    }
    final int positionDeltaMs =
        (snapshot.position.inMilliseconds -
                _lastLearningListSavedPosition.inMilliseconds)
            .abs();
    final bool partChanged = _recordedLearningListPartCid != _currentPart.cid;
    final bool crossedInterval =
        positionDeltaMs >= _watchHistoryProgressSaveInterval.inMilliseconds;
    final bool startedLearning =
        snapshot.isPlaying && entry.status != LearningListStatus.learning;
    final bool pausedAtNewPosition =
        !snapshot.isPlaying && positionDeltaMs >= 1000;
    if (!partChanged &&
        !crossedInterval &&
        !startedLearning &&
        !pausedAtNewPosition) {
      return;
    }
    _recordedLearningListPartCid = _currentPart.cid;
    unawaited(
      _saveCurrentLearningListProgress(
        snapshot.position,
        status: snapshot.isPlaying ? LearningListStatus.learning : null,
      ),
    );
  }

  /// 在离开、换分P或播放结束前补存学习任务的当前位置，不自动改变完成状态。
  void _flushCurrentLearningListProgress() {
    final LearningListEntry? entry = _currentLearningListEntry;
    if (entry == null ||
        entry.status == LearningListStatus.completed ||
        (_recordedLearningListPartCid != _currentPart.cid &&
            _playbackSnapshot.position == Duration.zero)) {
      return;
    }
    unawaited(
      _saveCurrentLearningListProgress(
        _playbackSnapshot.position,
        status: _playing ? LearningListStatus.learning : null,
        force: true,
      ),
    );
  }

  /// 把当前真实分P和位置持久化给已有任务；不存在的任务不会被播放器静默创建。
  Future<void> _saveCurrentLearningListProgress(
    Duration position, {
    LearningListStatus? status,
    bool force = false,
  }) async {
    final LearningListEntry? entry = _currentLearningListEntry;
    if (entry == null || _learningProgressSaveInFlight) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    final VideoPart part = _currentPart;
    final LearningListStatus? safeStatus =
        entry.status == LearningListStatus.completed
        ? LearningListStatus.completed
        : status;
    final Duration safePosition = position.isNegative
        ? Duration.zero
        : position;
    final int positionDeltaMs =
        (safePosition.inMilliseconds -
                _lastLearningListSavedPosition.inMilliseconds)
            .abs();
    if (!force &&
        _recordedLearningListPartCid == part.cid &&
        positionDeltaMs < 1000 &&
        (safeStatus == null || safeStatus == entry.status)) {
      return;
    }
    _learningProgressSaveInFlight = true;
    try {
      final List<LearningListEntry> entries = await _learningListService
          .updateProgress(
            bvid,
            part: part,
            position: safePosition,
            status: safeStatus,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != part.cid) {
        return;
      }
      final LearningListEntry? updated = _entryForPart(entries, bvid, part.cid);
      if (updated != null) {
        setState(() {
          _learningListEntry = updated;
          _recordedLearningListPartCid = part.cid;
          _lastLearningListSavedPosition = updated.position;
        });
      }
    } catch (_) {
      // 学习清单写入失败不应中断播放；之后的进度检查会再次尝试保存。
    } finally {
      _learningProgressSaveInFlight = false;
    }
  }

  /// 把当前已加入清单的分 P 标记完成，并让按钮立即显示“已标记完成”。
  Future<void> _markCurrentLearningCompleted() async {
    final LearningListEntry? current = _currentLearningListEntry;
    if (_addingLearningBvid != null ||
        current == null ||
        !current.matchesPart(_activeVideo.bvid, _currentPart.cid) ||
        current.status == LearningListStatus.completed) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    setState(() => _addingLearningBvid = bvid);
    try {
      final List<LearningListEntry> entries = await _learningListService
          .updateProgress(
            bvid,
            part: _currentPart,
            position: _displayDuration,
            status: LearningListStatus.completed,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != current.partCid) {
        return;
      }
      final LearningListEntry? completed = _entryForPart(
        entries,
        bvid,
        current.partCid,
      );
      setState(() {
        _learningListEntry = completed;
        _completionPromptVisible = true;
        _completionLearningFinished = false;
        _recordedLearningListPartCid = _currentPart.cid;
        _lastLearningListSavedPosition =
            completed?.position ?? _displayDuration;
      });
      _showPlayerNotice('已标记完成');
    } catch (_) {
      if (mounted) {
        _showPlayerNotice('标记完成失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 完成当前分 P 后在同一播放器内打开下一项；最后一项则保留提示并显示全部完成。
  Future<void> _continueLearningAfterCompletion() async {
    final LearningListEntry? current = _currentLearningListEntry;
    if (_addingLearningBvid != null ||
        current == null ||
        !current.matchesPart(_activeVideo.bvid, _currentPart.cid)) {
      return;
    }
    final String bvid = _activeVideo.bvid;
    setState(() => _addingLearningBvid = bvid);
    try {
      final List<LearningListEntry> beforeCompletion =
          await _learningListService.loadEntries();
      final LearningListEntry? next = _learningListService.nextIncompleteAfter(
        beforeCompletion,
        current,
      );
      final List<LearningListEntry> updatedEntries = await _learningListService
          .updateProgress(
            bvid,
            part: _currentPart,
            position: _displayDuration,
            status: LearningListStatus.completed,
          );
      if (!mounted ||
          _activeVideo.bvid != bvid ||
          _currentPart.cid != current.partCid) {
        return;
      }
      final LearningListEntry? completed = _entryForPart(
        updatedEntries,
        bvid,
        current.partCid,
      );
      if (next == null) {
        setState(() {
          _learningListEntry = completed;
          _completionPromptVisible = true;
          _completionLearningFinished = true;
          _recordedLearningListPartCid = _currentPart.cid;
          _lastLearningListSavedPosition =
              completed?.position ?? _displayDuration;
        });
        _showPlayerNotice('学习清单已完成');
        return;
      }
      final VideoPreview nextVideo = next.bvid == _activeVideo.bvid
          ? _activeVideo
          : await _bilibiliService.lookupVideo(next.bvid);
      if (!mounted || _activeVideo.bvid != bvid) {
        return;
      }
      await _switchActiveVideo(nextVideo, learningEntry: next);
    } catch (_) {
      if (mounted) {
        if (_activeVideo.bvid == bvid && _currentPart.cid == current.partCid) {
          setState(() {
            _learningListEntry = _learningListEntry?.copyWith(
              status: LearningListStatus.completed,
            );
            _completionPromptVisible = true;
            _completionLearningFinished = false;
          });
        }
        _showPlayerNotice('继续学习失败，请稍后重试。');
      }
    } finally {
      if (mounted && _addingLearningBvid == bvid) {
        setState(() => _addingLearningBvid = null);
      }
    }
  }

  /// 请求 Android 创建 Media3 视频纹理，再直接请求公开视频的播放数据。
  Future<void> _initializeNativePlayback() async {
    try {
      final PlaybackPreferences preferences = await _loadPlaybackPreferences();
      final DeviceNetworkType networkType = await _loadNetworkTypeSafely();
      final int preferredQuality = _preferredQualityForNetwork(
        preferences,
        networkType,
      );
      final SavedPlaybackState? savedState = await _playbackService
          .loadSavedPlaybackState(_activeVideo.bvid);
      final SystemPlaybackLevels levels = await _playbackService
          .getSystemPlaybackLevels();
      final VideoPart restoredPart = _findInitialPart(savedState);
      final bool restoredPartMatched =
          widget.initialPartCid == null &&
          savedState != null &&
          restoredPart.cid == savedState.cid;
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPart = restoredPart;
        _brightness = levels.brightness;
        _volume = levels.volume;
        _networkType = networkType;
        _currentQuality = preferredQuality;
        _preferredOpeningQuality = preferredQuality;
        _defaultQualityPending = true;
      });
      unawaited(_loadCurrentLearningListEntry());
      unawaited(_loadPlayerEnhancements());
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
        quality: preferredQuality,
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
    final PlaybackSnapshot previousSnapshot = _playbackSnapshot;
    final bool shouldRestartDanmakuPresentation =
        _shouldRestartDanmakuPresentation(previousSnapshot, snapshot);
    final bool justEnded =
        previousSnapshot.phase != PlaybackPhase.ended &&
        snapshot.phase == PlaybackPhase.ended;
    final bool leftEnded =
        previousSnapshot.phase == PlaybackPhase.ended &&
        snapshot.phase != PlaybackPhase.ended;
    final bool isNewPlaybackError =
        snapshot.phase == PlaybackPhase.error &&
        (previousSnapshot.phase != PlaybackPhase.error ||
            previousSnapshot.message != snapshot.message);
    final Duration? requestedInitialPosition = _pendingInitialPosition;
    final bool shouldSeekToInitialPosition =
        requestedInitialPosition != null &&
        snapshot.phase == PlaybackPhase.ready;
    final bool shouldShowResumeNotice =
        requestedInitialPosition == null &&
        snapshot.phase == PlaybackPhase.ready &&
        snapshot.restoredPosition > Duration.zero &&
        _shownRestoredCid != _currentPart.cid;
    if (shouldSeekToInitialPosition) {
      _pendingInitialPosition = null;
    }
    final int? pendingQuality = _pendingQualitySelection;
    final bool sawQualityLoading =
        pendingQuality != null &&
        (_qualitySelectionSawLoading ||
            snapshot.phase == PlaybackPhase.loading);
    final bool qualitySelectionFinished =
        pendingQuality != null &&
        sawQualityLoading &&
        (snapshot.phase == PlaybackPhase.ready ||
            snapshot.phase == PlaybackPhase.error);
    final bool qualitySelectionFailed =
        qualitySelectionFinished &&
        (snapshot.phase == PlaybackPhase.error ||
            snapshot.currentQuality != pendingQuality);
    final bool shouldResolveDefaultQuality =
        _defaultQualityPending &&
        snapshot.phase == PlaybackPhase.ready &&
        snapshot.availableQualities.isNotEmpty;
    final int? defaultFallbackQuality = shouldResolveDefaultQuality
        ? selectPlaybackQualityAtOrBelow(
            preferredQuality: _preferredOpeningQuality,
            actualQuality: snapshot.currentQuality,
            availableQualities: snapshot.availableQualities.map(
              (PlaybackQuality quality) => quality.id,
            ),
          )
        : null;
    if (shouldResolveDefaultQuality) {
      _defaultQualityPending = false;
    }
    final bool leftPictureInPicture =
        _playbackSnapshot.isInPictureInPicture &&
        !snapshot.isInPictureInPicture;
    final LearningListEntry? currentLearningEntry = _learningListEntry;
    final bool completedLearningEntry =
        justEnded &&
        currentLearningEntry != null &&
        currentLearningEntry.matchesPart(_activeVideo.bvid, _currentPart.cid) &&
        currentLearningEntry.status != LearningListStatus.completed;
    setState(() {
      _playbackSnapshot = snapshot;
      _isRetrying = false;
      if (!_isDraggingProgress &&
          !_horizontalScrubbing &&
          snapshot.duration > Duration.zero) {
        _progress =
            (snapshot.position.inMilliseconds /
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
      if (leftEnded) {
        _interactivePromptVisible = false;
        _completionPromptVisible = false;
        _completionLearningFinished = false;
      }
      if (justEnded) {
        // 互动视频优先显示剧情选择；普通视频仅在当前分 P 已加入学习清单时显示完成操作。
        _interactivePromptVisible =
            _playerEnhancementController.handlesPlaybackCompletion;
        _completionPromptVisible =
            !_interactivePromptVisible && completedLearningEntry;
        _completionLearningFinished = false;
        _showControls = true;
      }
    });
    if (shouldRestartDanmakuPresentation) {
      _restartDanmakuPresentationFrom(snapshot.position);
    }
    _syncDanmakuAnimation(snapshot);
    if (isNewPlaybackError) {
      _recordPlaybackDiagnostic(snapshot, previousSnapshot.phase);
    }
    if (qualitySelectionFailed) {
      _showMembershipQualityNotice();
    }
    if (defaultFallbackQuality != null &&
        defaultFallbackQuality != snapshot.currentQuality) {
      unawaited(_changeQuality(defaultFallbackQuality));
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
      _recordLearningListProgressWhenNeeded(snapshot);
    }
    if (justEnded) {
      _flushCurrentWatchHistoryProgress();
      _flushCurrentLearningListProgress();
    }
    _scheduleInteractiveChoicePrompt(snapshot);
    if (_danmakuEnabled && snapshot.phase == PlaybackPhase.ready) {
      _ensureDanmakuSegmentsForPosition(snapshot.position);
    }
    if (!snapshot.isPlaying || snapshot.isInPictureInPicture) {
      _stopControlsAutoHideTimer();
    } else if (_showControls && _controlsTimer == null) {
      _restartControlsAutoHideTimer();
    }
    _syncFocusPlaybackState(snapshot);
    if (snapshot.phase == PlaybackPhase.ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_maybePromptFocusAssociation());
      });
    }
  }

  /// 识别原生恢复、快进或回退造成的非连续位置；普通进度心跳和倍速播放不会误触发重置。
  bool _shouldRestartDanmakuPresentation(
    PlaybackSnapshot previous,
    PlaybackSnapshot current,
  ) {
    if (!_danmakuEnabled || current.phase != PlaybackPhase.ready) {
      return false;
    }
    final Duration delta = current.position - previous.position;
    if (delta < const Duration(milliseconds: -250)) {
      return true;
    }
    if (previous.phase != PlaybackPhase.ready &&
        delta > const Duration(seconds: 1)) {
      return true;
    }
    return delta > const Duration(seconds: 3);
  }

  /// 把新的原生播放失败写入脱敏问题诊断；不记录 BV、标题、播放地址、Cookie 或服务端响应正文。
  void _recordPlaybackDiagnostic(
    PlaybackSnapshot snapshot,
    PlaybackPhase previousPhase,
  ) {
    final String playerState = switch (previousPhase) {
      PlaybackPhase.loading => 'preparing',
      PlaybackPhase.ready => 'playing',
      PlaybackPhase.ended => 'ended',
      PlaybackPhase.error => 'error',
      PlaybackPhase.idle => 'idle',
    };
    unawaited(
      _problemDiagnosticsService.recordPlaybackFailure(
        message: snapshot.message ?? '无法获取视频播放地址。',
        playerState: playerState,
        multiPart: _activeVideo.parts.length > 1,
      ),
    );
  }

  /// 只在播放状态、BV 或分P真正变化时同步专注控制器，避免重复写本机存储。
  void _syncFocusPlaybackState(PlaybackSnapshot snapshot) {
    final FocusTimerController? controller = _boundFocusController;
    if (controller == null) {
      return;
    }
    if (snapshot.phase == PlaybackPhase.ended) {
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

  /// 快进或快退开始时短暂忽略原生播放器的缓冲暂停，避免勿扰模式被反复关闭和开启。
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

  /// 结束快进保护窗口，并按需把保护期间最后一个真实播放状态同步给专注控制器。
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

  /// 为首页创建且尚未关联的任务询问是否绑定当前真实视频分P。
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

  /// 尝试保存原生播放器当前画面，失败时仍允许关联和退出。
  Future<String?> _captureFocusFrame() async {
    try {
      return await _playbackService.captureCurrentFrame();
    } on Object {
      return null;
    }
  }

  /// 保存当前关联视频的最后画面和播放位置，供首页“上次看到”Pin 展示。
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

  /// 在播放器首次就绪后跳转到笔记或专注记录要求的时间点，并显示对应来源文案。
  Future<void> _seekToRequestedInitialPosition(Duration position) async {
    final String sourceLabel = switch (widget.initialPositionSource) {
      PlayerInitialPositionSource.note => '笔记位置',
      PlayerInitialPositionSource.focus => '专注位置',
      PlayerInitialPositionSource.learning => '学习清单位置',
      PlayerInitialPositionSource.externalLink => '外部链接位置',
    };
    try {
      await _seekNativeTo(position);
      if (mounted) {
        _showTransientSnackBar(
          '已跳转到$sourceLabel：${formatVideoNotePosition(position)}',
        );
      }
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('视频已打开，但暂时无法跳转到$sourceLabel。');
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
    final int positionDeltaMs =
        (snapshot.position.inMilliseconds -
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
    final Duration safePosition = position.isNegative
        ? Duration.zero
        : position;
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
      final List<WatchHistoryEntry> updated = await _watchHistoryService.record(
        entry,
      );
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
    WidgetsBinding.instance.removeObserver(this);
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    final FocusTimerController? focusController = _boundFocusController;
    focusController?.removeListener(_handleFocusStateChanged);
    if (focusController != null) {
      unawaited(
        focusController.updatePlaybackState(
          bvid: _activeVideo.bvid,
          partCid: _currentPart.cid,
          isPlaying: false,
        ),
      );
    }
    _isRetrying = false;
    _controlsTimer?.cancel();
    _interactivePromptTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _focusSeekTransitionTimer?.cancel();
    _resumeNoticeTimer?.cancel();
    _playerNoticeTimer?.cancel();
    _playerStatusTimer?.cancel();
    _notesPanelAnimationTimer?.cancel();
    _flushVideoNoteAutoSave();
    _noteAutoSaveTimer?.cancel();
    _danmakuFrameController.dispose();
    _partScrollController.dispose();
    _collectionPreviewScrollController.dispose();
    _noteTitleController.dispose();
    _noteBodyController.dispose();
    _playerEnhancementController.removeListener(
      _handlePlayerEnhancementChanged,
    );
    _playerEnhancementController.dispose();
    _disposeDescriptionRecognizers();
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
    _finishFocusSeekTransition(syncCurrentSnapshot: false);
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
    if (_controlsLocked) {
      return;
    }
    if (_showControls) {
      _hideControls();
    } else {
      _showPlayerControls();
    }
  }

  /// 显示控制层并在播放状态下重新开始自动收起倒计时。
  void _showPlayerControls() {
    if (_controlsLocked) {
      return;
    }
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
        _temporarySpeedActive ||
        _horizontalScrubbing) {
      return;
    }
    _controlsTimer = Timer(_controlsAutoHideDelay, () {
      if (mounted &&
          _showControls &&
          _playing &&
          !_playbackSnapshot.isInPictureInPicture &&
          !_isDraggingProgress &&
          !_temporarySpeedActive &&
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

  /// 请求原生播放器按相对时长跳转；成功后从目标位置重新生成弹幕，历史内容不会从中间补画。
  Future<void> _seekNativeBy(Duration offset) async {
    final int targetMilliseconds = (_playbackSnapshot.position + offset)
        .inMilliseconds
        .clamp(0, _displayDuration.inMilliseconds);
    _beginFocusSeekTransition();
    try {
      await _playbackService.seekBy(offset);
      _restartDanmakuPresentationFrom(
        Duration(milliseconds: targetMilliseconds),
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法跳转进度：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法跳转进度：$error');
    }
  }

  /// 执行绝对跳转并从目标时间重新生成弹幕，确保跳转前的历史弹幕不会出现在屏幕中段。
  Future<void> _seekNativeTo(Duration position) async {
    _beginFocusSeekTransition();
    await _playbackService.seekTo(position);
    _restartDanmakuPresentationFrom(position);
  }

  /// 把进度条比例换算为真实毫秒位置，再请求原生播放器跳转。
  Future<void> _seekToProgress(double progress) async {
    final Duration target = Duration(
      milliseconds: (_displayDuration.inMilliseconds * progress).round(),
    );
    try {
      await _seekNativeTo(target);
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

  /// 长按正在播放的画面时记住原倍速，并临时切换为三倍速。
  void _startTemporaryTripleSpeed(LongPressStartDetails details) {
    if (!_playing || _temporarySpeedActive || _horizontalScrubbing) {
      return;
    }
    _speedBeforeLongPress = _playbackSpeed;
    _stopControlsAutoHideTimer();
    setState(() {
      _temporarySpeedActive = true;
    });
    unawaited(_setTemporaryPlaybackSpeed(3));
  }

  /// 松开长按手势后恢复长按前的倍速，不改变当前播放进度。
  void _stopTemporaryTripleSpeed(LongPressEndDetails details) {
    if (!_temporarySpeedActive) {
      return;
    }
    final double speedToRestore = _speedBeforeLongPress;
    setState(() {
      _temporarySpeedActive = false;
    });
    unawaited(_setTemporaryPlaybackSpeed(speedToRestore));
    _restartControlsAutoHideTimer();
  }

  /// 长按被系统取消时恢复原倍速，避免手势竞争后残留三倍速状态。
  void _cancelTemporaryLongPress() {
    if (!_temporarySpeedActive) {
      return;
    }
    final double speedToRestore = _speedBeforeLongPress;
    setState(() {
      _temporarySpeedActive = false;
    });
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
    final String suffix = details == null || details.trim().isEmpty
        ? ''
        : '（${details.trim()}）';
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
    await _saveFocusLastSeen();
    await _boundFocusController?.updatePlaybackState(
      bvid: _activeVideo.bvid,
      partCid: _currentPart.cid,
      isPlaying: false,
    );
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    _resetVideoShotPreview();
    setState(() {
      _currentPart = part;
      _progress = 0;
      _showControls = true;
      _resumeNotice = null;
      _partSelectorExpanded = false;
      _learningListEntry = null;
      _learningListLoading = false;
      _completionPromptVisible = false;
      _completionLearningFinished = false;
      _interactivePromptVisible = false;
    });
    _shownRestoredCid = null;
    _recordedHistoryPartCid = null;
    _lastHistorySavedPosition = Duration.zero;
    _recordedLearningListPartCid = null;
    _lastLearningListSavedPosition = Duration.zero;
    _resumeNoticeTimer?.cancel();
    _lastFocusPlaybackBvid = null;
    _lastFocusPlaybackPartCid = null;
    _lastFocusPlaybackPlaying = null;
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_loadPlayerEnhancements());
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

  /// 打开用户明确选择的互动剧情 CID，并提前读取这个节点的下一批选择。
  Future<void> _playInteractiveChoice(InteractiveVideoChoice choice) async {
    if (_interactiveChoiceOpening) {
      return;
    }
    setState(() {
      _interactiveChoiceOpening = true;
      _interactivePromptVisible = false;
      _completionPromptVisible = false;
    });
    await _saveFocusLastSeen();
    await _boundFocusController?.updatePlaybackState(
      bvid: _activeVideo.bvid,
      partCid: _currentPart.cid,
      isPlaying: false,
    );
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    _clearSubtitlesForPart();
    _clearDanmakuForPart();
    _resetVideoShotPreview();
    final VideoPart branchPart = VideoPart(
      pageNumber: _currentPart.pageNumber,
      cid: choice.cid,
      title: choice.label,
      duration: Duration.zero,
    );
    setState(() {
      _currentPart = branchPart;
      _progress = 0;
      _showControls = true;
      _resumeNotice = null;
      _learningListEntry = null;
      _learningListLoading = false;
      _completionLearningFinished = false;
    });
    _shownRestoredCid = null;
    _recordedHistoryPartCid = null;
    _lastHistorySavedPosition = Duration.zero;
    _recordedLearningListPartCid = null;
    _lastLearningListSavedPosition = Duration.zero;
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_playerEnhancementController.selectChoice(choice));
    try {
      await _playbackService.openVideo(
        _activeVideo,
        part: branchPart,
        quality: _currentQuality,
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法打开互动剧情：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法打开互动剧情：$error');
    } finally {
      if (mounted) {
        setState(() => _interactiveChoiceOpening = false);
      }
    }
  }

  /// 跳到章节开始时间，并保持用户原来的播放或暂停状态。
  Future<void> _seekToChapter(Duration position) async {
    try {
      await _seekNativeTo(position);
      if (mounted && _displayDuration > Duration.zero) {
        setState(() {
          _progress =
              (position.inMilliseconds / _displayDuration.inMilliseconds)
                  .clamp(0, 1)
                  .toDouble();
        });
      }
      _showPlayerControls();
    } catch (error) {
      if (mounted) {
        _showPlayerNotice('暂时无法跳转到这个视频分段。');
      }
    }
  }

  /// 打开独立的分段信息面板；竖屏从底部出现，横屏从右侧出现。
  Future<void> _showVideoChapterPanel() async {
    final List<VideoChapter> chapters = _playerEnhancementController.chapters;
    if (chapters.isEmpty) {
      _showPlayerNotice('当前视频没有分段信息。');
      return;
    }
    await showVideoChapterPanel(
      context: context,
      chapters: chapters,
      position: _playbackSnapshot.position,
      chapterProgressVisible:
          _playerEnhancementController.chapterProgressVisible,
      // 分段面板跳转函数把用户选择的开始时间交给原生播放器。
      onSeek: (Duration position) => unawaited(_seekToChapter(position)),
      onToggleChapterProgress:
          _playerEnhancementController.toggleChapterProgress,
    );
  }

  /// 返回当前分P在视频分P列表中的位置。
  int get _currentPartIndex => _activeVideo.parts.indexWhere(
    (VideoPart part) => part.cid == _currentPart.cid,
  );

  /// 切换到当前分P的上一集；已是第一集时保持禁用。
  void _playPreviousPart() {
    final int index = _currentPartIndex;
    if (index > 0) {
      unawaited(_changePart(_activeVideo.parts[index - 1]));
    }
  }

  /// 切换到当前分P的下一集；已是最后一集时保持禁用。
  void _playNextPart() {
    final int index = _currentPartIndex;
    if (index >= 0 && index < _activeVideo.parts.length - 1) {
      unawaited(_changePart(_activeVideo.parts[index + 1]));
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
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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
      color: selected
          ? colors.primaryContainer
          : colors.surfaceContainerHighest,
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

  /// 响应全屏按钮；手动退出时先要求设备回到竖屏，再重新允许后续自动旋转。
  Future<void> _toggleFullscreen() async {
    final bool nextFullscreen = !_fullscreen;
    if (!nextFullscreen) {
      _suppressAutoFullscreenUntilPortrait = true;
      _restoreOrientationChoicesOnPortrait = true;
    }
    await _setFullscreen(nextFullscreen);
  }

  /// 统一切换全屏布局，并区分按钮触发和设备旋转触发的方向控制行为。
  Future<void> _setFullscreen(
    bool nextFullscreen, {
    bool updateOrientation = true,
    bool enteredByOrientation = false,
  }) async {
    if (!mounted || _fullscreen == nextFullscreen) {
      return;
    }
    _reanchorDanmakuForViewportChange();
    setState(() {
      _fullscreen = nextFullscreen;
      _fullscreenEnteredByOrientation = nextFullscreen && enteredByOrientation;
      _controlsLocked = nextFullscreen ? _controlsLocked : false;
      _showControls = true;
      // 从竖屏笔记本进入全屏时直接挂载全屏工作区；退出时保留笔记打开状态给竖屏布局继续使用。
      _notesOverlayMounted = nextFullscreen && _notesOpen;
    });
    _restartControlsAutoHideTimer();
    if (nextFullscreen) {
      if (updateOrientation) {
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _appliedSystemUiLayout = _PlayerSystemUiLayout.fullscreen;
    } else if (updateOrientation) {
      await _restoreSystemUi();
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _appliedSystemUiLayout = _PlayerSystemUiLayout.standard;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      _reanchorDanmakuForViewportChange();
    }
  }

  /// 锁定或解锁全屏控制层；锁定后仅保留左侧解锁按钮并停用画面手势。
  void _toggleControlsLock() {
    if (!_fullscreen) {
      return;
    }
    _stopControlsAutoHideTimer();
    setState(() {
      _controlsLocked = !_controlsLocked;
      _showControls = !_controlsLocked;
      if (_controlsLocked) {
        _partSelectorExpanded = false;
      }
    });
    if (!_controlsLocked) {
      _restartControlsAutoHideTimer();
    }
  }

  /// 在本帧布局确定后按顶部栏真实可见性启停状态刷新，避免用平台尺寸猜测布局。
  void _schedulePlayerStatusVisibility(bool visible) {
    _pendingPlayerStatusVisible = visible;
    if (!visible) {
      _stopPlayerStatusUpdates();
      return;
    }
    if (_playerStatusSyncScheduled) {
      return;
    }
    _playerStatusSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playerStatusSyncScheduled = false;
      if (!mounted) {
        return;
      }
      if (_pendingPlayerStatusVisible && _playerStatusTimer == null) {
        _startPlayerStatusUpdates();
      }
    });
  }

  /// 播放器顶部可见期间每分钟刷新时间和电量，横屏工作台与全屏直接复用结果。
  void _startPlayerStatusUpdates() {
    _stopPlayerStatusUpdates();
    _playerClock = DateTime.now();
    unawaited(_refreshPlayerDeviceStatus());
    _playerStatusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _refreshPlayerStatus();
    });
  }

  /// 停止播放器设备状态定时器，避免退出页面后仍保留回调。
  void _stopPlayerStatusUpdates() {
    _playerStatusTimer?.cancel();
    _playerStatusTimer = null;
  }

  /// 立即刷新显示时间，并异步读取 Android 提供的当前电量百分比。
  void _refreshPlayerStatus() {
    if (!mounted) {
      return;
    }
    setState(() => _playerClock = DateTime.now());
    unawaited(_refreshPlayerDeviceStatus());
  }

  /// 读取电量和网络类型后确认页面仍存在，再更新顶部小型状态栏。
  Future<void> _refreshPlayerDeviceStatus() async {
    final int? batteryPercent = await _loadBatteryPercentSafely();
    final DeviceNetworkType networkType = await _loadNetworkTypeSafely();
    if (!mounted) {
      return;
    }
    setState(() {
      _batteryPercent = batteryPercent;
      _networkType = networkType;
    });
  }

  /// 计算当前分P尚未播放的时长，并限制在专注模块允许的 1 到 180 分钟内。
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

  /// 使用播放器真实总时长和当前位置计算当前分 P 剩余时间，不套用专注时长的一分钟下限。
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

  /// 打开播放器专注面板，提供当前分P计划及活动计时控制。
  Future<void> _openPlayerFocusSheet() async {
    final FocusTimerController? controller = _boundFocusController;
    if (controller == null) {
      _showPlayerNotice('专注控制器尚未准备好');
      return;
    }
    await showPlayerFocusDoNotDisturbGuideIfNeeded(context);
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

  /// 离开全屏后恢复手机竖屏或平板横屏，并重新启用 edge-to-edge 系统栏。
  Future<void> _restoreSystemUi() async {
    final List<FlutterView> views = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .toList();
    if (views.isNotEmpty) {
      final List<DeviceOrientation>
      orientations = DeviceOrientationPolicy.startupOrientations(
        logicalSize: DeviceOrientationPolicy.logicalSizeForView(views.first),
        isAndroid: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
      );
      if (orientations.isNotEmpty) {
        await SystemChrome.setPreferredOrientations(orientations);
      }
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _appliedSystemUiLayout = _PlayerSystemUiLayout.standard;
  }

  /// 处理顶部返回按钮：先关闭笔记，再退出全屏或返回上一支合集视频。
  void _handleBackPressed() {
    if (_controlsLocked) {
      _toggleControlsLock();
    } else if (_notesOpen) {
      _closeVideoNotes();
    } else if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_collectionVideoBackStack.isNotEmpty) {
      unawaited(_restorePreviousCollectionVideo());
    } else {
      unawaited(_requestLeavePlayer());
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

  /// 接收系统返回结果：依次关闭笔记、全屏和合集内部页面，再允许离开播放页。
  void _handlePopInvoked(bool didPop, Object? result) {
    if (didPop) {
      return;
    }
    if (_controlsLocked) {
      _toggleControlsLock();
    } else if (_notesOpen) {
      _closeVideoNotes();
    } else if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_collectionVideoBackStack.isNotEmpty) {
      unawaited(_restorePreviousCollectionVideo());
    } else {
      unawaited(_requestLeavePlayer());
    }
  }

  /// 切换顶部弹幕按钮；实际的片段加载、动画启停和持久化统一交给配置应用函数。
  void _toggleDanmaku() {
    _applyDanmakuPreferences(
      _danmakuPreferences.copyWith(enabled: !_danmakuEnabled),
    );
    _showPlayerControls();
  }

  /// 立即应用已归一化配置；筛选规则只重建内存索引，不重复下载同一弹幕段。
  void _applyDanmakuPreferences(DanmakuPreferences preferences) {
    final DanmakuPreferences previous = _danmakuPreferences;
    final bool enabledChanged = preferences.enabled != previous.enabled;
    final bool filteringRulesChanged =
        !listEquals(preferences.blockedKeywords, previous.blockedKeywords) ||
        preferences.showScrolling != previous.showScrolling ||
        preferences.showTop != previous.showTop ||
        preferences.showBottom != previous.showBottom ||
        preferences.mergeRepeated != previous.mergeRepeated;
    final bool shouldRestartPresentation =
        preferences.enabled && (enabledChanged || filteringRulesChanged);
    final Duration presentationStart = _currentDanmakuTimelinePosition();
    if (shouldRestartPresentation) {
      _danmakuPresentationWindow.restartFrom(presentationStart);
    }
    _danmakuPreferencesChangedByUser = true;
    setState(() {
      _danmakuPreferences = preferences;
      if (filteringRulesChanged) {
        _rebuildDanmakuSegments();
      } else if (shouldRestartPresentation) {
        _rebuildDanmakuSegment(
          DanmakuSegmentLoadResult.segmentIndexForPosition(presentationStart),
        );
      }
    });
    _danmakuLanePlanner.clear();
    unawaited(_persistDanmakuPreferences(preferences));

    if (!preferences.enabled) {
      _danmakuFrameController.stop();
      _danmakuFrameController.value = 0;
      return;
    }
    if (enabledChanged) {
      // 重新开启时允许曾达到上限的分段再次自动重试。
      _danmakuSegmentFailureCounts.clear();
      _danmakuSegmentRetryAfter.clear();
    }
    if (enabledChanged || filteringRulesChanged) {
      _ensureDanmakuSegmentsForPosition(_playbackSnapshot.position);
      _syncDanmakuAnimation(_playbackSnapshot);
    }
  }

  /// 使用当前偏好和呈现起点重建一个片段，并保存稳定列表供车道布局缓存复用。
  void _rebuildDanmakuSegment(int segmentIndex) {
    final List<DanmakuEntry>? rawEntries = _rawDanmakuSegments[segmentIndex];
    if (rawEntries == null) {
      _danmakuSegments.remove(segmentIndex);
      return;
    }
    final List<DanmakuEntry> indexedEntries = DanmakuTimelineIndex.fromEntries(
      rawEntries,
      _danmakuPreferences,
    ).entries;
    _danmakuSegments[segmentIndex] = _danmakuPresentationWindow.filterEntries(
      segmentIndex: segmentIndex,
      entries: indexedEntries,
    );
  }

  /// 使用当前类型、关键词和合并规则重新建立所有已下载片段的 100ms 时间索引。
  void _rebuildDanmakuSegments() {
    _danmakuSegments.clear();
    for (final int segmentIndex in _rawDanmakuSegments.keys) {
      _rebuildDanmakuSegment(segmentIndex);
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
    final int realElapsedMicroseconds =
        (_danmakuFrameController.value *
                _danmakuFrameController.duration!.inMicroseconds)
            .round();
    return DanmakuTimeline.advance(
      positionAnchor: _danmakuPositionAnchor,
      realElapsed: Duration(microseconds: realElapsedMicroseconds),
      playbackSpeed: _playbackSpeed,
    );
  }

  /// 从指定视频位置开启新的弹幕呈现窗口，并立即刷新已缓存的目标片段。
  void _restartDanmakuPresentationFrom(Duration position) {
    if (!_danmakuEnabled) {
      return;
    }
    _danmakuPresentationWindow.restartFrom(position);
    final int segmentIndex = DanmakuSegmentLoadResult.segmentIndexForPosition(
      position,
    );
    _rebuildDanmakuSegment(segmentIndex);
    _danmakuLanePlanner.clear();
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
    _rawDanmakuSegments.clear();
    _danmakuSegments.clear();
    _loadingDanmakuSegments.clear();
    _danmakuSegmentFailureCounts.clear();
    _danmakuSegmentRetryAfter.clear();
    _danmakuPresentationWindow.clear();
    _danmakuLanePlanner.clear();
  }

  /// 根据连续失败次数生成短退避，避免临时网络问题时每个 500ms 进度快照都立即重试。
  Duration _danmakuRetryDelay(int failureCount) {
    return Duration(seconds: failureCount * 2);
  }

  /// 确保当前片段存在，并在接近六分钟边界时预取下一片段减少播放中的等待。
  void _ensureDanmakuSegmentsForPosition(Duration position) {
    if (!_danmakuEnabled || _playbackSnapshot.isInPictureInPicture) {
      return;
    }
    final int currentSegment = DanmakuSegmentLoadResult.segmentIndexForPosition(
      position,
    );
    unawaited(_loadDanmakuSegment(currentSegment));
    final int positionInSegmentMilliseconds =
        position.inMilliseconds %
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

  /// 请求一段真实弹幕并建立时间索引；临时失败最多自动重试三次且带递增退避。
  Future<void> _loadDanmakuSegment(int segmentIndex) async {
    final int failureCount = _danmakuSegmentFailureCounts[segmentIndex] ?? 0;
    final DateTime? retryAfter = _danmakuSegmentRetryAfter[segmentIndex];
    if (!_danmakuEnabled ||
        segmentIndex < 1 ||
        segmentIndex > DanmakuSegmentLoadResult.maximumSegmentIndex ||
        _rawDanmakuSegments.containsKey(segmentIndex) ||
        _loadingDanmakuSegments.contains(segmentIndex) ||
        failureCount >= _maximumDanmakuSegmentRetries ||
        (retryAfter != null && DateTime.now().isBefore(retryAfter))) {
      return;
    }
    final int requestToken = _danmakuRequestToken;
    _loadingDanmakuSegments.add(segmentIndex);
    final DanmakuSegmentLoadResult result = await _playerOverlayService
        .loadDanmakuSegment(
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
      final int nextFailureCount = failureCount + 1;
      _danmakuSegmentFailureCounts[segmentIndex] = nextFailureCount;
      if (nextFailureCount < _maximumDanmakuSegmentRetries) {
        _danmakuSegmentRetryAfter[segmentIndex] = DateTime.now().add(
          _danmakuRetryDelay(nextFailureCount),
        );
        if (nextFailureCount == 1) {
          _showTransientSnackBar('${result.message} 将自动重试。');
        }
      } else {
        _danmakuSegmentRetryAfter.remove(segmentIndex);
        _showTransientSnackBar('${result.message} 本片段已暂停自动重试。');
      }
      return;
    }
    _danmakuSegmentFailureCounts.remove(segmentIndex);
    _danmakuSegmentRetryAfter.remove(segmentIndex);
    final Duration presentationPosition = _currentDanmakuTimelinePosition();
    setState(() {
      // 原始条目保留在会话内，设置变化时只重建 100ms 时间索引，不再次请求网络。
      _rawDanmakuSegments[result.segmentIndex] = result.entries;
      _danmakuPresentationWindow.prepareSegment(
        segmentIndex: result.segmentIndex,
        currentPosition: presentationPosition,
      );
      _rebuildDanmakuSegment(result.segmentIndex);
    });
    _trimDanmakuSegments(
      DanmakuSegmentLoadResult.segmentIndexForPosition(
        _playbackSnapshot.position,
      ),
    );
  }

  /// 仅保留当前位置前后相邻的少量弹幕片段，防止长视频连续观看时内存持续增长。
  void _trimDanmakuSegments(int currentSegment) {
    final List<int> staleFailures = _danmakuSegmentFailureCounts.keys
        .where((int index) => (index - currentSegment).abs() > 1)
        .toList(growable: false);
    for (final int index in staleFailures) {
      _danmakuSegmentFailureCounts.remove(index);
      _danmakuSegmentRetryAfter.remove(index);
    }
    if (_rawDanmakuSegments.length <= _maximumCachedDanmakuSegments) {
      return;
    }
    final List<int> removableSegments = _rawDanmakuSegments.keys
        .where((int index) => (index - currentSegment).abs() > 1)
        .toList(growable: false);
    for (final int index in removableSegments) {
      _removeDanmakuSegment(index);
    }
    while (_rawDanmakuSegments.length > _maximumCachedDanmakuSegments) {
      final int oldestIndex = _rawDanmakuSegments.keys.reduce(
        (int left, int right) =>
            (left - currentSegment).abs() >= (right - currentSegment).abs()
            ? left
            : right,
      );
      _removeDanmakuSegment(oldestIndex);
    }
  }

  /// 同步移除一个片段的原始数据、索引和失败状态，防止长视频缓存只清掉其中一层。
  void _removeDanmakuSegment(int segmentIndex) {
    _rawDanmakuSegments.remove(segmentIndex);
    _danmakuSegments.remove(segmentIndex);
    _danmakuSegmentFailureCounts.remove(segmentIndex);
    _danmakuSegmentRetryAfter.remove(segmentIndex);
    _danmakuPresentationWindow.forgetSegment(segmentIndex);
  }

  /// 返回当前六分钟片段的真实弹幕列表；未加载、为空或关闭弹幕时返回空列表。
  List<DanmakuEntry> _currentDanmakuEntries() {
    if (!_danmakuEnabled) {
      return const <DanmakuEntry>[];
    }
    final int segmentIndex = DanmakuSegmentLoadResult.segmentIndexForPosition(
      _currentDanmakuTimelinePosition(),
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
    final SubtitleTrackLoadResult result = await _playerOverlayService
        .loadSubtitleTracks(bvid: _activeVideo.bvid, cid: _currentPart.cid);
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
    final SubtitleCueLoadResult result = await _playerOverlayService
        .loadSubtitleCues(
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
                color: Colors.black.withValues(alpha: 0.62),
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
                      const Text('显示类型'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: <Widget>[
                          FilterChip(
                            key: const Key('danmaku-show-scrolling'),
                            label: const Text('滚动'),
                            selected: value.showScrolling,
                            onSelected: (bool selected) =>
                                update(value.copyWith(showScrolling: selected)),
                          ),
                          FilterChip(
                            key: const Key('danmaku-show-top'),
                            label: const Text('顶部'),
                            selected: value.showTop,
                            onSelected: (bool selected) =>
                                update(value.copyWith(showTop: selected)),
                          ),
                          FilterChip(
                            key: const Key('danmaku-show-bottom'),
                            label: const Text('底部'),
                            selected: value.showBottom,
                            onSelected: (bool selected) =>
                                update(value.copyWith(showBottom: selected)),
                          ),
                        ],
                      ),
                      SwitchListTile(
                        key: const Key('danmaku-merge-repeated'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('合并同时出现的相同弹幕'),
                        subtitle: const Text('减少刷屏和文字排版开销，并显示合并数量'),
                        value: value.mergeRepeated,
                        onChanged: (bool enabled) =>
                            update(value.copyWith(mergeRepeated: enabled)),
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
                        label: '显示区域',
                        valueLabel: '顶部 ${(value.displayArea * 100).round()}%',
                        rangeLabel: '25%–100%',
                        value: value.displayArea,
                        min: DanmakuPreferences.minDisplayArea,
                        max: DanmakuPreferences.maxDisplayArea,
                        divisions: 3,
                        onChanged: (double item) =>
                            update(value.copyWith(displayArea: item)),
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
                        onChanged: (double item) =>
                            update(value.copyWith(scrollDurationSeconds: item)),
                      ),
                      sliderRow(
                        label: '文字描边',
                        valueLabel: value.strokeWidth == 0
                            ? '关闭'
                            : value.strokeWidth.toStringAsFixed(1),
                        rangeLabel: '0–3',
                        value: value.strokeWidth,
                        min: DanmakuPreferences.minStrokeWidth,
                        max: DanmakuPreferences.maxStrokeWidth,
                        divisions: 6,
                        onChanged: (double item) =>
                            update(value.copyWith(strokeWidth: item)),
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

  /// 构建“更多”菜单，只保留字幕、弹幕和画面比例等次级播放器设置。
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
        child: Row(
          children: <Widget>[
            Icon(Icons.tune_rounded),
            SizedBox(width: 8),
            Text('弹幕设置'),
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
      final bool entered = await _playbackService.enterPictureInPicture(
        aspectRatio,
      );
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
          child: AspectRatio(
            key: const Key('video-fit-contain'),
            aspectRatio: aspectRatio,
            child: texture,
          ),
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
        key: Key(fit == BoxFit.cover ? 'video-fit-cover' : 'video-fit-stretch'),
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
                onPressed: _isRetrying
                    ? null
                    : () => unawaited(_retryPlayback()),
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
      final List<VideoNote> notes = await _videoNoteService.loadNotesForVideo(
        _activeVideo.bvid,
      );
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
    _flushVideoNoteAutoSave();
    setState(() {
      _noteDraftRevision += 1;
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
    _flushVideoNoteAutoSave();
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
    _scheduleOrientationSync();
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

  /// 选择已有笔记并填入编辑器；播放位置只会由显式跳转按钮改变。
  void _selectVideoNote(VideoNote note) {
    final VideoPart targetPart = _findVideoNotePart(note.partCid);
    _noteAutoSaveTimer?.cancel();
    _noteAutoSaveTimer = null;
    setState(() {
      _noteDraftRevision += 1;
      _editingVideoNote = note;
      _noteTitleController.text = note.title;
      _noteBodyController.text = note.body;
      _notePosition = note.position;
      _notePartCid = targetPart.cid;
      _includeCurrentFrame = note.framePath != null;
      _noteFramePath = note.framePath;
    });
  }

  /// 只在用户点击显式按钮时跳转到当前编辑笔记的分P和时间点。
  Future<void> _jumpToSelectedVideoNotePosition() async {
    final VideoNote? note = _editingVideoNote;
    if (note == null) {
      _showTransientSnackBar('请先选择一条笔记。');
      return;
    }
    final VideoPart targetPart = _findVideoNotePart(note.partCid);
    try {
      if (targetPart.cid != _currentPart.cid) {
        await _changePart(targetPart);
      }
      await _seekNativeTo(note.position);
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('暂时无法跳转到这个笔记的时间点。');
      }
    }
  }

  /// 更新“插入当前画面”选择，取消时只影响本次保存，不立即删除旧文件。
  void _setIncludeCurrentFrame(bool selected) {
    setState(() => _includeCurrentFrame = selected);
    _scheduleVideoNoteAutoSave();
  }

  /// 在标题或正文停止输入片刻后自动保存，避免频繁写入本机偏好设置。
  void _handleVideoNoteDraftChanged(String value) {
    if (!_notesOpen || _noteSaving) {
      return;
    }
    _scheduleVideoNoteAutoSave();
  }

  /// 重置输入去抖计时器；空白草稿不会创建无意义的本机笔记。
  void _scheduleVideoNoteAutoSave() {
    _noteAutoSaveTimer?.cancel();
    if (_noteTitleController.text.trim().isEmpty &&
        _noteBodyController.text.trim().isEmpty) {
      return;
    }
    _noteAutoSaveTimer = Timer(_noteAutoSaveDelay, () {
      _noteAutoSaveTimer = null;
      unawaited(_saveVideoNote(automatic: true));
    });
  }

  /// 立即提交仍在等待去抖的草稿，供新建、关闭、换视频和离开播放器前调用。
  void _flushVideoNoteAutoSave() {
    final Timer? timer = _noteAutoSaveTimer;
    if (timer == null) {
      return;
    }
    timer.cancel();
    _noteAutoSaveTimer = null;
    if (_noteTitleController.text.trim().isNotEmpty ||
        _noteBodyController.text.trim().isNotEmpty) {
      unawaited(_saveVideoNote(automatic: true));
    }
  }

  /// 等待原生播放器把目标时间点真正渲染到 Surface，再执行截图。
  Future<void> _waitForNoteFramePosition(Duration target) async {
    for (int attempt = 0; attempt < 30; attempt += 1) {
      final int difference = (_playbackSnapshot.position - target)
          .inMilliseconds
          .abs();
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
      await _seekNativeTo(_notePosition);
      await _waitForNoteFramePosition(_notePosition);
      return await _playbackService.captureCurrentFrame();
    } finally {
      if (returnPart.cid != _currentPart.cid) {
        await _changePart(returnPart);
        await _playbackService.pause();
      }
      await _seekNativeTo(returnPosition);
      if (shouldResume) {
        await _playbackService.play();
      }
    }
  }

  /// 保存标题、正文、自动记录时间、视频位置和可选画面；自动保存不会反复弹出提示。
  Future<void> _saveVideoNote({bool automatic = false}) async {
    if (_noteSaving) {
      return;
    }
    final String enteredTitle = _noteTitleController.text.trim();
    final String body = _noteBodyController.text.trim();
    if (enteredTitle.isEmpty && !automatic) {
      _showTransientSnackBar('请先填写笔记标题。');
      return;
    }
    if (enteredTitle.isEmpty && body.isEmpty) {
      return;
    }
    final String title = enteredTitle.isEmpty ? '未命名笔记' : enteredTitle;
    final VideoNote? existing = _editingVideoNote;
    final int draftRevision = _noteDraftRevision;
    final bool includeFrame = _includeCurrentFrame;
    final int notePartCid = _notePartCid;
    final Duration notePosition = _notePosition;
    setState(() => _noteSaving = true);
    String? framePath = includeFrame ? _noteFramePath : null;
    try {
      if (includeFrame && framePath == null && !automatic) {
        framePath = await _captureFrameAtNotePosition();
        if (framePath == null) {
          throw PlatformException(
            code: 'frame_capture_failed',
            message: '没有取得当前视频画面。',
          );
        }
      }
      final DateTime now = DateTime.now();
      final VideoPart notePart = _findVideoNotePart(notePartCid);
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
              body: body,
              createdAt: now,
              updatedAt: now,
              position: notePosition,
              videoCoverUrl: _activeVideo.thumbnailUrl,
              framePath: framePath,
            )
          : existing.copyWith(
              title: title,
              body: body,
              updatedAt: now,
              position: notePosition,
              framePath: framePath,
              clearFrame: !includeFrame,
            );
      await _videoNoteService.saveNote(note);
      if (!mounted) {
        return;
      }
      setState(() {
        if (draftRevision == _noteDraftRevision) {
          _editingVideoNote = note;
          _noteFramePath = note.framePath;
        }
        _noteSaving = false;
        _notesLoading = true;
      });
      await _loadCurrentVideoNotes();
      if (mounted && !automatic) {
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
        _noteDraftRevision += 1;
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
      return _buildDetailImagePlaceholder(width, height, placeholderIcon);
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(icon),
      ),
    );
  }

  /// 当下层播放器夺走唯一原生通道时，重新创建纹理并打开当前视频，恢复原页面的播放所有权。
  Future<void> _restorePlaybackAfterNestedPlayer({
    required bool shouldResume,
  }) async {
    final PlaybackService service = _playbackService;
    if (service is! NativePlaybackService || service.ownsPlatformChannel) {
      return;
    }
    try {
      final int? textureId = await service.initialize();
      if (!mounted) {
        return;
      }
      setState(() {
        _textureId = textureId;
        _playbackSnapshot = _playbackSnapshot.copyWith(
          phase: PlaybackPhase.loading,
          isPlaying: false,
          message: '正在恢复原视频…',
        );
      });
      await service.openVideo(
        _activeVideo,
        part: _currentPart,
        quality: _currentQuality,
      );
      if (_playbackSpeed != 1) {
        await service.setPlaybackSpeed(_playbackSpeed);
      }
      if (!shouldResume) {
        await service.pause();
      }
    } catch (error) {
      if (mounted) {
        _showPlaybackError('返回原视频时恢复播放失败：$error');
      }
    }
  }

  /// 返回播放页后重新隐藏横屏状态栏，并立即执行一次布局对应的系统栏同步。
  void _resumePlayerSystemUiAfterNestedRoute() {
    _appliedSystemUiLayout = null;
    final Size size = MediaQuery.sizeOf(context);
    _schedulePlayerSystemUiSync(landscapeLayout: size.width > size.height);
  }

  /// 暂停当前视频后打开 UP 主公开主页，返回时重建被下层播放器占用的原生会话。
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
    await _showStandardSystemUiForNestedRoute();
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
          learningListService: _learningListService,
          watchHistoryService: _watchHistoryService,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    _resumePlayerSystemUiAfterNestedRoute();
    await _restorePlaybackAfterNestedPlayer(shouldResume: shouldResume);
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

  /// 复用现有纹理打开另一支视频；学习任务可精确指定分 P 与进度，避免替换页面释放新播放器。
  Future<void> _switchActiveVideo(
    VideoPreview video, {
    LearningListEntry? learningEntry,
  }) async {
    await _saveFocusLastSeen();
    await _boundFocusController?.updatePlaybackState(
      bvid: _activeVideo.bvid,
      partCid: _currentPart.cid,
      isPlaying: false,
    );
    _notesPanelAnimationTimer?.cancel();
    _flushVideoNoteAutoSave();
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    await _playbackService.pause();
    final SavedPlaybackState? savedState = await _playbackService
        .loadSavedPlaybackState(video.bvid);
    VideoPart targetPart = video.initialPart;
    final LearningListEntry? requestedLearningEntry =
        learningEntry != null && learningEntry.bvid == video.bvid
        ? learningEntry
        : null;
    if (requestedLearningEntry != null) {
      for (final VideoPart part in video.parts) {
        if (part.cid == requestedLearningEntry.partCid) {
          targetPart = part;
          break;
        }
        if (part.pageNumber == requestedLearningEntry.partPageNumber) {
          targetPart = part;
        }
      }
    } else if (savedState != null) {
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
      _learningListEntry = requestedLearningEntry;
      _learningListLoading = false;
      _completionPromptVisible = false;
      _completionLearningFinished = false;
      _interactivePromptVisible = false;
      _interactiveChoiceOpening = false;
    });
    _shownRestoredCid = null;
    _recordedHistoryPartCid = null;
    _lastHistorySavedPosition = Duration.zero;
    _recordedLearningListPartCid = null;
    _lastLearningListSavedPosition =
        requestedLearningEntry?.position ?? Duration.zero;
    _pendingInitialPosition =
        requestedLearningEntry != null &&
            requestedLearningEntry.position > Duration.zero
        ? requestedLearningEntry.position
        : null;
    _resumeNoticeTimer?.cancel();
    _lastFocusPlaybackBvid = null;
    _lastFocusPlaybackPartCid = null;
    _lastFocusPlaybackPlaying = null;
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_loadPlayerEnhancements());
    await _playbackService.openVideo(
      video,
      part: targetPart,
      quality: _currentQuality,
    );
    if (requestedLearningEntry == null &&
        savedState != null &&
        video.parts.length > 1) {
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
    final VideoShotFrame? frame = _horizontalScrubbing
        ? _videoShotPreview?.frameFor(target)
        : null;
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

  /// 创建仅属于学习清单任务的完播选择层，并随底部播放栏上浮以避免内容重叠。
  Widget _buildPlaybackCompletionPrompt() {
    if (!_completionPromptVisible || _playbackSnapshot.isInPictureInPicture) {
      return const SizedBox.shrink();
    }
    final LearningListEntry? currentEntry = _currentLearningListEntry;
    final bool markingCompleted = _addingLearningBvid == _activeVideo.bvid;
    final bool markedCompleted =
        currentEntry?.status == LearningListStatus.completed;
    final bool controlsVisible = _showControls && !_controlsLocked;
    final double fullscreenSafeBottom = _fullscreen
        ? MediaQuery.paddingOf(context).bottom
        : 0;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      left: 16,
      right: 16,
      bottom: (controlsVisible ? 78 : 14) + fullscreenSafeBottom,
      child: Center(
        child: PlaybackCompletionOverlay(
          markedCompleted: markedCompleted,
          learningFinished: _completionLearningFinished,
          processing: markingCompleted,
          // 完成回调只更新当前学习任务，不改变播放器分P。
          onMarkCompleted: () => unawaited(_markCurrentLearningCompleted()),
          // 继续学习回调只在用户明确点击后按学习清单顺序打开下一条任务。
          onContinueLearning: () =>
              unawaited(_continueLearningAfterCompletion()),
        ),
      ),
    );
  }

  /// 创建互动视频完播选择层，加载失败时允许重试但绝不会替用户自动选择。
  Widget _buildInteractiveVideoPrompt() {
    if (!_interactivePromptVisible || _playbackSnapshot.isInPictureInPicture) {
      return const SizedBox.shrink();
    }
    final bool controlsVisible = _showControls && !_controlsLocked;
    final double fullscreenSafeBottom = _fullscreen
        ? MediaQuery.paddingOf(context).bottom
        : 0;
    return InteractiveVideoChoiceOverlay(
      node: _playerEnhancementController.interactiveNode,
      loading:
          _playerEnhancementController.interactiveNodeLoading ||
          _interactiveChoiceOpening,
      errorMessage: _playerEnhancementController.interactiveNodeError,
      bottomInset: (controlsVisible ? 82 : 14) + fullscreenSafeBottom,
      // 剧情按钮函数只播放用户明确点击的目标分支。
      onChoiceSelected: (InteractiveVideoChoice choice) {
        unawaited(_playInteractiveChoice(choice));
      },
      // 重试函数重新请求当前节点，不触发播放和跳转。
      onRetry: () {
        unawaited(_playerEnhancementController.retryInteractiveNode());
      },
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
            // 合集面板加入函数沿用播放器的完整视频查询与学习清单服务。
            onAddToLearningList: (VideoCollectionEntry entry) =>
                unawaited(_addCollectionVideoToLearningList(entry)),
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
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
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
          _buildExpandableDescription(),
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
              Icons.thumb_up_alt_outlined,
              '点赞',
              stats.likeCount,
            ),
            _buildReadOnlyStat(Icons.paid_outlined, '投币', stats.coinCount),
            _buildReadOnlyStat(
              Icons.star_border_rounded,
              '收藏',
              stats.favoriteCount,
            ),
            _buildReadOnlyStat(Icons.share_outlined, '分享', stats.shareCount),
          ],
        ),
      ],
    );
  }

  /// 创建放在“记笔记”左侧的学习清单按钮，并根据加入状态切换文字和图标。
  Widget _buildCurrentVideoLearningListButton() {
    final LearningListEntry? currentEntry = _currentLearningListEntry;
    final bool busy =
        _learningListLoading || _addingLearningBvid == _activeVideo.bvid;
    return Tooltip(
      message: currentEntry == null ? '加入学习清单' : '取消加入学习清单',
      child: TextButton.icon(
        key: const Key('current-video-learning-list-button'),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        // 顶部学习清单按钮函数会在加入与取消加入之间切换，并在取消前要求确认。
        onPressed: busy
            ? null
            : () => unawaited(_handleCurrentVideoLearningListTap()),
        icon: busy
            ? const SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                currentEntry == null
                    ? Icons.playlist_add_rounded
                    : Icons.playlist_add_check_rounded,
                size: 20,
              ),
        label: Text(
          _learningListLoading
              ? '读取中…'
              : currentEntry == null
              ? '加入 P${_currentPart.pageNumber}'
              : currentEntry.status == LearningListStatus.completed
              ? 'P${_currentPart.pageNumber} 已完成'
              : 'P${_currentPart.pageNumber} 已加入',
        ),
      ),
    );
  }

  /// 创建最多三行的简介；确实溢出时才显示蓝色展开文字，并保留 @UP 点击能力。
  Widget _buildExpandableDescription() {
    final TextStyle style =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: _activeVideo.description, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 3,
        )..layout(maxWidth: constraints.maxWidth);
        final bool exceedsThreeLines = painter.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text.rich(
              TextSpan(style: style, children: _buildDescriptionSpans(style)),
              key: const Key('video-description'),
              maxLines: _descriptionExpanded ? null : 3,
              overflow: _descriptionExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (exceedsThreeLines || _descriptionExpanded)
              TextButton(
                key: const Key('toggle-video-description'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                // 展开按钮函数只改变简介行数，不影响播放器或页面滚动位置。
                onPressed: () => setState(
                  () => _descriptionExpanded = !_descriptionExpanded,
                ),
                child: Text(_descriptionExpanded ? '收起' : '展开'),
              ),
          ],
        );
      },
    );
  }

  /// 把普通简介、结构化 @UP 和 HTTP(S) 地址转换为富文本及可点击入口。
  List<InlineSpan> _buildDescriptionSpans(TextStyle baseStyle) {
    final List<VideoDescriptionSegment> segments =
        _activeVideo.descriptionSegments.isEmpty
        ? <VideoDescriptionSegment>[
            VideoDescriptionSegment(text: _activeVideo.description),
          ]
        : _activeVideo.descriptionSegments;
    return segments
        .map((VideoDescriptionSegment segment) {
          if (segment.isLink) {
            return TextSpan(
              text: segment.text,
              // 外链点击识别器先展示风险确认，不会直接把用户带离应用。
              recognizer: _descriptionLinkRecognizer(segment),
              style: baseStyle.copyWith(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: Theme.of(context).colorScheme.primary,
              ),
            );
          }
          if (!segment.isMention) {
            return TextSpan(text: segment.text);
          }
          return TextSpan(
            text: segment.text,
            // UP 提及点击识别器让 @ 文本像普通文字一样参与换行，并保持可点击。
            recognizer: _descriptionMentionRecognizer(segment),
            style: baseStyle.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        })
        .toList(growable: false);
  }

  /// 为一个 @UP 片段复用稳定的点击识别器，避免每次重建富文本都泄漏手势对象。
  TapGestureRecognizer _descriptionMentionRecognizer(
    VideoDescriptionSegment segment,
  ) {
    final String key = '${segment.mentionedMid}:${segment.text}';
    final TapGestureRecognizer recognizer = _descriptionMentionRecognizers
        .putIfAbsent(key, TapGestureRecognizer.new);
    recognizer.onTap = () => unawaited(_openDescriptionMention(segment));
    return recognizer;
  }

  /// 为一个外链片段复用稳定的点击识别器，保留原有的安全确认流程。
  TapGestureRecognizer _descriptionLinkRecognizer(
    VideoDescriptionSegment segment,
  ) {
    final String key = '${segment.linkUri}:${segment.text}';
    final TapGestureRecognizer recognizer = _descriptionLinkRecognizers
        .putIfAbsent(key, TapGestureRecognizer.new);
    recognizer.onTap = () => unawaited(_confirmAndOpenDescriptionLink(segment));
    return recognizer;
  }

  /// 释放简介富文本持有的手势识别器，避免播放器退出后仍保留点击回调。
  void _disposeDescriptionRecognizers() {
    for (final TapGestureRecognizer recognizer
        in _descriptionMentionRecognizers.values) {
      recognizer.dispose();
    }
    for (final TapGestureRecognizer recognizer
        in _descriptionLinkRecognizers.values) {
      recognizer.dispose();
    }
    _descriptionMentionRecognizers.clear();
    _descriptionLinkRecognizers.clear();
  }

  /// 打开简介中被提及 UP 主的公开主页，昵称只作为加载前的占位标题。
  Future<void> _openDescriptionMention(VideoDescriptionSegment segment) async {
    final int? mid = segment.mentionedMid;
    if (mid == null || mid <= 0) {
      return;
    }
    final bool shouldResume = _playing;
    if (shouldResume) {
      await _playbackService.pause();
    }
    if (!mounted) {
      return;
    }
    await _showStandardSystemUiForNestedRoute();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // 用户主页构建函数把 @ 文本去掉后作为初始昵称，随后由公开接口校正。
        builder: (BuildContext context) => UserProfilePage(
          mid: mid,
          initialName: segment.text.replaceFirst('@', '').trim(),
          publicContentService: _publicContentService,
          videoService: _bilibiliService,
          learningListService: _learningListService,
          watchHistoryService: _watchHistoryService,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    _resumePlayerSystemUiAfterNestedRoute();
    await _restorePlaybackAfterNestedPlayer(shouldResume: shouldResume);
    if (mounted && shouldResume && !_playing) {
      await _playbackService.play();
    }
  }

  /// 展示明确的离开应用风险说明，用户确认后才调用可注入的系统浏览器启动器。
  Future<void> _confirmAndOpenDescriptionLink(
    VideoDescriptionSegment segment,
  ) async {
    final Uri? uri = segment.linkUri;
    if (uri == null || !segment.isLink) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('即将打开外部链接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('外部网站的内容和安全性不由焦点哔哩控制，请确认链接可信后再继续。'),
            const SizedBox(height: 12),
            SelectableText(
              uri.toString(),
              key: const Key('external-link-risk-uri'),
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.primary,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('cancel-external-link'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-external-link'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续访问'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    bool opened = false;
    try {
      opened = await (widget.externalLinkLauncher ?? launchExternalLink)(uri);
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开默认浏览器，请稍后重试。')));
    }
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
      final double target = (currentIndex * 340.0)
          .clamp(0, position.maxScrollExtent)
          .toDouble();
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
    final bool adding = _addingLearningBvid == entry.bvid;
    final WatchHistoryEntry? watchHistory = _watchHistoryByBvid[entry.bvid];
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: current
          ? colors.primaryContainer.withValues(alpha: 0.32)
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
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  key: Key('add-learning-player-collection-${entry.bvid}'),
                  visualDensity: VisualDensity.compact,
                  // 合集预览加入函数查询对应完整视频并自动继承该视频观看进度。
                  onPressed: adding
                      ? null
                      : () =>
                            unawaited(_addCollectionVideoToLearningList(entry)),
                  icon: adding
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.playlist_add_rounded, size: 20),
                  tooltip: '加入学习清单',
                ),
              ),
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
            scrollCacheExtent: const ScrollCacheExtent.pixels(680),
            key: const Key('collection-preview-list'),
            controller: _collectionPreviewScrollController,
            scrollDirection: Axis.horizontal,
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
      partPageNumber: _findVideoNotePart(_notePartCid).pageNumber,
      createdAt: _editingVideoNote?.createdAt,
      includeFrame: _includeCurrentFrame,
      framePath: _noteFramePath,
      saving: _noteSaving,
      onIncludeFrameChanged: _setIncludeCurrentFrame,
      // 保存函数自动写入记录时间、视频时间点和用户选择的当前画面。
      onSave: () => unawaited(_saveVideoNote()),
      // 标题和正文变化函数安排去抖自动保存，避免每次按键都立即写本机存储。
      onTitleChanged: _handleVideoNoteDraftChanged,
      onBodyChanged: _handleVideoNoteDraftChanged,
      onNew: _startNewVideoNote,
      onClose: _closeVideoNotes,
      // 跳转函数只在用户点击独立按钮后才改变视频分P和时间点。
      onJumpToPosition: _editingVideoNote == null
          ? null
          : () => unawaited(_jumpToSelectedVideoNotePosition()),
      onDelete: _editingVideoNote == null
          ? null
          : () => unawaited(_deleteEditingVideoNote()),
      compact: compact,
      borderless: true,
    );
  }

  /// 创建竖屏笔记顶部的横向时间点列表，点按后只切换编辑内容。
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
                // 竖屏笔记卡点击函数只载入笔记，跳转需要用户使用编辑器按钮确认。
                onTap: () => _selectVideoNote(note),
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
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              formatVideoNotePosition(note.position),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'P${note.partPageNumber}',
                            key: Key('portrait-video-note-part-${note.id}'),
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ],
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
        child: Padding(padding: EdgeInsets.all(12), child: Text('暂无笔记')),
      );
    }
    return ListView.separated(
      key: const Key('fullscreen-video-note-list'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      itemCount: _currentVideoNotes.length,
      // 分隔函数给全屏笔记时间线保留紧凑间距。
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 6),
      // 构建函数显示可自动滚动的标题和视频时间点，点击只切换编辑内容。
      itemBuilder: (BuildContext context, int index) {
        final VideoNote note = _currentVideoNotes[index];
        final bool selected = note.id == _editingVideoNote?.id;
        final ColorScheme colors = Theme.of(context).colorScheme;
        return Material(
          color: selected
              ? colors.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            key: Key('fullscreen-video-note-${note.id}'),
            borderRadius: BorderRadius.circular(9),
            // 全屏笔记点击函数只载入标题、正文和画面，跳转由单独按钮执行。
            onTap: () => _selectVideoNote(note),
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
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: selected
                                ? colors.primary.withValues(alpha: 0.22)
                                : colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              'P${note.partPageNumber} ${formatVideoNotePosition(note.position)}',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ),
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

  /// 创建约占播放器三分之二宽度的笔记本，保留左侧视频画面供边看边记。
  Widget _buildFullscreenVideoNotesPanel(double playerWidth) {
    final double panelWidth = playerWidth * 0.64;
    final double expandedListWidth = playerWidth * 0.17;
    return Positioned(
      key: const Key('fullscreen-video-notes-panel'),
      top: 10,
      right: 10,
      bottom: 10,
      width: panelWidth,
      child: AnimatedSlide(
        key: const Key('fullscreen-video-notes-slide'),
        offset: _notesOpen ? Offset.zero : const Offset(1.08, 0),
        duration: _notesPanelAnimationDuration,
        curve: _notesOpen ? Curves.easeOutCubic : Curves.easeInCubic,
        child: Material(
          key: const Key('fullscreen-video-notes-material'),
          elevation: 18,
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
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
                  width: _fullscreenNoteListCollapsed ? 46 : expandedListWidth,
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
                                  style: Theme.of(context).textTheme.titleSmall
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
          color: Colors.black.withValues(alpha: 0.58),
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
              Expanded(
                child: Text(
                  '简介',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _buildCurrentVideoLearningListButton(),
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

  /// 创建固定在视频画面内的分段进度条，控制栏隐藏后仍保持可见并支持点击跳转。
  Widget _buildChapterProgressOverlay({required bool inPictureInPicture}) {
    if (inPictureInPicture ||
        _playerEnhancementController.chapters.isEmpty ||
        !_playerEnhancementController.chapterProgressVisible) {
      return const SizedBox.shrink();
    }
    final bool aboveControls = _showControls && !_controlsLocked;
    final double fullscreenSafeBottom = _fullscreen
        ? MediaQuery.paddingOf(context).bottom
        : 0;
    final double horizontalInset = _fullscreen && aboveControls ? 12 : 0;
    final double bottom = (aboveControls ? 54 : 4) + fullscreenSafeBottom;
    return Positioned(
      left: horizontalInset,
      right: horizontalInset,
      bottom: bottom,
      child: VideoChapterStrip(
        chapters: _playerEnhancementController.chapters,
        position: _playbackSnapshot.position,
        compact: true,
        onDarkSurface: true,
        // 画面内章节条点击函数统一跳转到对应章节的开始位置。
        onSeek: (Duration position) {
          unawaited(_seekToChapter(position));
        },
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

  /// 创建横屏平板播放器工作台，左侧稳定播放、右侧显示详情、笔记或分P。
  Widget _buildWorkspacePlayerBody({required Widget player}) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double sidebarWidth = (constraints.maxWidth * 0.32)
            .clamp(
              AdaptiveLayout.playerSidebarMinWidth,
              AdaptiveLayout.playerSidebarMaxWidth,
            )
            .toDouble();
        final Widget sideContent;
        if (_notesOpen) {
          sideContent = _buildPortraitVideoNotesPanel();
        } else if (_partSelectorExpanded) {
          sideContent = _buildExpandedPartSelector();
        } else {
          sideContent = SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: _buildNonFullscreenDetails(),
          );
        }
        return Row(
          key: const Key('player-workspace-layout'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: ColoredBox(
                key: const Key('player-workspace-video'),
                color: Colors.black,
                // 左侧播放器填满工作区；真实视频比例由用户选择的画幅模式在 Texture 层处理。
                child: player,
              ),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              key: const Key('player-workspace-side-pane'),
              width: sidebarWidth,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: sideContent,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 创建只覆盖视频画面的手势层，确保控制栏按钮不必等待双击识别结果。
  Widget _buildPlayerSurface({
    required BuildContext context,
    required BoxConstraints constraints,
    required bool enableSurfaceGestures,
    required bool enableVerticalAdjustment,
  }) {
    return GestureDetector(
      key: const Key('player-surface'),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      // 画面单击函数只切换控制层，避免误触导致视频暂停。
      onTap: enableSurfaceGestures ? _toggleControls : null,
      // 双击落点记录函数为分区快进快退提供位置信息。
      onDoubleTapDown: enableSurfaceGestures ? _recordDoubleTapPosition : null,
      // 双击处理函数依据画面宽度计算左中右分区。
      onDoubleTap: enableSurfaceGestures
          ? () => _handleDoubleTap(constraints.maxWidth)
          : null,
      // 长按开始函数仅临时切换到三倍速，横向快进由独立拖动手势负责。
      onLongPressStart: enableSurfaceGestures
          ? _startTemporaryTripleSpeed
          : null,
      // 长按结束函数恢复原倍速，不改变播放位置。
      onLongPressEnd: enableSurfaceGestures ? _stopTemporaryTripleSpeed : null,
      // 长按取消函数恢复界面状态且不提交未确认的进度。
      onLongPressCancel: enableSurfaceGestures
          ? _cancelTemporaryLongPress
          : null,
      // 横向拖动开始函数立即进入进度预览，并计算当前视频对应的拖动速度。
      onHorizontalDragStart: enableSurfaceGestures
          ? (DragStartDetails details) => _startHorizontalScrub(
              details,
              constraints.biggest,
              MediaQuery.viewPaddingOf(context),
            )
          : null,
      // 横向拖动更新函数只刷新预览，避免频繁向原生播放器发送跳转命令。
      onHorizontalDragUpdate: enableSurfaceGestures
          ? _updateHorizontalScrub
          : null,
      // 横向拖动结束函数一次性提交最终目标位置。
      onHorizontalDragEnd: enableSurfaceGestures
          ? _finishHorizontalScrub
          : null,
      // 横向拖动取消函数恢复开始位置，避免系统手势造成误跳转。
      onHorizontalDragCancel: enableSurfaceGestures
          ? _cancelHorizontalScrub
          : null,
      // 竖向手势开始函数在全屏和平板工作台判断左侧亮度、右侧音量及上下安全区。
      onVerticalDragStart: enableVerticalAdjustment && enableSurfaceGestures
          ? (DragStartDetails details) => _startVerticalAdjustment(
              details,
              constraints.biggest,
              MediaQuery.of(context).viewPadding.top,
              MediaQuery.of(context).viewPadding.bottom,
            )
          : null,
      // 竖向手势更新函数实时调整窗口亮度或媒体音量。
      onVerticalDragUpdate: enableVerticalAdjustment && enableSurfaceGestures
          ? (DragUpdateDetails details) =>
                _updateVerticalAdjustment(details, constraints.maxHeight)
          : null,
      // 竖向手势结束函数恢复控制栏自动隐藏计时。
      onVerticalDragEnd: enableVerticalAdjustment && enableSurfaceGestures
          ? _finishVerticalAdjustment
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _buildVideoOutput(),
          _buildDanmakuOverlay(),
          _buildSubtitleOverlay(),
        ],
      ),
    );
  }

  /// 创建播放器画面、手势、可点击错误重试层、控制层以及非全屏时的视频信息区域。
  @override
  Widget build(BuildContext context) {
    final bool inPictureInPicture = _playbackSnapshot.isInPictureInPicture;
    // 错误或选集展开时关闭画面手势，避免画面层干扰重试与选集按钮点击。
    final bool enableSurfaceGestures =
        _playbackSnapshot.phase != PlaybackPhase.error &&
        !_partSelectorExpanded &&
        !_controlsLocked;
    final Widget player = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool workspacePlayer =
            !_fullscreen &&
            AdaptiveLayout.usesWorkspace(MediaQuery.sizeOf(context));
        final bool showPlayerStatus = _fullscreen || workspacePlayer;
        _schedulePlayerStatusVisibility(showPlayerStatus);
        return Listener(
          // 指针被系统取消时优先撤销预览，避免取消事件被拖动识别器当作普通松手。
          onPointerCancel: _handlePlayerPointerCancel,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildPlayerSurface(
                  context: context,
                  constraints: constraints,
                  enableSurfaceGestures: enableSurfaceGestures,
                  enableVerticalAdjustment: showPlayerStatus,
                ),
                if (_temporarySpeedActive)
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
                              '三倍速中>>',
                              key: Key('temporary-triple-speed'),
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                _buildSeekFeedback(),
                _buildPlaybackCompletionPrompt(),
                _buildInteractiveVideoPrompt(),
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
                  top: showPlayerStatus ? 72 : 52,
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
                            color: Colors.black.withValues(alpha: 0.82),
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
                  opacity:
                      _showControls && !_controlsLocked && !inPictureInPicture
                      ? 1
                      : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring:
                        !_showControls || _controlsLocked || inPictureInPicture,
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        // 渐变层只负责绘制，不能拦截画面空白处的单击、双击和拖动。
                        const IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
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
                          ),
                        ),
                        Stack(
                          children: <Widget>[
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              height: showPlayerStatus ? 62 : 44,
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
                                    if (showPlayerStatus)
                                      _FullscreenDeviceStatus(
                                        focusController:
                                            widget.focusTimerController ??
                                            FocusTimerScope.maybeOf(context),
                                        currentBvid: _activeVideo.bvid,
                                        currentPartCid: _currentPart.cid,
                                        partRemainingDuration:
                                            _currentPartPlaybackRemaining(),
                                        clock: _playerClock,
                                        batteryPercent: _batteryPercent,
                                        networkTypeLabel: _networkType.label,
                                      ),
                                    Expanded(
                                      child: Row(
                                        children: <Widget>[
                                          PlayerCompactIconButton(
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
                                          if (_boundFocusController != null)
                                            PlayerCompactIconButton(
                                              key: const Key(
                                                'player-focus-button',
                                              ),
                                              // 专注按钮函数打开播放器内开始、暂停、续时和结束面板。
                                              onPressed: () => unawaited(
                                                _openPlayerFocusSheet(),
                                              ),
                                              icon:
                                                  _observedFocusStatus ==
                                                      FocusSessionStatus.paused
                                                  ? Icons.pause_circle_outline
                                                  : _observedFocusSessionId ==
                                                        null
                                                  ? Icons.timer_outlined
                                                  : Icons.timer_rounded,
                                              tooltip:
                                                  _observedFocusSessionId ==
                                                      null
                                                  ? '开始专注'
                                                  : '管理专注',
                                            ),
                                          if (_playerEnhancementController
                                              .chapters
                                              .isNotEmpty)
                                            PlayerCompactIconButton(
                                              key: const Key(
                                                'video-chapter-button',
                                              ),
                                              // 分段按钮函数直接打开章节面板，不再藏在更多选项中。
                                              onPressed: () => unawaited(
                                                _showVideoChapterPanel(),
                                              ),
                                              icon:
                                                  Icons.view_timeline_outlined,
                                              tooltip: '分段信息',
                                            ),
                                          PlayerCompactIconButton(
                                            key: const Key(
                                              'picture-in-picture',
                                            ),
                                            // 画中画按钮函数调用 Android 原生小窗能力。
                                            onPressed: () => unawaited(
                                              _enterPictureInPicture(),
                                            ),
                                            icon: Icons
                                                .picture_in_picture_alt_rounded,
                                            tooltip: '画中画',
                                          ),
                                          PlayerCompactIconButton(
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
                                            child: PopupMenuButton<_PlayerMoreMenuAction>(
                                              key: const Key(
                                                'more-settings-menu',
                                              ),
                                              tooltip: '更多选项',
                                              padding: EdgeInsets.zero,
                                              // 菜单使用短动画，避免点击控制项后仍感觉慢半拍。
                                              popUpAnimationStyle:
                                                  _playerPopupMenuAnimationStyle,
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
                                bottom: _fullscreen,
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
                                          PlayerCompactIconButton(
                                            key: const Key('play-pause-button'),
                                            // 左下角播放按钮函数向原生播放器发送播放或暂停命令。
                                            onPressed: _togglePlayback,
                                            icon: _playing
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            tooltip: _playing ? '暂停' : '播放',
                                          ),
                                          if (_activeVideo.parts.length >
                                              1) ...<Widget>[
                                            PlayerCompactIconButton(
                                              key: const Key(
                                                'previous-part-button',
                                              ),
                                              // 上一集函数切换到当前分P之前的一集。
                                              onPressed: _currentPartIndex > 0
                                                  ? _playPreviousPart
                                                  : () {},
                                              icon: Icons.skip_previous_rounded,
                                              tooltip: '上一集',
                                            ),
                                            PlayerCompactIconButton(
                                              key: const Key(
                                                'next-part-button',
                                              ),
                                              // 下一集函数切换到当前分P之后的一集。
                                              onPressed:
                                                  _currentPartIndex >= 0 &&
                                                      _currentPartIndex <
                                                          _activeVideo
                                                                  .parts
                                                                  .length -
                                                              1
                                                  ? _playNextPart
                                                  : () {},
                                              icon: Icons.skip_next_rounded,
                                              tooltip: '下一集',
                                            ),
                                          ],
                                          const SizedBox(width: 2),
                                          Text(
                                            _formatProgress(),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                            ),
                                          ),
                                          const Spacer(),
                                          if (_fullscreen &&
                                              _activeVideo.parts.length > 1)
                                            PlayerPartSelectorButton(
                                              key: const Key(
                                                'part-selector-button',
                                              ),
                                              // 选集按钮函数只在横屏显示右侧双列面板。
                                              onPressed: _openPartSelector,
                                            ),
                                          SizedBox(
                                            height: 34,
                                            child: PopupMenuButton<int>(
                                              key: const Key('quality-menu'),
                                              initialValue: _currentQuality,
                                              tooltip: '清晰度',
                                              padding: EdgeInsets.zero,
                                              // 菜单使用短动画，避免点击控制项后仍感觉慢半拍。
                                              popUpAnimationStyle:
                                                  _playerPopupMenuAnimationStyle,
                                              // 清晰度菜单选择函数保留进度后重新请求播放源。
                                              onSelected: (int quality) =>
                                                  unawaited(
                                                    _changeQuality(quality),
                                                  ),
                                              // 清晰度菜单构建函数使用原生接口实际返回的档位。
                                              itemBuilder: (BuildContext context) {
                                                return _availableQualities
                                                    .map(
                                                      (
                                                        PlaybackQuality quality,
                                                      ) => PopupMenuItem<int>(
                                                        key: Key(
                                                          'quality-${quality.id}',
                                                        ),
                                                        value: quality.id,
                                                        child: Text(
                                                          quality.label,
                                                        ),
                                                      ),
                                                    )
                                                    .toList(growable: false);
                                              },
                                              child: PlayerControlLabel(
                                                text: _currentQualityLabel(),
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
                                              // 菜单使用短动画，避免点击控制项后仍感觉慢半拍。
                                              popUpAnimationStyle:
                                                  _playerPopupMenuAnimationStyle,
                                              // 倍速菜单选择函数把用户选择交给原生播放器。
                                              onSelected: (double speed) =>
                                                  unawaited(
                                                    _changePlaybackSpeed(speed),
                                                  ),
                                              // 倍速菜单构建函数生成包含三倍速的六档速度。
                                              itemBuilder:
                                                  (BuildContext context) {
                                                    return _playbackSpeeds
                                                        .map(
                                                          (double speed) =>
                                                              PopupMenuItem<
                                                                double
                                                              >(
                                                                key: Key(
                                                                  'speed-$speed',
                                                                ),
                                                                value: speed,
                                                                child: Text(
                                                                  _formatSpeed(
                                                                    speed,
                                                                  ),
                                                                ),
                                                              ),
                                                        )
                                                        .toList(
                                                          growable: false,
                                                        );
                                                  },
                                              child: PlayerControlLabel(
                                                text: _formatSpeed(
                                                  _playbackSpeed,
                                                ),
                                              ),
                                            ),
                                          ),
                                          PlayerCompactIconButton(
                                            // 全屏按钮函数切换横屏沉浸状态。
                                            onPressed: () =>
                                                unawaited(_toggleFullscreen()),
                                            icon: _fullscreen
                                                ? Icons.fullscreen_exit_rounded
                                                : Icons.fullscreen_rounded,
                                            tooltip: _fullscreen
                                                ? '退出全屏'
                                                : '进入全屏',
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
                      ],
                    ),
                  ),
                ),
                _buildChapterProgressOverlay(
                  inPictureInPicture: inPictureInPicture,
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
                    !inPictureInPicture &&
                    (_controlsLocked || _showControls))
                  Positioned(
                    key: const Key('fullscreen-controls-lock'),
                    left: 8,
                    top: constraints.maxHeight / 2 - 22,
                    child: SafeArea(
                      right: false,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: IconButton(
                          // 锁定按钮函数隐藏或恢复其他播放器按钮和画面手势。
                          onPressed: _toggleControlsLock,
                          icon: Icon(
                            _controlsLocked
                                ? Icons.lock_rounded
                                : Icons.lock_open_rounded,
                            color: Colors.white,
                          ),
                          tooltip: _controlsLocked ? '解锁播放器' : '锁定播放器',
                        ),
                      ),
                    ),
                  ),
                if (_fullscreen &&
                    !_notesOpen &&
                    !_partSelectorExpanded &&
                    _showControls &&
                    !_controlsLocked &&
                    !inPictureInPicture)
                  _buildFullscreenVideoNoteButton(),
                if (_fullscreen && _notesOverlayMounted)
                  _buildFullscreenVideoNotesPanel(constraints.maxWidth),
                // 错误重试层放在控制栏之后，确保按钮不会被全屏控制栏的透明区域拦截点击。
                _buildPlaybackHint(),
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
    final bool landscapeLayout = screenSize.width > screenSize.height;
    _schedulePlayerSystemUiSync(landscapeLayout: landscapeLayout);
    final bool workspaceLayout =
        !fullscreenLayout && AdaptiveLayout.usesWorkspace(screenSize);
    final double playerHeight = fullscreenLayout
        ? screenSize.height
        : (screenSize.width / aspectRatio)
              .clamp(180, screenSize.height * 0.62)
              .toDouble();
    final Widget pageBody;
    if (fullscreenLayout) {
      pageBody = SizedBox.expand(child: player);
    } else if (workspaceLayout) {
      pageBody = _buildWorkspacePlayerBody(player: player);
    } else if (_notesOpen) {
      pageBody = Column(
        children: <Widget>[
          SizedBox(width: double.infinity, height: playerHeight, child: player),
          Expanded(child: _buildPortraitVideoNotesPanel()),
        ],
      );
    } else if (_partSelectorExpanded) {
      pageBody = Column(
        children: <Widget>[
          SizedBox(width: double.infinity, height: playerHeight, child: player),
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
        top: !fullscreenLayout && !landscapeLayout,
        left: !fullscreenLayout,
        right: !fullscreenLayout,
        bottom: false,
        child: pageBody,
      ),
    );
    return PopScope(
      canPop: _allowRoutePop,
      // 系统返回函数保证先退出全屏或返回上一支合集视频，再离开页面。
      onPopInvokedWithResult: _handlePopInvoked,
      child: pageScaffold,
    );
  }
}
