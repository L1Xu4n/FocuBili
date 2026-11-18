part of 'player_page.dart';

/// 组合播放器的拖动预览、学习完播和互动剧情选择反馈。
extension _PlayerFeedbackView on _PlayerPageState {
  /// 等完整图集实际解码才画目标格；传输期间不用上一张图冒充。
  Widget _buildVideoShotFrame(VideoShotFrame frame) {
    const displayWidth = 176.0;
    final displayHeight = displayWidth * frame.frameHeight / frame.frameWidth;
    final sheetPixelWidth = frame.frameWidth * frame.sheetColumns;
    final decodeWidth =
        (displayWidth *
                frame.sheetColumns *
                MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 2048);
    final smallerUrl = sheetPixelWidth > decodeWidth
        ? frame.resizedPublicAtlasUrl(decodeWidth)
        : null;

    Widget atlas(String url, {required bool resized}) {
      Widget unavailable() => resized
          ? atlas(frame.imageUrl, resized: false)
          : const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '预览暂不可用',
                key: Key('video-shot-unavailable'),
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            );
      return AppNetworkImage(
        key: ValueKey((_activeVideo.bvid, _currentPart.cid, url)),
        imageUrl: url,
        cache: widget.videoShotImageCache,
        memCacheWidth: decodeWidth,
        excludeFromSemantics: true,
        placeholder: (_, _) => const _VideoShotLoading(),
        errorWidget: (_, _, _) => unavailable(),
        frameBuilder: (context, child, number, _) {
          if (number == null || child is! RawImage || child.image == null) {
            return const _VideoShotLoading();
          }
          final image = child.image!;
          final scale = image.width / sheetPixelWidth;
          final rowHeight = frame.frameHeight * scale;
          final rows = (image.height / rowHeight).round();
          // 最后一页可以少于完整行数；比例错误或缺少目标格时不能拉伸假图。
          if (rows > frame.sheetRows ||
              frame.row >= rows ||
              (rows * rowHeight - image.height).abs() > 1) {
            return unavailable();
          }
          final width = image.width / frame.sheetColumns;
          final height = image.height / rows;
          return ClipRRect(
            key: const Key('video-shot-frame'),
            borderRadius: BorderRadius.circular(8),
            child: CustomPaint(
              size: Size(displayWidth, displayHeight),
              painter: _VideoShotCellPainter(
                image,
                Rect.fromLTWH(
                  frame.column * width,
                  frame.row * height,
                  width,
                  height,
                ),
              ),
            ),
          );
        },
      );
    }

    return atlas(smallerUrl ?? frame.imageUrl, resized: smallerUrl != null);
  }

  /// 横滑显示目标图和时间；拖播放器底部进度条仍沿用原来的行为。
  Widget _buildSeekFeedback() {
    final Duration target = Duration(
      milliseconds:
          (_displayDuration.inMilliseconds * _horizontalScrubTargetProgress)
              .round(),
    );
    final message = _horizontalScrubbing
        ? '跳转至 ${_formatSeconds((target.inMilliseconds / 1000).round())}'
        : _seekFeedback;
    if (message == null) return const SizedBox.shrink();
    final frame = _horizontalScrubbing
        ? _videoShotPreview?.frameFor(target)
        : null;

    return Center(
      child: IgnorePointer(
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
                  if (frame != null)
                    _buildVideoShotFrame(frame)
                  else if (_horizontalScrubbing && _videoShotLoading)
                    const _VideoShotLoading(),
                  Text(message, style: const TextStyle(color: Colors.white)),
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
  Widget _buildFadingControls(Widget child, {Key? regionKey}) {
    final visible =
        _showControls &&
        !_controlsLocked &&
        !_playbackSnapshot.isInPictureInPicture;
    return IgnorePointer(
      key: regionKey,
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
                  _horizontalScrubbing ||
                  _seekFeedback != null ||
                  _doubleTapSeekSeconds != 0 ||
                  _playbackActionPlaying != null;
              final liveScrub = _horizontalScrubbing || _seekFeedback != null;
              final doubleTap = !liveScrub && _doubleTapSeekSeconds != 0;
              Widget seek({bool fillWidth = false}) => PlayerSeekFeedback(
                key: ValueKey('seek-$_doubleTapFeedbackSequence'),
                seconds: _doubleTapSeekSeconds,
                foregroundOnly: true,
                fillWidth: fillWidth,
              );
              final Widget gesture = liveScrub
                  ? _buildSeekFeedback()
                  : doubleTap
                  ? seek()
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
              if (doubleTap) {
                // A blocking error needs all the remaining height for Retry;
                // the noninteractive picture band can continue to fade below.
                if (phase == PlaybackPhase.error) return hint;
                if (constraints.maxHeight < 124) {
                  if (constraints.maxWidth < 56) return hint;
                  // In a short viewport, share width rather than splitting a
                  // single readable line into two too-short rows.
                  final direction = SizedBox(
                    width:
                        constraints.maxWidth *
                        PlayerSeekFeedback.bandWidthFactor,
                    child: seek(fillWidth: true),
                  );
                  final compactHint = Expanded(
                    child: IgnorePointer(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  _playbackSnapshot.message ?? '正在准备播放…',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _doubleTapSeekSeconds > 0
                        ? [compactHint, direction]
                        : [direction, compactHint],
                  );
                }
              }
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

class _VideoShotLoading extends StatelessWidget {
  const _VideoShotLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: Key('video-shot-loading'),
      padding: EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 7),
          Text('正在加载预览', style: TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}

class _VideoShotCellPainter extends CustomPainter {
  const _VideoShotCellPainter(this.image, this.source);
  final ui.Image image;
  final Rect source;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawImageRect(image, source, Offset.zero & size, Paint());

  @override
  bool shouldRepaint(_VideoShotCellPainter oldDelegate) =>
      image != oldDelegate.image || source != oldDelegate.source;
}
