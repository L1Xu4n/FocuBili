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
}
