import 'dart:async';

import 'package:flutter/material.dart';
import '../../models/playback_preferences.dart';
import '../../platform/app_platform.dart';
import '../../services/playback_preferences_service.dart';
import '../player/widgets/player_action_feedback.dart';
import 'fullscreen_settings_preview.dart';

/// 打开真实全屏区域编辑器，结束后恢复手机方向、系统栏或桌面窗口状态。
Future<DoubleTapRegions?> showDoubleTapRegionsEditor({
  required BuildContext context,
  required DoubleTapRegions regions,
  required PlaybackPreferencesService service,
  required AppPlatform platform,
}) => showFullscreenSettingsPreview<DoubleTapRegions>(
  context: context,
  platform: platform,
  builder: (context) =>
      DoubleTapRegionsPage(regions: regions, service: service),
);

/// 拖动画面上的分割线调整区域，双击验证真实全屏的命中规则。
class DoubleTapRegionsPage extends StatefulWidget {
  /// 接收当前配置和保存服务；离开未保存时保留原设置。
  const DoubleTapRegionsPage({
    super.key,
    required this.regions,
    required this.service,
  });

  final DoubleTapRegions regions;
  final PlaybackPreferencesService service;

  /// 创建持有区域草稿和预览反馈的状态。
  @override
  State<DoubleTapRegionsPage> createState() => _DoubleTapRegionsPageState();
}

class _DoubleTapRegionsPageState extends State<DoubleTapRegionsPage> {
  late DoubleTapRegions _regions;
  Offset _tap = Offset.zero;
  Timer? _feedbackTimer;
  int _feedbackSequence = 0;
  int _seekSeconds = 0;
  bool _playing = false;
  bool _actionVisible = false;
  bool _saving = false;

  /// 复制已保存配置，防止编辑过程修改设置页的旧值。
  @override
  void initState() {
    super.initState();
    _regions = widget.regions.copyWith();
  }

  /// 退出预览时取消临时反馈，不影响实际播放服务。
  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  /// 应用拖动或滑块值，并马上重画区域边界。
  void _update(DoubleTapRegions regions) {
    if (!_saving) setState(() => _regions = regions.copyWith());
  }

