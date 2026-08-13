part of 'player_page.dart';

/// 封装字幕轨道、弹幕片段、弹幕配置持久化和播放画面文字叠加层。
mixin _PlayerOverlayCoordinator
    on
        State<PlayerPage>,
        _PlayerPlaybackSession,
        _PlayerGestureCoordinator,
        _PlayerViewportCoordinator {
  static const String _subtitleOffValue = '__focubili_subtitle_off__';
  static const Duration _danmakuNextSegmentPreloadThreshold = Duration(
    seconds: 30,
  );
  static const int _maximumCachedDanmakuSegments = 3;
  static const int _maximumDanmakuSegmentRetries = 3;

  DanmakuPreferences _danmakuPreferences = DanmakuPreferences();
  bool _danmakuPreferencesChangedByUser = false;
  bool _danmakuPersistenceWarningShown = false;
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
  late final PlayerOverlayService _playerOverlayService;
  late final DanmakuPreferencesService _danmakuPreferencesService;

  /// 返回配置中的弹幕开关，统一播放会话和持久化模型之间的状态来源。
  @override
  bool get _danmakuEnabled => _danmakuPreferences.enabled;

  /// 创建弹幕帧时钟和平台叠加数据服务，供播放器 initState 统一调用。
  void _initializePlayerOverlayCoordinator({required TickerProvider vsync}) {
    _danmakuFrameController = AnimationController(
      vsync: vsync,
      duration: const Duration(hours: 1),
    );
    _playerOverlayService =
        widget.playerOverlayService ?? createDefaultPlayerOverlayService();
    _danmakuPreferencesService =
        widget.danmakuPreferencesService ?? DanmakuPreferencesService();
  }

  /// 释放弹幕帧时钟，供播放器 dispose 统一调用。
  void _disposePlayerOverlayCoordinator() {
    _danmakuFrameController.dispose();
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
  @override
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
  @override
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
  @override
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
  @override
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
                  // 轨道选择函数只返回不敏感编号，真正字幕地址始终保留在平台服务内存。
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
              required Key sliderKey,
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
                    key: sliderKey,
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    // 禁止轻点轨道直接跳值；只有明确水平拖动才调节，竖滑优先交给面板滚动。
                    allowedInteraction: SliderInteraction.slideOnly,
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
                        sliderKey: const Key('danmaku-opacity-slider'),
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
                        sliderKey: const Key('danmaku-display-area-slider'),
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
                        sliderKey: const Key('danmaku-font-size-slider'),
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
                        sliderKey: const Key('danmaku-lane-count-slider'),
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
                        sliderKey: const Key('danmaku-scroll-duration-slider'),
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
                        sliderKey: const Key('danmaku-stroke-width-slider'),
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
                      TextFormField(
                        key: const Key('danmaku-blocked-keywords'),
                        // 让输入框 State 自己管理控制器，弹层退场动画结束后再随组件一起安全释放。
                        initialValue: value.blockedKeywords.join('，'),
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
  }
}
