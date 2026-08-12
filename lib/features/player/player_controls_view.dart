part of 'player_page.dart';

/// 组合播放器的选集、更多菜单、视频画面和播放状态提示。
extension _PlayerControlsView on _PlayerPageState {
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
                mainAxisExtent:
                    _PlayerControlsCoordinator._expandedPartItemHeight,
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

  /// 创建当前平台的视频画面，并在横竖屏中统一应用用户选择的比例模式。
  Widget _buildVideoOutput() {
    final PlaybackService service = _playbackService;
    if (service is PlaybackVideoSurface) {
      final PlaybackVideoSurface surface = service as PlaybackVideoSurface;
      final double aspectRatio = _playbackSnapshot.videoAspectRatio > 0
          ? _playbackSnapshot.videoAspectRatio
          : 16 / 9;
      return _buildFittedVideoOutput(surface.buildVideoSurface(), aspectRatio);
    }
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
}
