part of 'player_page.dart';

/// 组合播放器画面、控制层、详情区域和不同窗口尺寸下的页面骨架。
extension _PlayerPageView on _PlayerPageState {
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

  /// 组合播放器画面、手势、错误重试层、控制层和响应式页面骨架。
  Widget _buildPlayerPage(BuildContext context) {
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
                                        showNetworkType:
                                            _appPlatform != AppPlatform.windows,
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
                                          if (_playbackService
                                              is! PlaybackVideoSurface)
                                            PlayerCompactIconButton(
                                              key: const Key(
                                                'picture-in-picture',
                                              ),
                                              // 画中画按钮函数仅在当前原生播放服务声明支持时显示。
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
                                                  _PlayerControlsCoordinator
                                                      ._playerPopupMenuAnimationStyle,
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
                                                  _PlayerControlsCoordinator
                                                      ._playerPopupMenuAnimationStyle,
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
                                                  _PlayerControlsCoordinator
                                                      ._playerPopupMenuAnimationStyle,
                                              // 倍速菜单选择函数把用户选择交给原生播放器。
                                              onSelected: (double speed) =>
                                                  unawaited(
                                                    _changePlaybackSpeed(speed),
                                                  ),
                                              // 倍速菜单构建函数生成包含三倍速的六档速度。
                                              itemBuilder: (BuildContext context) {
                                                return _PlayerControlsCoordinator
                                                    ._playbackSpeeds
                                                    .map(
                                                      (double speed) =>
                                                          PopupMenuItem<double>(
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
                                                    .toList(growable: false);
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
      child: Focus(
        autofocus: true,
        onKeyEvent: _handlePlayerKeyEvent,
        child: pageScaffold,
      ),
    );
  }
}
