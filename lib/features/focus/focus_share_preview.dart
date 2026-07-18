import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/focus_session.dart';
import '../../models/focus_statistics.dart';
import '../../services/focus_share_service.dart';
import 'focus_timer_controller.dart';
import 'focus_timer_scope.dart';

/// 打开单次专注分享预览，用户确认后才调用系统分享面板。
Future<void> showFocusSessionSharePreview(
  BuildContext context,
  FocusSession session,
) {
  final FocusTimerController? controller = FocusTimerScope.maybeOf(context);
  final Duration fallbackDuration =
      session.accumulatedFocusDuration > Duration.zero
      ? session.accumulatedFocusDuration
      : session.plannedDuration;
  final FocusStatisticsSnapshot? completeSnapshot = controller == null
      ? null
      : FocusStatisticsCalculator.build(
          history: controller.history,
          range: FocusStatisticsRange.all,
          now: DateTime.now(),
          activeSession: controller.activeSession,
        );
  return showDialog<void>(
    context: context,
    // 分享预览构建函数使用固定设计卡片，保证不同手机生成相同画面比例。
    builder: (BuildContext dialogContext) => _FocusSharePreviewDialog(
      fileName: 'focubili_focus_${session.id}',
      shareText: '我在焦点哔哩完成了“${session.goal}”专注任务。',
      card: FocusSessionShareCard(
        session: session,
        todayFocusedDuration:
            controller?.todayFocusedDuration() ?? fallbackDuration,
        cumulativeFocusedDuration:
            completeSnapshot?.totalFocusedDuration ?? fallbackDuration,
      ),
    ),
  );
}

/// 打开专注统计分享预览，分享内容只使用调用时生成的本地快照。
Future<void> showFocusStatisticsSharePreview(
  BuildContext context,
  FocusStatisticsSnapshot snapshot,
) {
  return showDialog<void>(
    context: context,
    // 统计预览构建函数冻结当前范围数据，分享过程中记录变化不会改变画面。
    builder: (BuildContext dialogContext) => _FocusSharePreviewDialog(
      fileName: 'focubili_focus_statistics',
      shareText: '这是我在焦点哔哩的专注统计。',
      card: FocusStatisticsShareCard(snapshot: snapshot),
    ),
  );
}

/// 展示可缩放预览、关闭和系统分享按钮。
class _FocusSharePreviewDialog extends StatefulWidget {
  /// 创建一张不会直接上传的本地分享预览。
  const _FocusSharePreviewDialog({
    required this.card,
    required this.fileName,
    required this.shareText,
  });

  final Widget card;
  final String fileName;
  final String shareText;

  /// 创建负责图片捕获和分享状态的对话框状态。
  @override
  State<_FocusSharePreviewDialog> createState() =>
      _FocusSharePreviewDialogState();
}

/// 管理 RepaintBoundary、分享进度和错误提示。
class _FocusSharePreviewDialogState extends State<_FocusSharePreviewDialog> {
  final GlobalKey _boundaryKey = GlobalKey();
  final FocusShareService _shareService = const FocusShareService();
  bool _sharing = false;

