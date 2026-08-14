import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

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
import '../../platform/app_platform.dart';
import '../../models/video_preview.dart';
import '../../models/player_enhancement.dart';
import '../../models/video_shot_preview.dart';
import '../../models/watch_history_entry.dart';
import '../../models/learning_list_entry.dart';
import '../../services/device_status_service.dart';
import '../../services/external_link_service.dart';
import '../../services/native_playback_service.dart';
import '../../services/playback_service_factory.dart';
import '../../services/playback_video_surface.dart';
import '../../services/player_overlay_service.dart';
import '../../services/player_overlay_service_factory.dart';
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
import 'playback_resume_plan.dart';
import 'widgets/player_control_widgets.dart';

part 'player_collection_sheet.dart';
part 'player_layout_widgets.dart';
part 'player_danmaku_rendering.dart';
part 'player_playback_session.dart';
part 'player_learning_coordinator.dart';
part 'player_focus_coordinator.dart';
part 'player_gesture_coordinator.dart';
part 'player_notes_workspace.dart';
part 'player_viewport_coordinator.dart';
part 'player_overlay_coordinator.dart';
part 'player_controls_coordinator.dart';
part 'player_video_coordinator.dart';
part 'player_controls_view.dart';
part 'player_feedback_view.dart';
part 'player_details_view.dart';
part 'player_collection_view.dart';
part 'player_page_view.dart';

/// 标识播放器画面应保留比例、裁切填充，还是按容器比例拉伸。
enum _VideoFitMode { contain, cover, stretch }

/// 标识播放器右上角“更多”菜单中可执行的本地播放器设置。
enum _PlayerMoreMenuAction {
  subtitles,
  danmakuSettings,
  playbackLoop,
  sleepTimer,
  fitContain,
  fitCover,
  fitStretch,
}

/// 标识合集展开列表的四种本地排序方式，不改变服务端原始合集顺序。
enum _CollectionEntryOrder { original, newest, oldest, mostPlayed }

