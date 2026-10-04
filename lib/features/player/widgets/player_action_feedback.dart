import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放或暂停标志从大到小淡出，整个反馈层不接收指针事件。
class PlayerActionFeedback extends StatelessWidget {
  /// 创建一次播放状态变化的反馈；父级用不同 key 重启动画。
  const PlayerActionFeedback({super.key, required this.playing});

  final bool playing;

  /// 把包含最大缩放帧的完整画布适配到父级，避免小播放器裁切动画边缘。
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.square(
          dimension: 120,
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, progress, child) => Opacity(
                opacity: (1 - (progress - 0.35) / 0.65).clamp(0, 1),
                child: Transform.scale(
                  scale: 1.5 - progress * 0.85,
                  child: child,
                ),
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

  /// 按实际可用宽高缩小内容，紧凑提示限制背景宽度，避免桌面窗口放大空白。
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          constraints.maxWidth * 0.42,
          compact ? 220.0 : double.infinity,
        );
        final height = compact
            ? math.min(constraints.maxHeight, 72.0)
            : constraints.maxHeight;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 1100),
          builder: (context, progress, child) => Opacity(
            opacity: (1 - (progress - 0.7) / 0.3).clamp(0, 1),
            child: Align(
              alignment: seconds > 0
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: SizedBox(
                width: width,
                height: height.isFinite ? height : null,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.horizontal(
                      left: seconds > 0
                          ? Radius.elliptical(
                              width,
                              height.isFinite ? height : 72,
                            )
                          : Radius.zero,
                      right: seconds < 0
                          ? Radius.elliptical(
                              width,
                              height.isFinite ? height : 72,
                            )
                          : Radius.zero,
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: math.min(8, width / 8),
                      vertical: compact ? math.min(8, height / 8) : 0,
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
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
      },
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
