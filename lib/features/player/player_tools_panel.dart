part of 'player_page.dart';

enum _PlayerToolGroup {
  viewing('观看方式'),
  playback('播放与学习'),
  picture('画面比例'),
  content('内容管理');

  const _PlayerToolGroup(this.label);

  final String label;
}

enum _PlayerMoreMenuAction {
  listening(
    _PlayerToolGroup.viewing,
    'listening-menu-item',
    Icons.headphones_outlined,
  ),
  subtitles(
    _PlayerToolGroup.viewing,
    'player-subtitle-menu-item',
    Icons.closed_caption_outlined,
  ),
  danmakuSettings(
    _PlayerToolGroup.viewing,
    'danmaku-settings-menu-item',
    Icons.tune_rounded,
  ),
  playlist(
    _PlayerToolGroup.playback,
    'playback-playlist-menu-item',
    Icons.queue_music_rounded,
  ),
  playbackLoop(
    _PlayerToolGroup.playback,
    'playback-loop-menu-item',
    Icons.repeat_one_rounded,
  ),
  abRepeat(
    _PlayerToolGroup.playback,
    'ab-repeat-menu-item',
    Icons.repeat_on_outlined,
  ),
  sleepTimer(
    _PlayerToolGroup.playback,
    'sleep-timer-menu-item',
    Icons.bedtime_outlined,
  ),
  fitContain(
    _PlayerToolGroup.picture,
    'video-fit-mode-contain',
    Icons.fit_screen_rounded,
  ),
  fitCover(
    _PlayerToolGroup.picture,
    'video-fit-mode-cover',
    Icons.crop_free_rounded,
  ),
  fitStretch(
    _PlayerToolGroup.picture,
    'video-fit-mode-stretch',
    Icons.aspect_ratio_rounded,
  ),
  blockVideo(
    _PlayerToolGroup.content,
    'player-block-video',
    Icons.hide_source_outlined,
  ),
  blockCreator(
    _PlayerToolGroup.content,
    'player-block-creator',
    Icons.person_off_outlined,
  ),
  manageBlocklist(
    _PlayerToolGroup.content,
    'player-manage-blocklist',
    Icons.shield_outlined,
  );

  const _PlayerMoreMenuAction(this.group, this.key, this.icon);

  final _PlayerToolGroup group;
  final String key;
  final IconData icon;
}

typedef _PlayerTool = ({
  _PlayerMoreMenuAction action,
  String title,
  String? detail,
  IconData icon,
  bool enabled,
  bool? selected,
  bool? toggled,
  bool opensPanel,
});

_PlayerTool _playerTool(
  _PlayerMoreMenuAction action,
  String title, {
  String? detail,
  IconData? icon,
  bool enabled = true,
  bool? selected,
  bool? toggled,
  bool opensPanel = false,
}) => (
  action: action,
  title: title,
  detail: detail,
  icon: icon ?? action.icon,
  enabled: enabled,
  selected: selected,
  toggled: toggled,
  opensPanel: opensPanel,
);

typedef _PlayerToolsIdentity = (String, int, int);

/// 独立路由与播放器仅共享当前可用操作；不接管播放状态或手势。
class _PlayerToolsSession extends ValueNotifier<List<_PlayerTool>> {
  _PlayerToolsSession(this.identity, super.value);

  final _PlayerToolsIdentity identity;
}

extension _PlayerToolsView on _PlayerPageState {
  _PlayerToolsIdentity get _playerToolsIdentity =>
      (_activeVideo.bvid, _currentPart.cid, _partSwitchGeneration);