  /// 用真实命中算法预览双击结果，同方向连续操作累计秒数。
  void _previewDoubleTap(Size size) {
    final action = _regions.actionAt(
      _tap.dx / size.width,
      _tap.dy / size.height,
    );
    final seconds = action == DoubleTapAction.forward ? 5 : -5;
    final accumulate =
        _feedbackTimer?.isActive == true && _seekSeconds.sign == seconds.sign;
    _feedbackTimer?.cancel();
    setState(() {
      _feedbackSequence++;
      _actionVisible = action == DoubleTapAction.togglePlayback;
      if (_actionVisible) {
        _playing = !_playing;
        _seekSeconds = 0;
      } else {
        _seekSeconds = accumulate ? _seekSeconds + seconds : seconds;
      }
    });
    _feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _seekSeconds = 0;
          _actionVisible = false;
        });
      }
    });
  }

  /// 一次写入完整草稿；保存失败留在编辑器供重试。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.service.saveDoubleTapRegions(_regions);
      if (mounted) Navigator.of(context).pop(_regions);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('区域保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保持高度分割线贴合真实边界，同时将 24 像素拖动范围留在屏幕内。
  Widget _heightHandle(Size size, double boundary, {required bool bottom}) {
    final handleTop = (boundary - 12).clamp(0.0, size.height - 24);
    return Positioned(
      left: size.width * 0.16,
      top: handleTop,
      width: size.width * 0.68,
      height: 24,
      child: GestureDetector(
        key: Key(bottom ? 'zone-bottom-height-handle' : 'zone-height-handle'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => _update(
          _regions.copyWith(
            height:
                _regions.height +
                details.delta.dy * (bottom ? 2 : -2) / size.height,
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Icon(
                Icons.unfold_more_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: (boundary - handleTop - 1.5).clamp(0.0, 21.0),
              height: 3,
              child: ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 绘制触发色块、可拖动边界和可试用的操作反馈。
  Widget _preview(Size size) {
    final colors = Theme.of(context).colorScheme;
    final top = size.height * (1 - _regions.height) / 2;
    final height = size.height * _regions.height;
    final left = size.width * _regions.leftWidth;
    final right = size.width * _regions.rightWidth;
    return GestureDetector(
      key: const Key('double-tap-region-preview'),
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: (details) => _tap = details.localPosition,
      onDoubleTap: () => _previewDoubleTap(size),
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: const Alignment(0, 0.55),
              child: Text(
                '播放 / 暂停',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            Positioned(
              left: 0,
              top: top,
              width: left,
              height: height,
              child: ColoredBox(
                key: const Key('rewind-trigger-zone'),
                color: colors.primary.withValues(alpha: 0.18),
                child: Align(
                  alignment: const Alignment(0, 0.55),
                  child: Text(
                    '快退 5 秒',
                    style: TextStyle(color: colors.onSurface),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: top,
              width: right,
              height: height,
              child: ColoredBox(
                key: const Key('forward-trigger-zone'),
                color: colors.primary.withValues(alpha: 0.28),
                child: Align(
                  alignment: const Alignment(0, 0.55),
                  child: Text(
                    '快进 5 秒',
                    style: TextStyle(color: colors.onSurface),
                  ),
                ),
              ),
            ),
            Positioned(
              left: left - 14,
              top: top,
              width: 28,
              height: height,
              child: GestureDetector(
                key: const Key('rewind-zone-handle'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => _update(
                  _regions.copyWith(
                    leftWidth:
                        _regions.leftWidth + details.delta.dx / size.width,
                  ),
                ),
                child: Center(
                  child: SizedBox(
                    width: 3,
                    height: double.infinity,
                    child: ColoredBox(
                      color: colors.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: right - 14,
              top: top,
              width: 28,
              height: height,
              child: GestureDetector(
                key: const Key('forward-zone-handle'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => _update(
                  _regions.copyWith(
                    rightWidth:
                        _regions.rightWidth - details.delta.dx / size.width,
                  ),
                ),
                child: Center(
                  child: SizedBox(
                    width: 3,
                    height: double.infinity,
                    child: ColoredBox(
                      color: colors.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
            _heightHandle(size, top, bottom: false),
            _heightHandle(size, top + height, bottom: true),
            if (_seekSeconds != 0)
              PlayerSeekFeedback(
                key: ValueKey('seek-$_feedbackSequence'),
                seconds: _seekSeconds,
              ),
            if (_actionVisible)
              PlayerActionFeedback(
                key: ValueKey('action-$_feedbackSequence'),
                playing: _playing,
              ),
          ],
        ),
      ),
    );
  }

  /// 把标题、比例和保存操作悬浮到靠内的空白处，不挤占触发区视口。
  Widget _adjustmentPanel() => Material(
    key: const Key('double-tap-regions-panel'),
    color: Theme.of(
      context,
    ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.96),
    elevation: 4,
    borderRadius: BorderRadius.circular(20),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('自定义双击触发区', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '拖动画面上的分割线来调节 · 双击试用',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '左 ${(100 * _regions.leftWidth).round()}% · 右 ${(100 * _regions.rightWidth).round()}% · 高 ${(100 * _regions.height).round()}%',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 12,
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
              TextButton(
                key: const Key('reset-double-tap-regions'),
                onPressed: _saving
                    ? null
                    : () => _update(const DoubleTapRegions()),
                child: const Text('恢复默认'),
              ),
              FilledButton(
                key: const Key('save-double-tap-regions'),
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中' : '保存'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  /// 以整个屏幕计算触发区域，主题配色与设置页一致，操作卡片仅悬浮叠加。
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    body: LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          _preview(constraints.biggest),
          Align(
            alignment: const Alignment(0, -0.65),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (constraints.maxWidth - 96).clamp(240, 360),
                maxHeight: constraints.maxHeight * 0.6,
              ),
              child: SingleChildScrollView(child: _adjustmentPanel()),
            ),
          ),
        ],
      ),
    ),
  );
}