  /// 捕获卡片并打开系统分享；异常会保留预览并提示重试。
  Future<void> _share() async {
    if (_sharing) {
      return;
    }
    setState(() => _sharing = true);
    try {
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      final Rect? origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await _shareService.shareBoundary(
        boundaryKey: _boundaryKey,
        fileName: widget.fileName,
        text: widget.shareText,
        sharePositionOrigin: origin,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('分享图片生成失败，请稍后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _sharing = false);
      }
    }
  }

  /// 创建带高清捕获边界的预览，屏幕较小时只缩放显示而不降低输出尺寸。
  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('分享预览', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    // 关闭按钮函数只移除预览，不保存或分享图片。
                    onPressed: _sharing
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: RepaintBoundary(
                      key: _boundaryKey,
                      child: widget.card,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('share-focus-card'),
                  // 分享按钮函数把预览渲染为 PNG 后打开系统 App 列表。
                  onPressed: _sharing ? null : () => unawaited(_share()),
                  icon: _sharing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  label: Text(_sharing ? '正在生成…' : '分享到其他 App'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 生成单次专注完成卡，左上角固定展示焦点哔哩品牌标识。
class FocusSessionShareCard extends StatelessWidget {
  /// 创建读取已结束专注记录的分享卡。
  const FocusSessionShareCard({
    super.key,
    required this.session,
    this.todayFocusedDuration,
    this.cumulativeFocusedDuration,
  });

  final FocusSession session;
  final Duration? todayFocusedDuration;
  final Duration? cumulativeFocusedDuration;

  /// 创建深色渐变、目标、完成时长和关联视频组成的固定尺寸卡片。
  @override
  Widget build(BuildContext context) {
    final Duration focused = session.accumulatedFocusDuration > Duration.zero
        ? session.accumulatedFocusDuration
        : session.plannedDuration;
    final Duration today = todayFocusedDuration ?? focused;
    final Duration cumulative = cumulativeFocusedDuration ?? focused;
    return _FocusShareCanvas(
      height: 520,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _ShareBrandHeader(kicker: 'FOCUS COMPLETED'),
          const Spacer(),
          const Icon(
            Icons.auto_awesome_rounded,
            color: Color(0xFFFFD166),
            size: 42,
          ),
          const SizedBox(height: 18),
          const Text(
            '今天，也认真完成了一件事。',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 15,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            session.goal,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              height: 1.18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              _ShareMetric(label: '今日专注时长', value: _formatShareDuration(today)),
              const SizedBox(width: 12),
              _ShareMetric(
                label: '累计专注时长',
                value: _formatShareDuration(cumulative),
              ),
            ],
          ),
          if (session.sourceVideoTitle?.isNotEmpty == true) ...<Widget>[
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Text(
                '关联视频 · ${session.sourceVideoTitle}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            _formatShareDate(session.finishedAt ?? session.startedAt),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 生成统计快照分享卡，突出总时长、完成率、连续天数和趋势。
class FocusStatisticsShareCard extends StatelessWidget {
  /// 创建只依赖不可变统计快照的分享卡。
  const FocusStatisticsShareCard({super.key, required this.snapshot});

  final FocusStatisticsSnapshot snapshot;

  /// 创建固定尺寸统计卡，折线图会自适应当前范围的数据点数量。
  @override
  Widget build(BuildContext context) {
    return _FocusShareCanvas(
      height: 660,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _ShareBrandHeader(kicker: _rangeLabel(snapshot.range)),
          const SizedBox(height: 34),
          const Text(
            '我的专注足迹',
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '每一次投入，都在让目标变得更清晰。',
            style: TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              _ShareMetric(
                width: 142,
                label: '专注总时长',
                value: _formatShareDuration(snapshot.totalFocusedDuration),
              ),
              _ShareMetric(
                width: 142,
                label: '按时完成率',
                value: '${(snapshot.completionRate * 100).round()}%',
              ),
              _ShareMetric(
                width: 142,
                label: '投入天数',
                value: '${snapshot.focusDayCount} 天',
              ),
              _ShareMetric(
                width: 142,
                label: '连续专注',
                value: '${snapshot.currentStreakDays} 天',
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  snapshot.range == FocusStatisticsRange.all
                      ? '近 30 天专注趋势'
                      : '专注趋势',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 124,
                  child: Semantics(
                    label: '专注趋势图，纵轴为专注时长，横轴为日期',
                    image: true,
                    child: CustomPaint(
                      painter: _ShareTrendPainter(snapshot.dailyTrend),
                      size: const Size(double.infinity, 124),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Text(
            '完成 ${snapshot.completedCount} 次  ·  打断 ${snapshot.interruptionCount} 次  ·  关联视频 ${snapshot.linkedVideoCount} 个',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 提供两种分享卡共用的渐变背景、装饰光斑和内边距。
class _FocusShareCanvas extends StatelessWidget {
  /// 创建固定宽高的可捕获画布。
  const _FocusShareCanvas({required this.height, required this.child});

  final double height;
  final Widget child;

  /// 绘制深蓝紫渐变，并把内容放在不会被圆角裁切的安全范围内。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color(0xFF111A3A),
                Color(0xFF223A75),
                Color(0xFF4F3A78),
              ],
            ),
          ),
          child: Stack(
            children: <Widget>[
              const Positioned(
                top: -70,
                right: -55,
                child: _GlowCircle(size: 190, color: Color(0x334FC3F7)),
              ),
              const Positioned(
                bottom: -85,
                left: -70,
                child: _GlowCircle(size: 210, color: Color(0x33FF8A65)),
              ),
              Padding(padding: const EdgeInsets.all(26), child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 展示卡片左上角 Logo、应用名和当前卡片类型。
class _ShareBrandHeader extends StatelessWidget {
  /// 创建品牌标题行。
  const _ShareBrandHeader({required this.kicker});

  final String kicker;

  /// 组合应用图标、焦点哔哩名称和小型英文标记。
  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset(
            'assets/icon/focubili_icon.png',
            width: 38,
            height: 38,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 11),
        const Expanded(
          child: Text(
            '焦点哔哩',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          kicker,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
      ],
    );
  }
}

/// 展示分享卡中的一个半透明指标块。
class _ShareMetric extends StatelessWidget {
  /// 创建标签和值组成的指标块。
  const _ShareMetric({
    required this.label,
    required this.value,
    this.width = 145,
  });

  final String label;
  final String value;
  final double width;

  /// 创建半透明圆角指标布局。
  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// 绘制分享卡内带自适应日期与完整时长纵轴的简洁专注趋势线。
class _ShareTrendPainter extends CustomPainter {
  /// 创建读取逐日趋势的画笔。
  const _ShareTrendPainter(this.trend);

  final List<FocusDailyStatistic> trend;

  /// 按卡片宽度等距绘制折线和底部淡色填充，不绘制数据圆点。
  @override
  void paint(Canvas canvas, Size size) {
    if (trend.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }
    final int maximum = trend.fold<int>(
      0,
      (int value, FocusDailyStatistic item) =>
          item.focusedDuration.inMilliseconds > value
          ? item.focusedDuration.inMilliseconds
          : value,
    );
    final int verticalStepMinutes = _shareTrendAxisStepMinutes(maximum);
    final int verticalMaximumMinutes = verticalStepMinutes * 3;
    const TextStyle labelStyle = TextStyle(
      color: Color(0x99FFFFFF),
      fontSize: 7,
    );
    final TextPainter widestVerticalLabel = TextPainter(
      text: TextSpan(
        text: _formatShareAxisDuration(verticalMaximumMinutes),
        style: labelStyle,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final Rect chart = Rect.fromLTRB(
      widestVerticalLabel.width + 7,
      3,
      size.width - 2,
      size.height - 19,
    );
    final Paint gridPaint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 0.7;
    for (int row = 0; row <= 3; row += 1) {
      final double y = chart.top + chart.height * row / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      final int minutes = verticalMaximumMinutes - verticalStepMinutes * row;
      final TextPainter labelPainter = TextPainter(
        text: TextSpan(
          text: _formatShareAxisDuration(minutes),
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      labelPainter.paint(
        canvas,
        Offset(
          chart.left - labelPainter.width - 4,
          y - labelPainter.height / 2,
        ),
      );
    }
    final List<Offset> points = List<Offset>.generate(trend.length, (
      int index,
    ) {
      final double x = trend.length == 1
          ? chart.center.dx
          : chart.left + chart.width * index / (trend.length - 1);
      final double ratio =
          trend[index].focusedDuration.inMilliseconds /
          Duration(minutes: verticalMaximumMinutes).inMilliseconds;
      return Offset(x, chart.bottom - ratio * chart.height);
    }, growable: false);
    final Path line = Path()..moveTo(points.first.dx, points.first.dy);
    for (final Offset point in points.skip(1)) {
      line.lineTo(point.dx, point.dy);
    }
    final Path area = Path.from(line)
      ..lineTo(points.last.dx, chart.bottom)
      ..lineTo(points.first.dx, chart.bottom)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x66AFCBFF), Color(0x00AFCBFF)],
        ).createShader(chart),
    );
    final Paint linePaint = Paint()
      ..color = const Color(0xFFAFCBFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(line, linePaint);
    final List<int> dateIndexes = _shareAdaptiveDateLabelIndexes(
      itemCount: trend.length,
      availableWidth: chart.width,
    );
    for (final int index in dateIndexes) {
      final DateTime date = trend[index].date;
      final TextPainter datePainter = TextPainter(
        text: TextSpan(text: '${date.month}/${date.day}', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final double x = (points[index].dx - datePainter.width / 2).clamp(
        chart.left,
        chart.right - datePainter.width,
      );
      datePainter.paint(canvas, Offset(x, chart.bottom + 5));
    }
  }

  /// 趋势列表对象变化时重新绘制分享图。
  @override
  bool shouldRepaint(covariant _ShareTrendPainter oldDelegate) {
    return oldDelegate.trend != trend;
  }
}

/// 返回分享图三等分纵轴使用的易读分钟步长。
int _shareTrendAxisStepMinutes(int maximumMilliseconds) {
  final int maximumMinutes = maximumMilliseconds <= 0
      ? 1
      : (maximumMilliseconds / Duration.millisecondsPerMinute).ceil();
  final int target = (maximumMinutes / 3).ceil();
  const List<int> preferred = <int>[
    1,
    2,
    5,
    10,
    15,
    20,
    30,
    60,
    120,
    180,
    240,
    360,
    480,
    720,
    1440,
  ];
  for (final int value in preferred) {
    if (value >= target) {
      return value;
    }
  }
  return ((target / 1440).ceil()) * 1440;
}

/// 把分享图纵轴分钟值格式化为紧凑时长。
String _formatShareAxisDuration(int minutes) {
  if (minutes == 0) {
    return '0';
  }
  if (minutes < 60) {
    return '$minutes 分';
  }
  if (minutes % 60 == 0) {
    return '${minutes ~/ 60} 时';
  }
  return '${(minutes / 60).toStringAsFixed(1)} 时';
}

/// 分享图按实际宽度抽样日期，范围变长时不会把每一天都塞进横轴。
List<int> _shareAdaptiveDateLabelIndexes({
  required int itemCount,
  required double availableWidth,
}) {
  if (itemCount <= 0) {
    return const <int>[];
  }
  if (itemCount == 1) {
    return const <int>[0];
  }
  final int maximumLabels = (availableWidth / 36).floor().clamp(2, itemCount);
  final int step = ((itemCount - 1) / (maximumLabels - 1)).ceil();
  final List<int> indexes = <int>[
    for (int index = 0; index < itemCount; index += step) index,
  ];
  if (indexes.last != itemCount - 1) {
    indexes.add(itemCount - 1);
  }
  return indexes;
}

/// 绘制分享卡背景中的柔和装饰圆形。
class _GlowCircle extends StatelessWidget {
  /// 创建指定大小和颜色的光斑。
  const _GlowCircle({required this.size, required this.color});

  final double size;
  final Color color;

  /// 创建不响应触摸的圆形色块。
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 把时长转为分享卡使用的小时或分钟文字。
String _formatShareDuration(Duration value) {
  if (value.inMinutes >= 60) {
    final double hours = value.inMinutes / 60;
    return '${hours.toStringAsFixed(hours == hours.roundToDouble() ? 0 : 1)} 小时';
  }
  return '${value.inMinutes} 分钟';
}

/// 把日期转为不受系统语言影响的年月日文字。
String _formatShareDate(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.year} 年 ${local.month} 月 ${local.day} 日';
}

/// 返回统计范围在分享卡右上角显示的英文标记。
String _rangeLabel(FocusStatisticsRange range) {
  return switch (range) {
    FocusStatisticsRange.sevenDays => 'LAST 7 DAYS',
    FocusStatisticsRange.thirtyDays => 'LAST 30 DAYS',
    FocusStatisticsRange.all => 'ALL TIME',
  };
}