  Future<void> _openPlayerTools() async {
    if (_playerToolsOpen ||
        !_showControls ||
        _controlsLocked ||
        _playbackSnapshot.isInPictureInPicture) {
      return;
    }
    final navigator = Navigator.of(context);
    final playerRoute = ModalRoute.of(context);
    if (playerRoute?.isCurrent != true) return;

    final session = _PlayerToolsSession(
      _playerToolsIdentity,
      _playerToolItems(),
    );
    _playerToolsSession = session;
    _stopControlsAutoHideTimer();

    final route = DialogRoute<_PlayerMoreMenuAction>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierLabel: '关闭播放器功能',
      barrierColor: Colors.black.withValues(alpha: .46),
      requestFocus: true,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Duration(milliseconds: 180),
              reverseDuration: Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
            ),
      builder: (_) =>
          _PlayerToolsPanel(session: session, desktop: _appPlatform.isDesktop),
    );
    _PlayerMoreMenuAction? action;
    try {
      action = await navigator.push(route);
      if (mounted && playerRoute?.isCurrent == true) {
        // 直接操作不必等退场动画：例如切换听视频应立即暂停 A–B 调度。
        _applyPlayerToolsAction(session, action, opensPanel: false);
      }
      // 关闭期间不接收第二次触发，也不在旧路由上叠放二级设置。
      await route.completed;
    } finally {
      _playerToolsSession = null;
      session.dispose();
    }
    if (!mounted || playerRoute?.isCurrent != true) return;
    _showPlayerControls();
    if (_playerToolsTriggerFocus.context != null) {
      _playerToolsTriggerFocus.requestFocus();
    }
    _applyPlayerToolsAction(session, action, opensPanel: true);
  }

  void _applyPlayerToolsAction(
    _PlayerToolsSession session,
    _PlayerMoreMenuAction? action, {
    required bool opensPanel,
  }) {
    if (action == null ||
        _controlsLocked ||
        _playbackSnapshot.isInPictureInPicture ||
        session.identity != _playerToolsIdentity) {
      return;
    }
    if (_playerToolItems().any(
      (item) =>
          item.action == action &&
          item.enabled &&
          item.opensPanel == opensPanel,
    )) {
      _handleMoreSettingsSelection(action);
    }
  }

  /// 原页面状态改变时刷新打开的面板，但不要在构建期间重建另一个路由。
  void _refreshPlayerTools() {
    final session = _playerToolsSession;
    if (session == null) return;
    final items = session.identity == _playerToolsIdentity
        ? _playerToolItems()
        : const <_PlayerTool>[];
    if (listEquals(items, session.value)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(session, _playerToolsSession)) return;
      session.value = items;
    });
  }

  List<_PlayerTool> _playerToolItems() {
    final loading = _playbackSnapshot.phase == PlaybackPhase.loading;
    final listening = _playbackSnapshot.audioOnly;
    final ab = _abRepeatRange;
    final subtitle = _selectedSubtitleTrack;
    return [
      if (_playbackService is ListeningPlaybackService)
        _playerTool(
          _PlayerMoreMenuAction.listening,
          listening ? '返回看视频' : '听视频（省流）',
          icon: listening ? Icons.ondemand_video_outlined : null,
          enabled: !_switchingListening && !loading,
          detail: _switchingListening
              ? '正在切换'
              : loading
              ? '等待视频加载'
              : listening
              ? '仅音频'
              : null,
        ),
      _playerTool(
        _PlayerMoreMenuAction.subtitles,
        '字幕',
        detail: subtitle == null ? '未开启' : '已开启',
        opensPanel: true,
      ),
      _playerTool(
        _PlayerMoreMenuAction.danmakuSettings,
        '弹幕设置',
        detail: _danmakuEnabled ? '已开启' : '已关闭',
        opensPanel: true,
      ),
      _playerTool(
        _PlayerMoreMenuAction.playlist,
        '播放列表与模式',
        detail: _playbackPreferences.mode.label,
        opensPanel: true,
      ),
      _playerTool(
        _PlayerMoreMenuAction.playbackLoop,
        '循环播放',
        toggled: _playbackLoopEnabled,
        enabled: !_savingPlayerToolsLoop,
        detail: _savingPlayerToolsLoop
            ? '正在保存'
            : _playbackLoopEnabled
            ? '已开启'
            : '未开启',
      ),
      _playerTool(
        _PlayerMoreMenuAction.abRepeat,
        'A–B 区间循环',
        detail: ab == null
            ? '未设置'
            : '${formatAbRepeatTime(ab.a)} – ${formatAbRepeatTime(ab.b)}',
        opensPanel: true,
      ),
      _playerTool(
        _PlayerMoreMenuAction.sleepTimer,
        '定时关闭',
        detail: _sleepTimerMenuStatus,
        opensPanel: true,
      ),
      _fitTool(_PlayerMoreMenuAction.fitContain, _VideoFitMode.contain),
      _fitTool(_PlayerMoreMenuAction.fitCover, _VideoFitMode.cover),
      _fitTool(_PlayerMoreMenuAction.fitStretch, _VideoFitMode.stretch),
      if (!_activeVideo.isCourse)
        _playerTool(_PlayerMoreMenuAction.blockVideo, '屏蔽该视频'),
      _playerTool(
        _PlayerMoreMenuAction.blockCreator,
        '屏蔽该 UP 主',
        enabled: _activeVideo.ownerMid > 0,
        detail: _activeVideo.ownerMid > 0 ? null : '未取得 UP 主信息',
      ),
      _playerTool(
        _PlayerMoreMenuAction.manageBlocklist,
        '管理黑名单',
        opensPanel: true,
      ),
    ];
  }

  _PlayerTool _fitTool(_PlayerMoreMenuAction action, _VideoFitMode mode) =>
      _playerTool(
        action,
        _videoFitModeLabel(mode),
        selected: _videoFitMode == mode,
        detail: _videoFitMode == mode ? '当前比例' : null,
      );
}

class _PlayerToolsPanel extends StatefulWidget {
  const _PlayerToolsPanel({required this.session, required this.desktop});

  final _PlayerToolsSession session;
  final bool desktop;

