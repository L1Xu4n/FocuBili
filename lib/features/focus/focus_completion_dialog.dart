import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/focus_session.dart';
import '../../services/focus_notification_service.dart';
import 'focus_share_preview.dart';

/// 显示专注完成庆祝弹窗，返回用户选择的续时时长或空值。
Future<Duration?> showFocusCompletionDialog(
  BuildContext context,
  FocusSession session,
) {
  return showDialog<Duration>(
    context: context,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (BuildContext dialogContext) =>
        _FocusCompletionDialog(session: session),
  );
}

/// 展示完成目标、礼花小动画和继续五分钟操作。
class _FocusCompletionDialog extends StatefulWidget {
  /// 创建一次专注完成弹窗。
  const _FocusCompletionDialog({required this.session});

  final FocusSession session;

  /// 创建驱动礼花动画的状态。
  @override
  State<_FocusCompletionDialog> createState() => _FocusCompletionDialogState();
}

/// 管理一次性全屏礼花动画，弹窗关闭时自动释放动画控制器。
class _FocusCompletionDialogState extends State<_FocusCompletionDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 启动一整幕同时从顶部落下的礼花，并触发震动和用户提供的完成音效。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..forward();
    unawaited(HapticFeedback.mediumImpact());
    unawaited(const FocusNotificationService().playCelebrationSound());
  }

  /// 构建礼花、完成说明和续时按钮。
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              key: const Key('focus-completion-confetti'),
              animation: _controller,
              // 礼花构建函数让整幕彩片同时从全屏顶部落到底部。
              builder: (BuildContext context, Widget? child) => CustomPaint(
                painter: _ConfettiPainter(progress: _controller.value),
              ),
            ),
          ),
        ),
        Center(
          child: SafeArea(
            child: AlertDialog(
              icon: const Text('🎉', style: TextStyle(fontSize: 38)),
              title: const Text('专注已结束，做得好！'),
              content: Text(
                '你完成了“${widget.session.goal}”\n'
                '本次专注 ${widget.session.plannedDuration.inMinutes} 分钟。',
                textAlign: TextAlign.center,
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: <Widget>[
                TextButton.icon(
                  key: const Key('share-completed-focus'),
                  // 分享函数保留完成弹窗，并在其上方打开本地生成的分享预览。
                  onPressed: () => unawaited(
                    showFocusSessionSharePreview(context, widget.session),
                  ),
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('分享'),
                ),
                TextButton(
                  key: const Key('finish-focus-celebration'),
                  // 完成函数关闭庆祝弹窗，记录继续保留在统计中。
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
                FilledButton.icon(
                  key: const Key('extend-completed-focus'),
                  // 续时函数返回五分钟，由根控制器重新打开同一任务。
                  onPressed: () =>
                      Navigator.of(context).pop(const Duration(minutes: 5)),
                  icon: const Icon(Icons.more_time_rounded),
                  label: const Text('再专注 5 分钟'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 弹窗移除后停止并释放动画控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// 使用 Canvas 绘制从屏幕顶部飘落的彩色礼花片。
class _ConfettiPainter extends CustomPainter {
  /// 创建指定动画进度的一帧礼花。
  const _ConfettiPainter({required this.progress});

  final double progress;

  static const List<Color> _colors = <Color>[
    Colors.redAccent,
    Colors.amber,
    Colors.lightBlueAccent,
    Colors.greenAccent,
    Colors.purpleAccent,
  ];

  /// 根据短延迟绘制 120 片全宽礼花，避免按批次循环形成分段下落。
  @override
  void paint(Canvas canvas, Size size) {
    const int particleCount = 120;
    for (int index = 0; index < particleCount; index += 1) {
      final double delay = (index % 5) * 0.025;
      final double phase = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (progress < delay || phase >= 1) {
        continue;
      }
      final double baseX = ((index * 47) % particleCount) / particleCount;
      final double sway = math.sin(phase * math.pi * 3 + index) * 18;
      final double x = baseX * size.width + sway;
      final double fallProgress = Curves.easeIn.transform(phase);
      final double y = -30 + fallProgress * (size.height + 70);
      final double width = 4 + (index % 3) * 2;
      final double height = 8 + (index % 4) * 2;
      final Paint paint = Paint()
        ..color = _colors[index % _colors.length].withValues(alpha: 0.9);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(phase * math.pi * 5 + index * 0.4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: width, height: height),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  /// 动画进度变化时请求下一帧礼花。
  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
