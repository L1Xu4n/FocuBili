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

const _seekAnimationDuration = Duration(milliseconds: 1100);
const _seekTextSize = 14.0;

Alignment _seekAlignment(int seconds) =>
    seconds > 0 ? Alignment.centerRight : Alignment.centerLeft;

double _seekOpacity(double progress) => (1 - (progress - .7) / .3).clamp(0, 1);

/// Shares one animation across the real player's picture and safe feedback lane.
class PlayerSeekFeedbackClock extends StatefulWidget {
  const PlayerSeekFeedbackClock({
    super.key,
    required this.sequence,
    required this.child,
  });

  final int sequence;
  final Widget child;

  static Animation<double>? _of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_PlayerSeekAnimationScope>()
      ?.animation;

  @override
  State<PlayerSeekFeedbackClock> createState() =>
      _PlayerSeekFeedbackClockState();
}

class _PlayerSeekFeedbackClockState extends State<PlayerSeekFeedbackClock>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: _seekAnimationDuration,
    value: 1,
  );

  @override
  void didUpdateWidget(covariant PlayerSeekFeedbackClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sequence != oldWidget.sequence) _animation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) =>
      _PlayerSeekAnimationScope(animation: _animation, child: widget.child);

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }
}

class _PlayerSeekAnimationScope extends InheritedWidget {
  const _PlayerSeekAnimationScope({
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_PlayerSeekAnimationScope oldWidget) =>
      animation != oldWidget.animation;
}

/// The decorative side band follows the whole picture, like the settings preview.
class PlayerSeekBackdrop extends StatelessWidget {
  const PlayerSeekBackdrop({super.key, required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    final animation = PlayerSeekFeedbackClock._of(context);
    if (animation == null) return _SeekBackdrop(seconds: seconds);
    return AnimatedBuilder(
      animation: animation,
      child: _SeekBackdrop(seconds: seconds),
      builder: (context, child) =>
          Opacity(opacity: _seekOpacity(animation.value), child: child),
    );
  }
}

class _SeekBackdrop extends StatelessWidget {
  const _SeekBackdrop({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth * PlayerSeekFeedback.bandWidthFactor;
        final height = constraints.maxHeight;
        return Align(
          alignment: _seekAlignment(seconds),
          child: SizedBox(
            width: width,
            height: height,
            child: DecoratedBox(
              key: const Key('double-tap-seek-backdrop'),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .28),
                borderRadius: BorderRadius.horizontal(
                  left: seconds > 0
                      ? Radius.elliptical(width, height)
                      : Radius.zero,
                  right: seconds < 0
                      ? Radius.elliptical(width, height)
                      : Radius.zero,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// 在快进或快退对应的一侧显示流动三角形和本轮累计跳转时间。
class PlayerSeekFeedback extends StatelessWidget {
  const PlayerSeekFeedback({
    super.key,
    required this.seconds,
    this.foregroundOnly = false,
    this.fillWidth = false,
  });

  static const bandWidthFactor = .42;

  final int seconds;
  final bool foregroundOnly;
  final bool fillWidth;

  Widget _glyphs(BuildContext context, double progress) => Align(
    alignment: _seekAlignment(seconds),
    child: FractionallySizedBox(
      widthFactor: fillWidth ? 1 : bandWidthFactor,
      heightFactor: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = MediaQuery.textScalerOf(
            context,
          ).scale(_seekTextSize);
          // A portrait player's safe lane may only have room for one line.
          // Keep the arrows proportional; arrange them beside the label rather
          // than reducing the whole two-line composition to a tiny replica.
          final oneLine =
              foregroundOnly &&
              constraints.maxHeight < 28 + 8 + fontSize * 1.35;
          final triangles = CustomPaint(
            size: oneLine ? const Size(40, 28 * 40 / 96) : const Size(96, 28),
            painter: _MovingTrianglesPainter(
              progress: progress,
              forward: seconds > 0,
            ),
          );
          final label = Text(
            '${seconds > 0 ? '快进' : '快退'} ${seconds.abs()} 秒',
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontSize: _seekTextSize,
              fontWeight: FontWeight.w600,
            ),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: FittedBox(
                key: const Key('double-tap-seek-glyphs'),
                fit: BoxFit.scaleDown,
                child: oneLine
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (seconds > 0) ...[label, const SizedBox(width: 4)],
                          triangles,
                          if (seconds < 0) ...[const SizedBox(width: 4), label],
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [triangles, const SizedBox(height: 8), label],
                      ),
              ),
            ),
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    Widget frame(double progress) => IgnorePointer(
      child: Opacity(
        opacity: _seekOpacity(progress),
        child: foregroundOnly
            ? _glyphs(context, progress)
            : Stack(
                fit: StackFit.expand,
                children: [
                  _SeekBackdrop(seconds: seconds),
                  _glyphs(context, progress),
                ],
              ),
      ),
    );
    final animation = PlayerSeekFeedbackClock._of(context);
    if (animation != null) {
      return AnimatedBuilder(
        animation: animation,
        builder: (context, _) => frame(animation.value),
      );
    }
    // Settings uses the same composition without splitting its two layers.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: _seekAnimationDuration,
      builder: (context, progress, _) => frame(progress),
    );
  }
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
    canvas.scale(size.width / 96, size.height / 28);
    if (!forward) {
      canvas.translate(96, 0);
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