/// 标识播放器首次跳转来自笔记还是专注记录，以显示准确提示文案。
enum PlayerInitialPositionSource { note, focus, learning, externalLink }

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
    this.appPlatform,
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
  final AppPlatform? appPlatform;
  final int? initialPartCid;
  final Duration? initialPosition;
  final PlayerInitialPositionSource initialPositionSource;

  /// 创建播放器状态，保存播放、进度、控制层和全屏状态。
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 管理原生视频纹理、播放状态、手势、控制层和系统全屏状态。
class _PlayerPageState extends State<PlayerPage>
    with
        SingleTickerProviderStateMixin,
        WidgetsBindingObserver,
        _PlayerPlaybackSession,
        _PlayerLearningCoordinator,
        _PlayerFocusCoordinator,
        _PlayerGestureCoordinator,
        _PlayerNotesWorkspace,
        _PlayerViewportCoordinator,
        _PlayerOverlayCoordinator,
        _PlayerControlsCoordinator,
        _PlayerVideoCoordinator {
  @override
  late final PlaybackService _playbackService;
  @override
  late final WatchHistoryService _watchHistoryService;
  @override
  late final LearningListService _learningListService;
  @override
  late final DeviceStatusService _deviceStatusService;
  @override
  late final AppPlatform _appPlatform;
  @override
  late final BilibiliService _bilibiliService;
  @override
  late final BilibiliPublicContentService _publicContentService;
  @override
  late final VideoShotService _videoShotService;
  @override
  late final VideoNoteService _videoNoteService;
  @override
  late final ProblemDiagnosticsService _problemDiagnosticsService;
  @override
  late VideoPreview _activeVideo;
  @override
  late VideoPart _currentPart;
  @override
  final List<VideoPreview> _collectionVideoBackStack = <VideoPreview>[];
  @override
  final ScrollController _partScrollController = ScrollController();
  @override
  final ScrollController _collectionPreviewScrollController =
      ScrollController();
  final Map<String, TapGestureRecognizer> _descriptionMentionRecognizers =
      <String, TapGestureRecognizer>{};
  final Map<String, TapGestureRecognizer> _descriptionLinkRecognizers =
      <String, TapGestureRecognizer>{};
  @override
  bool _showControls = true;
  @override
  bool _isDraggingProgress = false;
  @override
  double _progress = 0;
  @override
  Timer? _controlsTimer;
  @override
  Timer? _interactivePromptTimer;
  @override
  Timer? _playerNoticeTimer;
  @override
  Timer? _playerStatusTimer;
  @override
  Timer? _sleepTimer;
  @override
  double _playbackSpeed = 1;
  @override
  String? _playerNotice;
  @override
  bool _playbackLoopEnabled = false;
  @override
  DateTime? _sleepTimerDeadline;
  @override
  int? _pauseAfterPlayCount;
  @override
  int _completedPlayCount = 0;
  @override
  bool _loopRestartInFlight = false;
  @override
  bool _partSelectorExpanded = false;
  @override
  bool _partsAscending = true;
  @override
  _VideoFitMode _videoFitMode = _VideoFitMode.contain;
  @override
  bool _descriptionExpanded = false;
  @override
  String? _openingCollectionBvid;
  @override
  bool _interactiveChoiceOpening = false;
  @override
  DateTime _playerClock = DateTime.now();
  @override
  int? _batteryPercent;
  @override
  DeviceNetworkType _networkType = DeviceNetworkType.other;
  @override
  bool _playerStatusSyncScheduled = false;
  @override
  bool _pendingPlayerStatusVisible = false;
  @override
  String? _locatedCollectionPreviewBvid;
  @override
  late final PlaybackPreferencesService _playbackPreferencesService;
  @override
  late final PlayerEnhancementController _playerEnhancementController;
  @override
  PlaybackPreferences _playbackPreferences = const PlaybackPreferences();

  /// 判断原生播放器是否真的在播放，避免 Flutter 页面自己伪造播放状态。
  @override
  bool get _playing => _playbackSnapshot.isPlaying;

  /// 优先使用原生播放器返回的真实总时长，加载前暂以视频卡片时长保持界面稳定。
  @override
  Duration get _displayDuration {
    return _playbackSnapshot.duration > Duration.zero
        ? _playbackSnapshot.duration
        : _currentPart.duration;
  }

  /// 切换简介的展开状态，供详情视图扩展通过合法的 State 成员刷新界面。
  void _toggleDescriptionExpanded() {
    setState(() {
      _descriptionExpanded = !_descriptionExpanded;
    });
  }

  /// 一次性写入播放会话恢复结果，使初始化状态在同一帧内对界面生效。
  @override
  void _applyInitialPlaybackConfiguration({
    required VideoPart part,
    required SystemPlaybackLevels levels,
    required DeviceNetworkType networkType,
    required int preferredQuality,
  }) {
    setState(() {
      _currentPart = part;
      _brightness = levels.brightness;
      _volume = levels.volume;
      _networkType = networkType;
      _currentQuality = preferredQuality;
      _preferredOpeningQuality = preferredQuality;
      _defaultQualityPending = true;
    });
  }

  /// 创建播放服务、订阅原生状态，并启动视频纹理和播放数据请求。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePlayerOverlayCoordinator(vsync: this);
    _activeVideo = widget.video;
    _currentPart = _activeVideo.initialPart;
    _notePartCid = _currentPart.cid;
    _playbackService = widget.playbackService ?? createDefaultPlaybackService();
    _watchHistoryService = widget.watchHistoryService ?? WatchHistoryService();
    _learningListService = widget.learningListService ?? LearningListService();
    _deviceStatusService =
        widget.deviceStatusService ?? const NativeDeviceStatusService();
    _bilibiliService = widget.bilibiliService ?? BilibiliVideoInfoService();
    _publicContentService =
        widget.publicContentService ?? BilibiliHttpPublicContentService();
    _videoShotService =
        widget.videoShotService ??
        (widget.playbackService == null
            ? BilibiliVideoShotService()
            : const EmptyVideoShotService());
    _videoNoteService = widget.videoNoteService ?? VideoNoteService();
    _appPlatform = widget.appPlatform ?? AppPlatformDetector.current;
    _problemDiagnosticsService = ProblemDiagnosticsService();
    _playbackPreferencesService =
        widget.playbackPreferencesService ?? const PlaybackPreferencesService();
    _playerEnhancementController = PlayerEnhancementController(
      service:
          widget.playerEnhancementService ??
          (widget.playbackService == null
              ? BilibiliPublicPlayerEnhancementService()
              : const EmptyPlayerEnhancementService()),
    )..addListener(_handlePlayerEnhancementChanged);
    _startPlayerPlaybackSession(widget.initialPosition);
    unawaited(_loadWatchHistoryBadges());
    unawaited(_loadCurrentLearningListEntry());
    unawaited(_loadDanmakuPreferences());
    if (widget.playbackService == null) {
      unawaited(_allowPlayerOrientations());
    }
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

  /// 读取当前电量；替换了原生播放器却未提供设备服务时直接返回未知，避免调用不存在的平台通道。
  @override
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

  /// 离开页面前取消重试状态、订阅和计时器，释放原生资源并恢复竖屏与系统栏。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushCurrentWatchHistoryProgress();
    _flushCurrentLearningListProgress();
    _disposePlayerControlsCoordinator();
    _disposePlayerVideoCoordinator();
    _disposePlayerPlaybackSession();
    _disposePlayerFocusCoordinator();
    _disposePlayerGestureCoordinator();
    _disposePlayerNotesWorkspace();
    _disposePlayerOverlayCoordinator();
    _disposeDescriptionRecognizers();
    unawaited(_playbackService.dispose());
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildPlayerPage(context);
}
