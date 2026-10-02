import 'package:flutter/material.dart';
import 'player_control_widgets.dart';

/// 顶栏空间不足时将右侧操作换到下一行，放大按钮不会压出画面。
class PlayerTopControlBar extends StatelessWidget {
  /// 接收返回按钮、可选标题和操作按钮的实际总宽度。
  const PlayerTopControlBar({
    super.key,
    required this.leading,
    required this.actions,
    required this.actionsWidth,
    this.title,
    this.scale = 1,
  });
  final Widget leading;
  final Widget? title;
  final List<Widget> actions;
  final double actionsWidth;
  final double scale;

  /// 根据尺寸决定一行排列或拆为两行，标题始终保留可用空间。
  @override
  Widget build(BuildContext context) {
    final size = PlayerControlSize(scale);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fits =
            constraints.maxWidth >=
            size.button + actionsWidth + (title == null ? 0 : 64 * size.scale);
        if (fits) {
          return Row(
            children: [
              leading,
              Expanded(child: title ?? const SizedBox.shrink()),
              ...actions,
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                leading,
                if (title != null) Expanded(child: title!),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(alignment: WrapAlignment.end, children: actions),
            ),
          ],
        );
      },
    );
  }
}

/// 按实际控件宽度排列两组操作，窄屏或大字模式下自然增加行数。
class PlayerControlGroups extends StatelessWidget {
  /// 接收播放与时间操作组，以及选集、清晰度、倍速和全屏操作组。
  const PlayerControlGroups({
    super.key,
    required this.playbackControls,
    required this.displayControls,
  });

  final List<Widget> playbackControls;
  final List<Widget> displayControls;

  /// 在宽屏两端对齐两组，空间不足时换行并允许组内再次安全换行。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Wrap(
            key: const Key('player-playback-control-group'),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: playbackControls,
          ),
          Wrap(
            key: const Key('player-display-control-group'),
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 标签内部的 Center 在有限宽度下会扩张；按自然宽度约束后才能准确换行。
              for (final control in displayControls)
                IntrinsicWidth(child: control),
            ],
          ),
        ],
      ),
    );
  }
}
