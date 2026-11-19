import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/focus_session.dart';
import '../../models/focus_statistics.dart';

const _paper = Color(0xfff5f2e9);
const _ink = Color(0xff142e47);
const _muted = Color(0xff465f71);
const _blue = Color(0xff204baa);
const _cool = Color(0xffc5dff9);
const _orange = Color(0xffffaa79);

/// The alternate artwork uses a fixed 3:4 canvas, independent of the
/// surrounding dialog's theme, constraints, and user text scaling.
class _RulerCanvas extends StatelessWidget {
  const _RulerCanvas({
    required this.date,
    required this.title,
    required this.durationLabel,
    required this.duration,
    required this.panelTitle,
    required this.panel,
    required this.metrics,
    this.video,
  });

  static const double height = 480;
  final String? date;
  final String title;
  final String durationLabel;
  final Duration duration;
  final String panelTitle;
  final Widget panel;
  final List<({String label, String value})> metrics;
  final String? video;

  @override
  Widget build(BuildContext context) => MediaQuery.withNoTextScaling(
    child: DefaultTextStyle(
      style: TextStyle(
        color: _ink,
        fontSize: 12,
        fontFamily: DefaultTextStyle.of(context).style.fontFamily,
      ),
      child: SizedBox(
        width: 360,
        height: height,
        child: ColoredBox(
          color: _paper,
          child: Stack(
            children: [
              Positioned(
                left: 24,
                right: 24,
                top: 18,
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: Image.asset(
                        'assets/icon/focubili_icon.png',
                        width: 23,
                        height: 23,
                      ),
                    ),
                    const SizedBox(width: 7),
                    const Text(
                      '焦点哔哩',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      '专注刻度',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Positioned(
                left: 24,
                right: 24,
                top: 52,
                child: ColoredBox(color: _ink, child: SizedBox(height: .65)),
              ),
              if (date case final date?)
                Positioned(
                  left: 24,
                  top: 67,
                  child: Row(
                    children: [
                      const ColoredBox(
                        color: _blue,
                        child: SizedBox(width: 3, height: 8),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        date,
                        style: const TextStyle(
                          fontSize: 9,
                          color: _muted,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              Positioned(
                top: 89,
                left: 24,
                right: 24,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 25,
                    height: 1.22,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'serif',
                    fontFamilyFallback: [
                      'Noto Serif CJK SC',
                      'Songti SC',
                      'SimSun',
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 126,
                left: 24,
                child: Text(
                  durationLabel,
                  style: const TextStyle(color: _muted, fontSize: 10),
                ),
              ),
              Positioned(
                left: 24,
                top: 143,
                width: 218,
                height: 55,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        for (final part in _durationParts(duration)) ...[
                          TextSpan(
                            text: part.value,
                            style: const TextStyle(
                              fontSize: 56,
                              height: 1,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -2.5,
                            ),
                          ),
                          TextSpan(
                            text: ' ${part.unit}  ',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ],
                    ),
                    style: const TextStyle(
                      color: _blue,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const Positioned(
                right: 31,
                top: 123,
                width: 88,
                height: 71,
                child: CustomPaint(painter: _RulerMark()),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 208,
                height: 165,
                child: ColoredBox(
                  color: _blue,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 13),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          panelTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(child: panel),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                top: video == null ? 402 : 390,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, metric) in metrics.indexed) ...[
                      if (i > 0)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: ColoredBox(
                            color: Color(0xffb5c5d2),
                            child: SizedBox(width: .65, height: 39),
                          ),
                        ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: _RulerMetric(
                            label: metric.label,
                            value: metric.value,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (video case final title?)
                Positioned(
                  left: 24,
                  right: 24,
                  top: 443,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ColoredBox(
                        color: _ink,
                        child: SizedBox(width: double.infinity, height: .65),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '关联视频：$title',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 9),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RulerMetric extends StatelessWidget {
  const _RulerMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 9)),
      const SizedBox(height: 3),
      FittedBox(
        alignment: Alignment.centerLeft,
        fit: BoxFit.scaleDown,
        child: Text.rich(
          TextSpan(
            children: [
              for (final part in RegExp(r'[0-9]+|[^0-9]+').allMatches(value))
                TextSpan(
                  text: part.group(0),
                  style: int.tryParse(part.group(0)!) == null
                      ? const TextStyle(fontSize: 10)
                      : null,
                ),
            ],
          ),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    ],
  );
}

class FocusRulerSessionCard extends StatelessWidget {
  const FocusRulerSessionCard({
    super.key,
    required this.session,
    this.todayFocusedDuration,
    this.cumulativeFocusedDuration,
  });

  final FocusSession session;
  final Duration? todayFocusedDuration;
  final Duration? cumulativeFocusedDuration;

  @override
  Widget build(BuildContext context) {
    final start = session.startedAt.toLocal();
    final end = session.finishedAt?.toLocal();
    final endOnAnotherDay =
        end != null &&
        (start.year != end.year ||
            start.month != end.month ||
            start.day != end.day);
    final active = session.accumulatedFocusDuration;
    final video = session.sourceVideoTitle?.trim();
    return _RulerCanvas(
      date: _date(start),
      title: session.goal.trim().isEmpty ? '一次专注' : session.goal,
      durationLabel: '本次实际专注',
      duration: active,
      panelTitle: '本次专注时段',
      panel: _SessionPanel(
        start: start,
        end: end,
        endOnAnotherDay: endOnAnotherDay,
        status: session.status,
        completedWithVideo:
            session.completeOnPartEnd && active < session.plannedDuration,
        active: active,
      ),
      metrics: [
        if (todayFocusedDuration case final today?)
          (label: '今日已专注', value: _compactDuration(today)),
        if (cumulativeFocusedDuration case final total?)
          (label: '累计已专注', value: _compactDuration(total)),
        (label: '中途打断', value: '${session.interruptions.length} 次'),
      ],
      video: video?.isNotEmpty == true ? video : null,
    );
  }
}

class _SessionPanel extends StatelessWidget {
  const _SessionPanel({
    required this.start,
    required this.end,
    required this.endOnAnotherDay,
    required this.status,
    required this.completedWithVideo,
    required this.active,
  });

  final DateTime start;
  final DateTime? end;
  final bool endOnAnotherDay;
  final FocusSessionStatus status;
  final bool completedWithVideo;
  final Duration active;

  @override
  Widget build(BuildContext context) {
    final scale = focusRulerDialScale(active);
    final fraction =
        (active.inMicroseconds / Duration(minutes: scale).inMicroseconds).clamp(
          0.0,
          1.0,
        );
    final endLabel = switch (status) {
      FocusSessionStatus.completed => completedWithVideo ? '完成' : '按时完成',
      FocusSessionStatus.endedEarly => '提前结束',
      _ => '结束',
    };
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _event(_time(start), '开始'),
              Padding(
                padding: const EdgeInsets.fromLTRB(3, 2, 0, 2),
                child: CustomPaint(
                  size: const Size(4, 15),
                  painter: _EventLine(),
                ),
              ),
              if (end case final finished?)
                _event(
                  endOnAnotherDay
                      ? '${_shortDate(finished)} ${_time(finished)}'
                      : _time(finished),
                  endLabel,
                )
              else
                const Text(
                  '尚未结束',
                  style: TextStyle(fontSize: 10, color: _cool),
                ),
            ],
          ),
        ),
        SizedBox(
          width: 120,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Semantics(
                image: true,
                label: '实际专注 ${_compactDuration(active)}，刻度上限 $scale 分钟',
                child: CustomPaint(
                  size: const Size.square(89),
                  painter: _RulerDial(fraction),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '全圈 $scale 分钟',
                style: const TextStyle(color: _cool, fontSize: 8),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _event(String time, String label) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: time,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          TextSpan(
            text: '  $label',
            style: const TextStyle(fontSize: 9, color: _cool),
          ),
        ],
      ),
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    ),
  );
}

/// Keep the same dial readable beyond an hour without resetting its hand.
int focusRulerDialScale(Duration active) {
  const hour = Duration(hours: 1);
  if (active <= hour) return 60;
  return ((active.inMicroseconds + hour.inMicroseconds - 1) ~/
          hour.inMicroseconds) *
      60;
}

class _EventLine extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final start = Offset(size.width / 2, 2);
    final end = Offset(size.width / 2, size.height - 2);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = _cool
        ..strokeWidth = .6,
    );
    final accent = Paint()..color = _orange;
    canvas.drawCircle(start, 1.3, accent);
    canvas.drawCircle(end, 1.3, accent);
  }

  @override
  bool shouldRepaint(_EventLine oldDelegate) => false;
}

class _RulerDial extends CustomPainter {
  const _RulerDial(this.fraction);
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 1;
    Offset point(double angle, double length) =>
        center + Offset(math.cos(angle), math.sin(angle)) * length;
    for (var i = 0; i < 60; i++) {
      final angle = i * math.pi / 30 - math.pi / 2;
      final major = i % 5 == 0;
      final spent = fraction > 0 && i < fraction * 60;
      final tick = Paint()
        ..color = spent ? Colors.white : _cool.withValues(alpha: .39)
        ..strokeWidth = major ? 1.2 : .75;
      canvas.drawLine(
        point(angle, radius - (major ? 6 : 3.5)),
        point(angle, radius),
        tick,
      );
    }
    final hand = Paint()
      ..color = _orange
      ..strokeWidth = 1.5;
    if (fraction > 0) {
      final angle = fraction * 2 * math.pi - math.pi / 2;
      canvas.drawLine(center, point(angle, radius - 7), hand);
    }
    canvas.drawCircle(center, 2.2, hand);
  }

  @override
  bool shouldRepaint(_RulerDial oldDelegate) =>
      oldDelegate.fraction != fraction;
}

class FocusRulerStatisticsCard extends StatelessWidget {
  const FocusRulerStatisticsCard({super.key, required this.snapshot});
  final FocusStatisticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final daily = snapshot.dailyTrend;
    final range = snapshot.range;
    final title = switch (range) {
      FocusStatisticsRange.sevenDays => '七天的专注足迹',
      FocusStatisticsRange.thirtyDays => '三十天的专注足迹',
      FocusStatisticsRange.all => '我的专注足迹',
    };
    return _RulerCanvas(
      date: range == FocusStatisticsRange.all
          ? '全部记录'
          : daily.isEmpty
          ? null
          : '${_date(daily.first.date)}  –  ${daily.first.date.year != daily.last.date.year ? _date(daily.last.date) : _dotMonthDay(daily.last.date)}',
      title: title,
      durationLabel: '累计专注时长',
      duration: snapshot.totalFocusedDuration,
      panelTitle: range == FocusStatisticsRange.all
          ? '近 30 天每日专注（分钟）'
          : '每日专注（分钟）',
      panel: daily.isEmpty
          ? const Center(
              child: Text('暂无专注数据', style: TextStyle(color: _cool)),
            )
          : Semantics(
              image: true,
              label: '每日专注柱状图，纵轴为分钟，横轴为日期',
              child: CustomPaint(
                painter: _DailyBars(
                  daily,
                  DefaultTextStyle.of(context).style.fontFamily,
                ),
                size: const Size(double.infinity, double.infinity),
              ),
            ),
      metrics: [
        (label: '按时完成率', value: '${(snapshot.completionRate * 100).round()}%'),
        (label: '投入天数', value: '${snapshot.focusDayCount} 天'),
        (label: '连续专注', value: '${snapshot.currentStreakDays} 天'),
      ],
    );
  }
}

class _DailyBars extends CustomPainter {
  const _DailyBars(this.daily, this.fontFamily);
  final List<FocusDailyStatistic> daily;
  final String? fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    final minutes = daily
        .map(
          (day) =>
              math.max(0, day.focusedDuration.inMicroseconds) /
              Duration.microsecondsPerMinute,
        )
        .toList(growable: false);
    final maxValue = minutes.fold(0.0, math.max);
    final step = _step(maxValue / 3);
    final plot = Rect.fromLTRB(20, 14, size.width - 2, size.height - 16);
    final slot = plot.width / minutes.length;
    for (var i = 0; i <= 3; i++) {
      final y = plot.bottom - i * plot.height / 3;
      final grid = Paint()
        ..color = _cool.withValues(alpha: i == 0 ? .5 : .38)
        ..strokeWidth = .5;
      if (i == 0) {
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      } else {
        for (var x = plot.left; x < plot.right; x += 4) {
          canvas.drawLine(
            Offset(x, y),
            Offset(math.min(x + 1.4, plot.right), y),
            grid,
          );
        }
      }
      _label(canvas, '${step * i}', plot.left - 4, y - 4, rightAligned: true);
    }
    final labelCount = math.min(minutes.length, minutes.length <= 7 ? 7 : 6);
    final labels = <int>{
      for (var i = 0; i < labelCount; i++)
        labelCount == 1
            ? 0
            : (i * (minutes.length - 1) / (labelCount - 1)).round(),
    };
    for (final (i, value) in minutes.indexed) {
      final latest = i == minutes.length - 1;
      final x = plot.left + slot * (i + .5);
      final barHeight = value / (step * 3) * plot.height;
      final barWidth = slot * (value == 0 ? .34 : .61);
      final fill = latest ? _orange : _cool;
      canvas.drawRect(
        Rect.fromLTWH(
          x - barWidth / 2,
          plot.bottom - math.max(barHeight, .7),
          barWidth,
          math.max(barHeight, .7),
        ),
        Paint()..color = fill,
      );
      if (labelCount == minutes.length || latest) {
        final text = value > 0 && value < 1 ? '<1' : value.round().toString();
        _label(
          canvas,
          text,
          x,
          plot.bottom - barHeight - 10,
          color: latest ? _orange : Colors.white,
          bold: true,
          clampWidth: size.width,
        );
      }
      if (labels.contains(i)) {
        _label(
          canvas,
          _shortDate(daily[i].date),
          x,
          plot.bottom + 5,
          color: fill,
          bold: latest,
          clampWidth: size.width,
        );
      }
    }
  }

  void _label(
    Canvas canvas,
    String text,
    double anchor,
    double y, {
    Color color = _cool,
    bool bold = false,
    bool rightAligned = false,
    double? clampWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: bold ? 8.4 : 7.5,
          fontFamily: fontFamily,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = rightAligned
        ? anchor - painter.width
        : (anchor - painter.width / 2).clamp(
            0.0,
            math.max(0.0, (clampWidth ?? double.infinity) - painter.width),
          );
    painter.paint(canvas, Offset(x.toDouble(), y));
    painter.dispose();
  }

  static int _step(double value) {
    const choices = [
      1,
      2,
      3,
      5,
      10,
      15,
      20,
      30,
      45,
      60,
      90,
      120,
      180,
      240,
      360,
      480,
      720,
    ];
    return choices.firstWhere(
      (n) => n >= value,
      orElse: () => (value / 60).ceil() * 60,
    );
  }

  @override
  bool shouldRepaint(_DailyBars oldDelegate) =>
      oldDelegate.daily != daily || oldDelegate.fontFamily != fontFamily;
}

class _RulerMark extends CustomPainter {
  const _RulerMark();

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 8; i++) {
      final x = 3.0 + i * 4.0;
      final y = 10.0 - i * 1.25;
      final path = Path()
        ..moveTo(x, y + 9)
        ..quadraticBezierTo(x - 1, y - 1, x + 7, y + 2)
        ..lineTo(x + 51, y + 20)
        ..quadraticBezierTo(x + 60, y + 25, x + 52, y + 32)
        ..lineTo(x + 16, y + 58)
        ..quadraticBezierTo(x + 8, y + 65, x + 7, y + 57)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(const Color(0xff9ebee1), _blue, i / 7)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == 7 ? 1.2 : .86,
      );
    }
  }

  @override
  bool shouldRepaint(_RulerMark oldDelegate) => false;
}

String _two(int n) => n.toString().padLeft(2, '0');
String _date(DateTime date) => '${date.year}.${_dotMonthDay(date)}';
String _dotMonthDay(DateTime date) => '${_two(date.month)}.${_two(date.day)}';
String _shortDate(DateTime date) => '${_two(date.month)}/${_two(date.day)}';
String _time(DateTime date) => '${_two(date.hour)}:${_two(date.minute)}';

List<({String value, String unit})> _durationParts(Duration value) {
  final hours = math.max(0, value.inHours);
  final minutes = math.max(0, value.inMinutes);
  if (value > Duration.zero && minutes == 0) {
    return [
      (value: value.inSeconds == 0 ? '<1' : '${value.inSeconds}', unit: '秒'),
    ];
  }
  return [
    if (hours > 0) (value: '$hours', unit: '小时'),
    if (hours == 0 || minutes % 60 > 0) (value: '${minutes % 60}', unit: '分钟'),
  ];
}

String _compactDuration(Duration value) =>
    _durationParts(value).map((part) => '${part.value} ${part.unit}').join(' ');
