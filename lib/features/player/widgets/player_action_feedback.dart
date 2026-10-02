import 'package:flutter/material.dart';

/// 播放或暂停标志从大到小淡出，整个反馈层不接收指针事件。
class PlayerActionFeedback extends StatelessWidget {
  /// 创建一次播放状态变化的反馈；父级用不同 key 重启动画。
  const PlayerActionFeedback({super.key, required this.playing});

  final bool playing;

  /// 在 650 毫秒内缩小图标，并在后半段完全淡出。
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
        builder: (context, progress, child) => Opacity(
          opacity: (1 - (progress - 0.35) / 0.65).clamp(0, 1),
          child: Transform.scale(scale: 1.5 - progress * 0.85, child: child),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(
              playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
              color: Colors.white,
              size: 52,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 在快进或快退对应的一侧显示流动三角形和本轮累计跳转时间。
class PlayerSeekFeedback extends StatelessWidget {
  /// 创建侧边跳转反馈；正秒数向右，负秒数向左。
  const PlayerSeekFeedback({
    super.key,
    required this.seconds,
    this.compact = false,
  });

  final int seconds;
  final bool compact;

  /// 使用一次有限动画反馈操作，不遮挡点击，也不常驻运行帧动画。
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1100),
      builder: (context, progress, child) => Opacity(
        opacity: (1 - (progress - 0.7) / 0.3).clamp(0, 1),
        child: Align(
          alignment: seconds > 0 ? Alignment.centerRight : Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 0.42,
            heightFactor: compact ? null : 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                borderRadius: BorderRadius.horizontal(
                  left: seconds > 0
                      ? const Radius.elliptical(220, 400)
                      : Radius.zero,
                  right: seconds < 0
                      ? const Radius.elliptical(220, 400)
                      : Radius.zero,
                ),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: compact ? 8 : 0),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CustomPaint(
                        size: const Size(96, 28),
                        painter: _MovingTrianglesPainter(
                          progress: progress,
                          forward: seconds > 0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${seconds > 0 ? '快进' : '快退'} ${seconds.abs()} 秒',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 绘制三个顺序流动的方向三角形，方向变化时直接镜像画布。
class _MovingTrianglesPainter extends CustomPainter {
  /// 保存本帧动画进度和跳转方向。
  const _MovingTrianglesPainter({
    required this.progress,
    required this.forward,
  });

  final double progress;
  final bool forward;

  /// 按顺序改变三角形透明度并向目标方向平移，形成连续流动感。
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (!forward) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    for (var index = 0; index < 3; index++) {
      final phase = (progress * 2.5 - index * 0.18) % 1;
      final x = 8 + index * 24 + phase * 12;
      final path = Path()
        ..moveTo(x, 3)
        ..lineTo(x + 17, 14)
        ..lineTo(x, 25)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.25 + (1 - phase) * 0.75),
      );
    }
    canvas.restore();
  }

  /// 只有动画帧或方向改变时重新绘制。
  @override
  bool shouldRepaint(_MovingTrianglesPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.forward != forward;
}
