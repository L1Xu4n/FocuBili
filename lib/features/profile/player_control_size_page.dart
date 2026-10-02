import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/playback_preferences.dart';
import '../../platform/app_platform.dart';
import '../../services/playback_preferences_service.dart';
import '../player/widgets/player_control_layout.dart';
import '../player/widgets/player_control_widgets.dart';
import 'fullscreen_settings_preview.dart';

/// 打开与实际横屏播放器等大的沉浸预览，返回保存后的大小比例。
Future<double?> showPlayerControlSizeEditor({
  required BuildContext context,
  required double scale,
  required PlaybackPreferencesService service,
  required AppPlatform platform,
}) => showFullscreenSettingsPreview<double>(
  context: context,
  platform: platform,
  builder: (context) => PlayerControlSizePage(scale: scale, service: service),
);

/// 按真实全屏位置呈现控制栏，在画面中央编辑本机大小。
class PlayerControlSizePage extends StatefulWidget {
  /// 接收已保存比例和服务；本次编辑仅维护草稿。
  const PlayerControlSizePage({
    super.key,
    required this.scale,
    required this.service,
  });
  final double scale;
  final PlaybackPreferencesService service;

  /// 创建预览的交互状态与大小草稿。
  @override
  State<PlayerControlSizePage> createState() => _PlayerControlSizePageState();
}

class _PlayerControlSizePageState extends State<PlayerControlSizePage> {
  late double _scale;
  bool _playing = false;
  bool _saving = false;
  bool _danmaku = false;
  double _progress = 0.25;
  double _speed = 1;
  String _quality = '高清 720P';

  /// 将旧比例校验后复制为本次草稿。
  @override
  void initState() {
    super.initState();
    _scale = PlaybackPreferences.normalizeControlScale(widget.scale);
  }

  /// 以 5% 档位即时改变真实控件的外观和点击尺寸。
  void _changeScale(double value) =>
      setState(() => _scale = PlaybackPreferences.normalizeControlScale(value));

  /// 试用播放按钮，只切换当前预览状态。
  void _togglePreview() => setState(() => _playing = !_playing);

  /// 试用上一集和下一集，并同步时间进度示例。
  void _seekPreview(double offset) =>
      setState(() => _progress = (_progress + offset).clamp(0, 1));

  /// 为不启动媒体服务的预览入口显示简短反馈。
  void _previewNotice(String label) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$label · 预览'),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  /// 保存成功后返回比例；失败时保留草稿供重试。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.service.saveControlScale(_scale);
      if (mounted) Navigator.of(context).pop(_scale);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('播放栏大小保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 用真实顶栏组件显示返回、标题和操作按钮，保留实际尺寸及换行规则。
  Widget _topBar(PlayerControlSize size) {
    final actions = <Widget>[
      PlayerCompactIconButton(
        scale: size.scale,
        onPressed: () => _previewNotice('专注'),
        icon: Icons.timer_outlined,
        tooltip: '开始专注',
      ),
      PlayerCompactIconButton(
        scale: size.scale,
        onPressed: () => _previewNotice('分段信息'),
        icon: Icons.view_timeline_outlined,
        tooltip: '分段信息',
      ),
      PlayerCompactIconButton(
        scale: size.scale,
        onPressed: () => _previewNotice('画中画'),
        icon: Icons.picture_in_picture_alt_rounded,
        tooltip: '画中画',
      ),
      PlayerCompactIconButton(
        scale: size.scale,
        onPressed: () => setState(() => _danmaku = !_danmaku),
        icon: _danmaku ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
        tooltip: _danmaku ? '关闭弹幕' : '开启弹幕',
      ),
      SizedBox(
        width: size.moreButton,
        height: size.moreButton,
        child: PopupMenuButton<String>(
          tooltip: '更多选项',
          padding: EdgeInsets.zero,
          iconSize: 22 * size.scale,
          icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
          onSelected: _previewNotice,
          itemBuilder: (context) => const [
            PopupMenuItem(value: '字幕设置', child: Text('字幕设置')),
            PopupMenuItem(value: '听视频', child: Text('听视频（省流）')),
          ],
        ),
      ),
    ];
    return PlayerTopControlBar(
      scale: size.scale,
      leading: PlayerCompactIconButton(
        scale: size.scale,
        onPressed: () => Navigator.of(context).pop(),
        icon: Icons.arrow_back_rounded,
        tooltip: '返回',
      ),
      title: Text(
        '播放栏大小预览',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontSize: 14 * size.scale,
          fontWeight: FontWeight.w600,
        ),
      ),
      actions: actions,
      actionsWidth: (actions.length - 1) * size.button + size.moreButton,
    );
  }

