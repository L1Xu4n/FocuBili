part of 'player_page.dart';

/// 组合播放器的拖动预览、学习完播和互动剧情选择反馈。
extension _PlayerFeedbackView on _PlayerPageState {
  /// Paint a cell only after the shared cache has decoded the sheet. A failure
  /// or an incomplete final row leaves just the seek time, not an empty card.
  Widget _buildVideoShotFrame(VideoShotFrame frame) {
    const displayWidth = 176.0;
    final displayHeight = displayWidth * frame.frameHeight / frame.frameWidth;
    final atlasWidth = frame.frameWidth * frame.sheetColumns;
    final decodedWidth =
        (displayWidth *
                frame.sheetColumns *
                MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 2048);
    return AppNetworkImage(
      key: ValueKey(frame.imageUrl),
      imageUrl: frame.imageUrl,
      cache: widget.videoShotImageCache,
      memCacheWidth: decodedWidth,
      excludeFromSemantics: true,
      errorWidget: (_, _, _) => const SizedBox.shrink(),
      frameBuilder: (context, child, frameNumber, _) {
        if (frameNumber == null || child is! RawImage || child.image == null) {
          return const SizedBox.shrink();
        }
        final image = child.image!;
        final scale = image.width / atlasWidth;
        final rowHeight = frame.frameHeight * scale;
        final rows = (image.height / rowHeight).round();
        // A final sheet can have fewer full rows; a changed aspect ratio or
        // missing row must not stretch unrelated pixels into a thumbnail.
        if (rows > frame.sheetRows ||
            frame.row >= rows ||
            (rows * rowHeight - image.height).abs() > 1) {
          return const SizedBox.shrink();
        }
        final cellWidth = image.width / frame.sheetColumns;
        final cellHeight = image.height / rows;
        return ClipRRect(
          key: const Key('video-shot-frame'),
          borderRadius: BorderRadius.circular(8),
          child: CustomPaint(
            size: Size(displayWidth, displayHeight),
            painter: _VideoShotCellPainter(
              image,
              Rect.fromLTWH(
                frame.column * cellWidth,
                frame.row * cellHeight,
                cellWidth,
                cellHeight,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 创建由统一提示区排列的拖动卡；无截图时仍显示准确目标时间。
  Widget _buildSeekFeedback() {
    if (_seekFeedback == null) return const SizedBox.shrink();
    final progress = _isDraggingProgress
        ? _progress
        : _horizontalScrubTargetProgress;
    final target = Duration(
      milliseconds: (_displayDuration.inMilliseconds * progress).round(),
    );
    final frame = _isDraggingProgress || _horizontalScrubbing
        ? _videoShotPreview?.frameFor(target)
        : null;
    return Center(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _seekFeedback == null ? 0 : 1,
          duration: const Duration(milliseconds: 160),
          child: FittedBox(
            fit: BoxFit.scaleDown,
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
                    Text(
                      _isDraggingProgress
                          ? _progressDragText(_progress)
                          : _seekFeedback ?? '',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 创建学习清单完播卡，位置由统一提示区测量和排列。
  Widget _buildPlaybackCompletionPrompt() {
    if (!_completionPromptVisible || _playbackSnapshot.isInPictureInPicture) {
      return const SizedBox.shrink();
    }
    final LearningListEntry? currentEntry = _currentLearningListEntry;
    final bool markingCompleted = _addingLearningBvid == _activeVideo.bvid;
    final bool markedCompleted =
        currentEntry?.status == LearningListStatus.completed;
    return Center(
      child: TickerMode(
        enabled: !_choosingLearningParts,
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
    return InteractiveVideoChoiceOverlay(
      node: _playerEnhancementController.interactiveNode,
      loading:
          _playerEnhancementController.interactiveNodeLoading ||
          _interactiveChoiceOpening,
      errorMessage: _playerEnhancementController.interactiveNodeError,
      bottomInset: 0,
      embedded: true,
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

  /// 让上下栏分别淡出并透传隐藏后的触摸，不影响提示可见性。
  Widget _buildFadingControls(Widget child) {
    final visible =
        _showControls &&
        !_controlsLocked &&
        !_playbackSnapshot.isInPictureInPicture;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: child,
      ),
    );
  }

  /// 顶部状态、中央手势和底部字幕独立布局；听视频仍留在画面层。
  Widget _buildPlayerFeedback() {
    if (_playbackSnapshot.isInPictureInPicture) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _playerNotices,
      builder: (context, _) {
        final subtitle = _activeSubtitleCue();
        final subtitleVisible =
            subtitle != null || (_subtitleCuesLoading && _subtitleCues.isEmpty);
        final phase = _playbackSnapshot.phase;
        final playbackHintVisible =
            phase == PlaybackPhase.error || phase == PlaybackPhase.loading;
        final bottomInteractive =
            _completionPromptVisible || _interactivePromptVisible;
        return PlayerFeedbackLanes(
          top: PlayerFeedbackStack(
            interactive: _playerNotices.entries.any(
              (entry) => entry.onAction != null,
            ),
            children: [
              if (_temporarySpeedActive)
                PlayerNoticeCard(
                  key: const Key('temporary-triple-speed'),
                  message: _playbackPreferences.longPressPlaybackSpeed == 3
                      ? '三倍速中>>'
                      : '${_playbackPreferences.longPressPlaybackSpeed}倍速中>>',
                ),
              for (final entry in _playerNotices.entries)
                PlayerNoticeCard(
                  key: entry.message == _playerNotices.messages.first
                      ? const Key('player-floating-notice')
                      : ValueKey('player-notice-${entry.message}'),
                  message: entry.message,
                  actionLabel: entry.actionLabel,
                  onAction: entry.onAction,
                ),
              if (_resumeNotice != null)
                PlayerNoticeCard(
                  key: const Key('player-resume-notice'),
                  message: _resumeNotice!,
                ),
            ],
          ),
          center: LayoutBuilder(
            builder: (context, constraints) {
              final hasGesture =
                  _seekFeedback != null ||
                  _doubleTapSeekSeconds != 0 ||
                  _playbackActionPlaying != null;
              final Widget gesture = _seekFeedback != null
                  ? _buildSeekFeedback()
                  : _doubleTapSeekSeconds != 0
                  ? PlayerSeekFeedback(
                      key: ValueKey('seek-$_doubleTapFeedbackSequence'),
                      seconds: _doubleTapSeekSeconds,
                      compact: true,
                    )
                  : _playbackActionPlaying != null
                  ? PlayerActionFeedback(
                      key: ValueKey('playback-action-$_playbackActionSequence'),
                      playing: _playbackActionPlaying!,
                    )
                  : const SizedBox.shrink();
              final hint = PlayerFeedbackStack(
                interactive: phase == PlaybackPhase.error,
                alignment: Alignment.center,
                children: [if (playbackHintVisible) _buildPlaybackHint()],
              );
              if (!playbackHintVisible) return gesture;
              if (!hasGesture) return hint;
              // Native seek may temporarily enter loading. Its spinner/retry
              // row must not paint over the still-running direction animation.
              final height = (constraints.maxHeight * .45).clamp(0.0, 72.0);
              final gap = (constraints.maxHeight - height).clamp(0.0, 6.0);
              return Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: height,
                    child: gesture,
                  ),
                  SizedBox(height: gap),
                  Expanded(child: hint),
                ],
              );
            },
          ),
          bottom: PlayerFeedbackStack(
            interactive: bottomInteractive,
            alignment: Alignment.bottomCenter,
            children: [
              if (_completionPromptVisible) _buildPlaybackCompletionPrompt(),
              if (_interactivePromptVisible) _buildInteractiveVideoPrompt(),
            ],
          ),
          subtitle: subtitleVisible
              ? _buildSubtitleOverlay()
              : const SizedBox.shrink(),
          subtitlePosition: _playbackPreferences.subtitlePosition,
        );
      },
    );
  }
}

class _VideoShotCellPainter extends CustomPainter {
  const _VideoShotCellPainter(this.image, this.source);

  final ui.Image image;
  final Rect source;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(image, source, Offset.zero & size, Paint());
  }

  @override
  bool shouldRepaint(_VideoShotCellPainter previous) =>
      image != previous.image || source != previous.source;
}
