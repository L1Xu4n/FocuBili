part of 'player_page.dart';

/// 组合共享轨道边界上的章节和笔记标记。
extension _PlayerTimelineView on _PlayerPageState {
  /// 展开时对齐 Slider，收起时让章节条与全宽微型进度条使用同一左右边界。
  Widget _buildTimelineAnnotations({bool collapsed = false}) {
    final showChapters =
        _playerEnhancementController.chapters.isNotEmpty &&
        _playerEnhancementController.chapterProgressVisible;
    final showFlags =
        _playbackPreferences.showNoteTimeMarkers &&
        _currentVideoNotes.any((note) => note.partCid == _currentPart.cid);
    if (!showChapters && !showFlags) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('player-timeline-annotations'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showFlags)
          PlayerNoteFlags(
            notes: _currentVideoNotes,
            bvid: _activeVideo.bvid,
            cid: _currentPart.cid,
            duration: _displayDuration,
            // 旗标回调打开现有工作区，不自动跳转播放位置。
            onOpen: (notes) => unawaited(_openPlayerNoteFlag(notes)),
          ),
        if (showChapters)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : PlayerTimelineGeometry.trackInset,
            ),
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
          ),
      ],
    );
  }

  /// 控制栏隐藏或锁定后，仍在视频底部显示可操作的章节和旗标。
  Widget _buildChapterProgressOverlay({required bool inPictureInPicture}) {
    if (inPictureInPicture || (_showControls && !_controlsLocked)) {
      return const SizedBox.shrink();
    }
    final double fullscreenSafeBottom = _fullscreen
        ? MediaQuery.paddingOf(context).bottom
        : 0;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 4 + fullscreenSafeBottom,
      child: _buildTimelineAnnotations(collapsed: true),
    );
  }
}