  /// 把真实进度条和两组控制项放在画面底部，菜单可以直接试用。
  Widget _bottomBar(PlayerControlSize size) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      PlayerProgressSlider(
        scale: size.scale,
        value: _progress,
        onChanged: (value) => setState(() => _progress = value),
      ),
      PlayerControlGroups(
        playbackControls: [
          PlayerCompactIconButton(
            key: const Key('preview-play-button'),
            scale: size.scale,
            onPressed: _togglePreview,
            icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            tooltip: _playing ? '暂停预览' : '播放预览',
          ),
          PlayerCompactIconButton(
            scale: size.scale,
            onPressed: () => _seekPreview(-0.1),
            icon: Icons.skip_previous_rounded,
            tooltip: '上一集',
          ),
          PlayerCompactIconButton(
            scale: size.scale,
            onPressed: () => _seekPreview(0.1),
            icon: Icons.skip_next_rounded,
            tooltip: '下一集',
          ),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '00:${(_progress * 60).round().toString().padLeft(2, '0')} / 01:00',
              style: TextStyle(color: Colors.white, fontSize: size.labelFont),
            ),
          ),
        ],
        displayControls: [
          PlayerPartSelectorButton(
            scale: size.scale,
            onPressed: () => _previewNotice('选集'),
          ),
          PopupMenuButton<String>(
            tooltip: '清晰度',
            padding: EdgeInsets.zero,
            onSelected: (value) => setState(() => _quality = value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: '高清 720P', child: Text('高清 720P')),
              PopupMenuItem(value: '高清 1080P', child: Text('高清 1080P')),
            ],
            child: PlayerControlLabel(text: _quality, scale: size.scale),
          ),
          PopupMenuButton<double>(
            tooltip: '播放倍速',
            padding: EdgeInsets.zero,
            onSelected: (value) => setState(() => _speed = value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 1, child: Text('1x')),
              PopupMenuItem(value: 1.5, child: Text('1.5x')),
              PopupMenuItem(value: 2, child: Text('2x')),
            ],
            child: PlayerControlLabel(
              text:
                  '${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}x',
              scale: size.scale,
            ),
          ),
          PlayerCompactIconButton(
            scale: size.scale,
            onPressed: () => Navigator.of(context).pop(),
            icon: Icons.fullscreen_exit_rounded,
            tooltip: '退出全屏',
          ),
        ],
      ),
    ],
  );

  /// 按当前范围生成 5% 档位滑块，两种调整卡片共用同一配置。
  Widget _sizeSlider() => Slider(
    key: const Key('player-control-size-slider'),
    padding: EdgeInsets.zero,
    value: _scale,
    min: PlaybackPreferences.minControlScale,
    max: PlaybackPreferences.maxControlScale,
    divisions:
        ((PlaybackPreferences.maxControlScale -
                    PlaybackPreferences.minControlScale) /
                0.05)
            .round(),
    label: '${(_scale * 100).round()}%',
    onChanged: _saving ? null : _changeScale,
  );

  /// 小横屏用一行保留滑块、比例和三个操作，给 200% 底栏留下可点击空间。
  Widget _compactAdjustment() => Row(
    children: [
      SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          key: const Key('reset-player-control-size'),
          tooltip: '恢复默认',
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : () => _changeScale(1),
          icon: const Icon(Icons.restore_rounded, size: 20),
        ),
      ),
      Expanded(child: _sizeSlider()),
      SizedBox(
        width: 40,
        child: Text(
          '${(_scale * 100).round()}%',
          key: const Key('player-control-size-value'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ),
      SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          tooltip: '取消',
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, size: 20),
        ),
      ),
      SizedBox(
        width: 36,
        height: 36,
        child: IconButton.filled(
          key: const Key('save-player-control-size'),
          tooltip: '保存',
          padding: EdgeInsets.zero,
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.check_rounded, size: 20),
        ),
      ),
    ],
  );

  /// 在画面中央空白处固定设置卡片，小横屏切为一行，调节时位置不移动。
  Widget _adjustmentPanel({required bool compact}) => Material(
    key: const Key('player-control-size-panel'),
    color: Theme.of(
      context,
    ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.97),
    elevation: 6,
    borderRadius: BorderRadius.circular(20),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: compact ? 4 : 10,
      ),
      child: compact
          ? _compactAdjustment()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '播放栏大小',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${(_scale * 100).round()}%',
                      key: const Key('player-control-size-value'),
                    ),
                  ],
                ),
                _sizeSlider(),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    TextButton(
                      key: const Key('reset-player-control-size'),
                      onPressed: _saving ? null : () => _changeScale(1),
                      child: const Text('恢复默认'),
                    ),
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('save-player-control-size'),
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '保存中' : '保存'),
                    ),
                  ],
                ),
              ],
            ),
    ),
  );

  /// 全屏按原尺寸铺开播放器界面，调整卡片悬浮且不占用上下控制栏的空间。
  @override
  Widget build(BuildContext context) {
    final size = PlayerControlSize(_scale);
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) => Stack(
          key: const Key('player-control-size-preview'),
          fit: StackFit.expand,
          children: [
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xff20232a),
                      Color(0xff101217),
                      Colors.black,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                bottom: false,
                minimum: const EdgeInsets.only(top: 2, left: 2, right: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '12:00  ·  Wi-Fi  ·  100%',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                    _topBar(size),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                child: _bottomBar(size),
              ),
            ),
            Positioned(
              left: 8,
              top:
                  size.sideControlCenter(constraints.maxHeight) -
                  24 * size.scale,
              child: SafeArea(
                right: false,
                child: Material(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(22),
                  child: IconButton(
                    key: const Key('preview-lock-button'),
                    iconSize: 24 * size.scale,
                    constraints: BoxConstraints.tightFor(
                      width: 48 * size.scale,
                      height: 48 * size.scale,
                    ),
                    style: IconButton.styleFrom(
                      fixedSize: Size.square(48 * size.scale),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => _previewNotice('锁定播放器'),
                    tooltip: '锁定播放器',
                    icon: const Icon(
                      Icons.lock_open_rounded,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment(0, size.sideControlAlignmentY),
                child: Material(
                  color: Colors.black.withValues(alpha: 0.58),
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    key: const Key('preview-note-button'),
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => _previewNotice('记笔记'),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12 * size.scale,
                        vertical: 9 * size.scale,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.edit_note_rounded,
                            color: Colors.white,
                            size: 20 * size.scale,
                          ),
                          SizedBox(width: 5 * size.scale),
                          Text(
                            '记笔记',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14 * size.scale,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: constraints.maxHeight <= 400
                  ? const Alignment(0, -0.35)
                  : Alignment.center,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.min(
                    320,
                    math.max(240, constraints.maxWidth - 400),
                  ),
                  maxHeight: math.max(120, constraints.maxHeight - 160),
                ),
                child: SingleChildScrollView(
                  child: _adjustmentPanel(
                    compact: constraints.maxHeight <= 400,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
