part of 'player_page.dart';

/// 组合播放器的拖动预览、学习完播和互动剧情选择反馈。
extension _PlayerFeedbackView on _PlayerPageState {
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

  /// 创建由统一提示区排列的拖动卡；无截图时仍显示准确目标时间。
  Widget _buildSeekFeedback() {
    if (_seekFeedback == null) return const SizedBox.shrink();
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
      child: PlaybackCompletionOverlay(
        markedCompleted: markedCompleted,
        learningFinished: _completionLearningFinished,
        processing: markingCompleted,
        // 完成回调只更新当前学习任务，不改变播放器分P。
        onMarkCompleted: () => unawaited(_markCurrentLearningCompleted()),
        // 继续学习回调只在用户明确点击后按学习清单顺序打开下一条任务。
        onContinueLearning: () => unawaited(_continueLearningAfterCompletion()),
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

  /// 将短消息、续播、字幕和操作卡片排成一列；听视频状态使用独立画面层。
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
        final actionVisible =
            _completionPromptVisible ||
            _interactivePromptVisible ||
            phase == PlaybackPhase.error ||
            _playerNotices.entries.any((entry) => entry.onAction != null);
        final gestureVisible =
            _seekFeedback != null ||
            _doubleTapSeekSeconds != 0 ||
            _playbackActionPlaying != null;
        // 这里仍有控制栏之间的有限高度；进入可滚动提示列后高度约束会丢失。
        return LayoutBuilder(
          builder: (context, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              // Direction feedback belongs to the video edges, outside the
              // 620px notice column and its scrolling/overflow state.
              if (_seekFeedback == null && _doubleTapSeekSeconds != 0)
                Align(
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: double.infinity,
                    height: constraints.maxHeight.clamp(0.0, 72.0),
                    child: PlayerSeekFeedback(
                      key: ValueKey('seek-$_doubleTapFeedbackSequence'),
                      seconds: _doubleTapSeekSeconds,
                      compact: true,
                    ),
                  ),
                ),
              PlayerFeedbackStack(
                interactive: actionVisible,
                alignment:
                    _completionPromptVisible ||
                        _interactivePromptVisible ||
                        subtitleVisible
                    ? Alignment.bottomCenter
                    : gestureVisible || playbackHintVisible
                    ? Alignment.center
                    : Alignment.topCenter,
                children: [
                  if (_temporarySpeedActive)
                    const PlayerNoticeCard(
                      key: Key('temporary-triple-speed'),
                      message: '三倍速中>>',
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
                  // 直接拖动优先于尚未消失的旧动画，避免同一手势重复反馈。
                  if (_seekFeedback != null)
                    _buildSeekFeedback()
                  else if (_doubleTapSeekSeconds == 0 &&
                      _playbackActionPlaying != null)
                    SizedBox(
                      height: constraints.maxHeight.clamp(0.0, 84.0),
                      child: PlayerActionFeedback(
                        key: ValueKey(
                          'playback-action-$_playbackActionSequence',
                        ),
                        playing: _playbackActionPlaying!,
                      ),
                    ),
                  if (playbackHintVisible) _buildPlaybackHint(),
                  if (_completionPromptVisible)
                    _buildPlaybackCompletionPrompt(),
                  if (_interactivePromptVisible) _buildInteractiveVideoPrompt(),
                  if (subtitleVisible) _buildSubtitleOverlay(),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