  @override
  State<_PlayerToolsPanel> createState() => _PlayerToolsPanelState();
}

class _PlayerToolsPanelState extends State<_PlayerToolsPanel> {
  final _scroll = ScrollController();
  bool _closing = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _dismiss([_PlayerMoreMenuAction? action]) {
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    _closing = true;
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, space) {
        final side =
            space.maxWidth >= 560 &&
            (widget.desktop || space.maxWidth > space.maxHeight);
        final short = space.maxHeight < 440;
        return Dialog(
          key: const Key('player-tools-panel'),
          alignment: side
              ? AlignmentDirectional.centerEnd
              : Alignment.bottomCenter,
          insetPadding: EdgeInsets.symmetric(
            horizontal: side ? (short ? 12 : 24) : 10,
            vertical: short ? 8 : 12,
          ),
          constraints: BoxConstraints(
            maxWidth: side ? 416 : 480,
            maxHeight: side ? 860 : space.maxHeight * (short ? .96 : .86),
          ),
          backgroundColor: colors.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    short ? 0 : 8,
                    10,
                    short ? 0 : 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          namesRoute: true,
                          header: true,
                          child: Text(
                            '播放器功能',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('player-tools-close'),
                        tooltip: '关闭功能列表',
                        autofocus: true,
                        onPressed: _dismiss,
                        icon: const Icon(Icons.close_rounded),
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(48),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colors.outlineVariant),
                Flexible(
                  child: ValueListenableBuilder(
                    valueListenable: widget.session,
                    builder: (context, items, _) => _buildItems(context, items),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildItems(BuildContext context, List<_PlayerTool> items) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return RawScrollbar(
      controller: _scroll,
      thumbVisibility: true,
      thumbColor: colors.onSurfaceVariant.withValues(alpha: .55),
      thickness: 3,
      radius: const Radius.circular(2),
      crossAxisMargin: 4,
      mainAxisMargin: 4,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          key: const Key('player-tools-scroll'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(10, 4, 14, 10),
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Semantics(
                    liveRegion: true,
                    child: const Text('播放内容已切换，请重新打开功能列表。'),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final group in _PlayerToolGroup.values) ...[
                      if (group != _PlayerToolGroup.values.first)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 3, 6, 0),
                          child: Divider(
                            height: 1,
                            color: colors.outlineVariant,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 11, 6, 4),
                        child: Semantics(
                          header: true,
                          child: Text(
                            group.label,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      for (final item in items)
                        if (item.action.group == group)
                          _PlayerToolRow(
                            key: Key(item.action.key),
                            item: item,
                            onPressed: item.enabled
                                ? () => _dismiss(item.action)
                                : null,
                          ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _PlayerToolRow extends StatelessWidget {
  const _PlayerToolRow({super.key, required this.item, this.onPressed});

  final _PlayerTool item;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = item.selected == true || item.toggled == true;
    final foreground = !item.enabled
        ? colors.onSurfaceVariant
        : active
        ? colors.onPrimaryContainer
        : colors.onSurface;
    final detailColor = active && item.enabled
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;
    final radius = BorderRadius.circular(10);
    final detail = item.detail;
    final title = Text(
      item.title,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: foreground,
        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    final status = detail == null
        ? null
        : Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(color: detailColor),
          );
    final trailing = item.selected != null
        ? item.selected!
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded
        : item.toggled != null
        ? item.toggled!
              ? Icons.toggle_on_rounded
              : Icons.toggle_off_outlined
        : !item.enabled
        ? Icons.info_outline_rounded
        : item.opensPanel
        ? Icons.chevron_right_rounded
        : null;

    return Semantics(
      container: true,
      button: true,
      enabled: item.enabled,
      label: item.title,
      value: detail,
      selected: item.selected,
      inMutuallyExclusiveGroup: item.selected != null,
      toggled: item.toggled,
      onTap: onPressed,
      child: Ink(
        decoration: active
            ? BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: radius,
              )
            : null,
        child: InkWell(
          borderRadius: radius,
          excludeFromSemantics: true,
          onTap: onPressed,
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      color: active ? foreground : colors.onSurfaceVariant,
                      size: 21,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, size) {
                          if (status == null) return title;
                          if (size.maxWidth >= 218 &&
                              MediaQuery.textScalerOf(context).scale(14) <=
                                  17) {
                            return Row(
                              children: [
                                Expanded(flex: 3, child: title),
                                const SizedBox(width: 8),
                                Flexible(
                                  flex: 2,
                                  child: Align(
                                    alignment: AlignmentDirectional.centerEnd,
                                    child: status,
                                  ),
                                ),
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              title,
                              const SizedBox(height: 2),
                              status,
                            ],
                          );
                        },
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 10),
                      Icon(trailing, color: detailColor, size: 20),
                    ] else
                      const SizedBox(width: 30),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
