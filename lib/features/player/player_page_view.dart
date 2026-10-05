part of 'player_page.dart';

/// 组合播放器画面、控制层、详情区域和不同窗口尺寸下的页面骨架。
extension _PlayerPageView on _PlayerPageState {
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
    return FullscreenVideoTransform(
      key: ValueKey(
        'video-transform-${_activeVideo.bvid}-${_currentPart.cid}-$_fullscreen',
      ),
      enabled:
          _fullscreen &&
          (_appPlatform == AppPlatform.android ||
              _appPlatform == AppPlatform.ios) &&
          _playbackPreferences.enableTwoFingerVideoTransform &&
          enableSurfaceGestures,
      // A second finger cancels pending single-finger actions without seeking the video.
      onMultiTouchStart: () {
        _cancelHorizontalScrub();
        _cancelTemporaryLongPress();
        _finishVerticalAdjustment(DragEndDetails());
      },
      builder: (context, videoTransform, usingTwoFingers) {
        final gesturesEnabled = enableSurfaceGestures && !usingTwoFingers;
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(gestureSettings: playerTouchGestureSettings),
          child: GestureDetector(
            key: const Key('player-surface'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            // 长按开始函数仅临时切换到三倍速，横向快进由独立拖动手势负责。
            onLongPressStart: gesturesEnabled
                ? _startTemporaryTripleSpeed
                : null,
            // 长按结束函数恢复原倍速，不改变播放位置。
            onLongPressEnd: gesturesEnabled ? _stopTemporaryTripleSpeed : null,
            // 长按取消函数恢复界面状态且不提交未确认的进度。
            onLongPressCancel: gesturesEnabled
                ? _cancelTemporaryLongPress
                : null,
            // 横向拖动开始函数立即进入进度预览，并计算当前视频对应的拖动速度。
            onHorizontalDragStart: gesturesEnabled
                ? (DragStartDetails details) => _startHorizontalScrub(
                    details,
                    constraints.biggest,
                    MediaQuery.viewPaddingOf(context),
                  )
                : null,
            // 横向拖动更新函数只刷新预览，避免频繁向原生播放器发送跳转命令。
            onHorizontalDragUpdate: gesturesEnabled
                ? _updateHorizontalScrub
                : null,
            // 横向拖动结束函数一次性提交最终目标位置。
            onHorizontalDragEnd: gesturesEnabled
                ? _finishHorizontalScrub
                : null,
            // 横向拖动取消函数恢复开始位置，避免系统手势造成误跳转。
            onHorizontalDragCancel: gesturesEnabled
                ? _cancelHorizontalScrub
                : null,
            // 竖向手势开始函数在全屏和平板工作台判断左侧亮度、右侧音量及上下安全区。
            onVerticalDragStart: enableVerticalAdjustment && gesturesEnabled
                ? (DragStartDetails details) => _startVerticalAdjustment(
                    details,
                    constraints.biggest,
                    MediaQuery.of(context).viewPadding.top,
                    MediaQuery.of(context).viewPadding.bottom,
                  )
                : null,
            // 竖向手势更新函数实时调整窗口亮度或媒体音量。
            onVerticalDragUpdate: enableVerticalAdjustment && gesturesEnabled
                ? (DragUpdateDetails details) =>
                      _updateVerticalAdjustment(details, constraints.maxHeight)
                : null,
            // 竖向手势结束函数恢复控制栏自动隐藏计时。
            onVerticalDragEnd: enableVerticalAdjustment && gesturesEnabled
                ? _finishVerticalAdjustment
                : null,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: gesturesEnabled
                  ? {
                      PlayerTapGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                            PlayerTapGestureRecognizer
                          >(
                            () => PlayerTapGestureRecognizer(debugOwner: this),
                            (recognizer) => recognizer
                              ..gestureSettings = playerTouchGestureSettings
                              ..onSingleTap = _toggleControls
                              ..onDoubleTapDown = _recordDoubleTapPosition
                              ..onDoubleTap = () =>
                                  _handleDoubleTap(constraints.biggest),
                          ),
                    }
                  : const {},
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Transform(
                    key: const Key('fullscreen-video-picture-transform'),
                    alignment: Alignment.center,
                    transform: videoTransform,
                    child: _buildVideoOutput(),
                  ),
                  _buildDanmakuOverlay(),
                  if ((_appPlatform.isDesktop ||
                          _appPlatform == AppPlatform.ios) &&
                      _brightness < 1)
                    IgnorePointer(
                      key: const Key('software-brightness-overlay'),
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 1 - _brightness),
                      ),
                    ),
                  if (_playbackSnapshot.isRestoringPosition)
                    const ColoredBox(
                      key: Key('player-resume-position-gate'),
                      color: Colors.black,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 组合播放器与响应式页面，放大控制栏时为窄屏换行保留实际高度。
  Widget _buildPlayerPage(BuildContext context) {
    final controlSize = PlayerControlSize(_playbackPreferences.controlScale);
    final bool inPictureInPicture = _playbackSnapshot.isInPictureInPicture;
    // 错误或选集展开时关闭画面手势，避免画面层干扰重试与选集按钮点击。
    final bool enableSurfaceGestures =
        _playbackSnapshot.phase != PlaybackPhase.error &&
        !_playbackSnapshot.isRestoringPosition &&
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
                // 听视频信息属于画面层，不参与字幕/通知提示列的高度和对齐计算。
                if (_playbackSnapshot.audioOnly &&
                    !inPictureInPicture &&
                    _playbackSnapshot.phase != PlaybackPhase.error &&
                    _playbackSnapshot.phase != PlaybackPhase.loading)
                  IgnorePointer(child: _buildListeningSurface()),
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
                  // 渐变层不能拦截画面手势；提示和控制栏分别管理显示状态。
                  child: const IgnorePointer(
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
                ),
                PlayerFeedbackViewport(
                  controlsVisible:
                      _showControls && !_controlsLocked && !inPictureInPicture,
                  edgeInsets: MediaQuery.paddingOf(context),
                  sideInset: _fullscreen && (_showControls || _controlsLocked)
                      ? 16 + 48 * controlSize.scale
                      : 16,
                  feedback: _buildPlayerFeedback(),
                  topControls: _buildFadingControls(
                    SafeArea(
                      key: const Key('top-player-bar'),
                      top: false,
                      bottom: false,
                      minimum: const EdgeInsets.only(top: 2, left: 2, right: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                              showNetworkType: !_appPlatform.isDesktop,
                            ),
                          _buildTopControlBar(),
                        ],
                      ),
                    ),
                  ),
                  bottomControls: _buildFadingControls(
                    SafeArea(
                      key: const Key('bottom-player-bar'),
                      top: false,
                      bottom: _fullscreen,
                      minimum: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (_showControls &&
                              !_controlsLocked &&
                              !inPictureInPicture)
                            _buildTimelineAnnotations(),
                          PlayerProgressSlider(
                            scale: controlSize.scale,
                            sliderKey: const Key('player-progress-slider'),
                            value: _progress,
                            onChangeStart: _startProgressDrag,
                            onChanged: _updateProgressDrag,
                            onChangeEnd: _finishProgressDrag,
                          ),
                          PlayerControlGroups(
                            playbackControls: <Widget>[
                              PlayerCompactIconButton(
                                scale: controlSize.scale,
                                key: const Key('play-pause-button'),
                                // 左下角播放按钮函数向原生播放器发送播放或暂停命令。
                                onPressed: _togglePlayback,
                                icon: _playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                tooltip: _playing ? '暂停' : '播放',
                              ),
                              if (_activeVideo.parts.length > 1) ...<Widget>[
                                PlayerCompactIconButton(
                                  scale: controlSize.scale,
                                  key: const Key('previous-part-button'),
                                  // 上一集函数切换到当前分P之前的一集。
                                  onPressed: _currentPartIndex > 0
                                      ? _playPreviousPart
                                      : () {},
                                  icon: Icons.skip_previous_rounded,
                                  tooltip: '上一集',
                                ),
                                PlayerCompactIconButton(
                                  scale: controlSize.scale,
                                  key: const Key('next-part-button'),
                                  // 下一集函数切换到当前分P之后的一集。
                                  onPressed:
                                      _currentPartIndex >= 0 &&
                                          _currentPartIndex <
                                              _activeVideo.parts.length - 1
                                      ? _playNextPart
                                      : () {},
                                  icon: Icons.skip_next_rounded,
                                  tooltip: '下一集',
                                ),
                              ],
                              Padding(
                                padding: const EdgeInsets.only(left: 2),
                                child: Text(
                                  _formatProgress(),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: controlSize.labelFont,
                                  ),
                                ),
                              ),
                            ],
                            displayControls: <Widget>[
                              if (_fullscreen && _activeVideo.parts.length > 1)
                                PlayerPartSelectorButton(
                                  scale: controlSize.scale,
                                  key: const Key('part-selector-button'),
                                  // 选集按钮函数只在横屏显示右侧双列面板。
                                  onPressed: _openPartSelector,
                                ),
                              if (!_playbackSnapshot.audioOnly)
                                SizedBox(
                                  height: controlSize.button,
                                  child: PopupMenuButton<int>(
                                    key: const Key('quality-menu'),
                                    initialValue: _playingOffline
                                        ? _PlayerPlaybackSession
                                              ._localCacheQuality
                                        : _currentQuality,
                                    tooltip: '清晰度',
                                    padding: EdgeInsets.zero,
                                    // 菜单使用短动画，避免点击控制项后仍感觉慢半拍。
                                    popUpAnimationStyle:
                                        _PlayerControlsCoordinator
                                            ._playerPopupMenuAnimationStyle,
                                    // 清晰度菜单选择函数保留进度后重新请求播放源。
                                    onSelected: (int quality) =>
                                        unawaited(_changeQuality(quality)),
                                    // 清晰度菜单构建函数使用原生接口实际返回的档位。
                                    itemBuilder: (BuildContext context) {
                                      return [
                                        if (_currentVideoDownloaded ||
                                            _playingOffline)
                                          const PopupMenuItem<int>(
                                            key: Key('quality-local-cache'),
                                            value: _PlayerPlaybackSession
                                                ._localCacheQuality,
                                            child: Text('本地缓存'),
                                          ),
                                        ..._availableQualities.map(
                                          (PlaybackQuality quality) =>
                                              PopupMenuItem<int>(
                                                key: Key(
                                                  'quality-${quality.id}',
                                                ),
                                                value: quality.id,
                                                child: Text(quality.label),
                                              ),
                                        ),
                                      ];
                                    },
                                    child: PlayerControlLabel(
                                      scale: controlSize.scale,
                                      text: _currentQualityLabel(),
                                    ),
                                  ),
                                ),
                              SizedBox(
                                height: controlSize.button,
                                child: PopupMenuButton<double>(
                                  key: const Key('speed-menu'),
                                  initialValue: _playbackSpeed,
                                  tooltip: '播放倍速',
                                  padding: EdgeInsets.zero,
                                  // 菜单使用短动画，避免点击控制项后仍感觉慢半拍。
                                  popUpAnimationStyle:
                                      _PlayerControlsCoordinator
                                          ._playerPopupMenuAnimationStyle,
                                  // 倍速菜单选择函数把用户选择交给原生播放器。
                                  onSelected: (double speed) =>
                                      unawaited(_changePlaybackSpeed(speed)),
                                  // 倍速菜单读取本机自定义档位，始终保留 1x。
                                  itemBuilder: (BuildContext context) {
                                    return _playbackPreferences.playbackSpeeds
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
                                  child: PlayerControlLabel(
                                    scale: controlSize.scale,
                                    text: _formatSpeed(_playbackSpeed),
                                  ),
                                ),
                              ),
                              PlayerCompactIconButton(
                                scale: controlSize.scale,
                                // 全屏按钮函数切换横屏沉浸状态。
                                onPressed: () => unawaited(_toggleFullscreen()),
                                icon: _fullscreen
                                    ? Icons.fullscreen_exit_rounded
                                    : Icons.fullscreen_rounded,
                                tooltip: _fullscreen ? '退出全屏' : '进入全屏',
                              ),
                            ],
                          ),
                        ],
                      ),
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
                    top:
                        controlSize.sideControlCenter(constraints.maxHeight) -
                        24 * controlSize.scale,
                    child: SafeArea(
                      right: false,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: IconButton(
                          iconSize: 24 * controlSize.scale,
                          constraints: BoxConstraints.tightFor(
                            width: 48 * controlSize.scale,
                            height: 48 * controlSize.scale,
                          ),
                          style: IconButton.styleFrom(
                            fixedSize: Size.square(48 * controlSize.scale),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
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
                if (inPictureInPicture && _appPlatform == AppPlatform.linux)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: _playbackSnapshot.isPlaying ? '暂停' : '播放',
                            color: Colors.white,
                            onPressed: _togglePlayback,
                            icon: Icon(
                              _playbackSnapshot.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                            ),
                          ),
                          IconButton(
                            tooltip: '返回完整窗口',
                            color: Colors.white,
                            onPressed: _enterPictureInPicture,
                            icon: const Icon(Icons.open_in_full),
                          ),
                        ],
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
    final bool landscapeLayout = screenSize.width > screenSize.height;
    _schedulePlayerSystemUiSync(landscapeLayout: landscapeLayout);
    final bool workspaceLayout =
        !fullscreenLayout && AdaptiveLayout.usesWorkspace(screenSize);
    final extraControlRow = screenSize.width < 6 * controlSize.button
        ? controlSize.button
        : 0.0;
    final maximumPlayerHeight =
        screenSize.height * (0.62 + 0.18 * (controlSize.scale - 1).clamp(0, 1));
    final minimumPlayerHeight =
        (180 * controlSize.scale.clamp(1, PlaybackPreferences.maxControlScale) +
                extraControlRow)
            .clamp(0, maximumPlayerHeight)
            .toDouble();
    final double playerHeight = fullscreenLayout
        ? screenSize.height
        : (screenSize.width / aspectRatio)
              .clamp(minimumPlayerHeight, maximumPlayerHeight)
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
      child: Focus(
        autofocus: true,
        onKeyEvent: _handlePlayerKeyEvent,
        child: MouseRegion(
          key: const Key('player-mouse-region'),
          cursor: _playerMouseCursor,
          child: pageScaffold,
        ),
      ),
    );
  }
}
