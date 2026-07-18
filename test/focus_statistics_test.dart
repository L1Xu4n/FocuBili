import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/focus_statistics.dart';

/// 创建指定日期、状态和时长的已结束记录，减少统计测试重复样板。
FocusSession _finishedSession({
  required String id,
  required DateTime finishedAt,
  required Duration focusedDuration,
  required FocusSessionStatus status,
  String? sourceBvid,
  List<FocusInterruption> interruptions = const <FocusInterruption>[],
}) {
  return FocusSession(
    id: id,
    goal: '目标 $id',
    plannedDuration: focusedDuration > const Duration(minutes: 30)
        ? focusedDuration
        : const Duration(minutes: 30),
    startedAt: finishedAt.subtract(focusedDuration),
    accumulatedFocusDuration: focusedDuration,
    status: status,
    finishedAt: finishedAt,
    sourceBvid: sourceBvid,
    interruptions: interruptions,
  );
}

/// 注册统计计算器的时间范围、完成率、趋势和连续天数测试。
void main() {
  /// 验证七天看板排除范围外记录，并正确汇总完成与提前结束。
  test('七天专注统计生成指标和每日趋势', () {
    final DateTime now = DateTime(2026, 7, 18, 12);
    final List<FocusSession> history = <FocusSession>[
      _finishedSession(
        id: 'today',
        finishedAt: DateTime(2026, 7, 18, 10),
        focusedDuration: const Duration(minutes: 30),
        status: FocusSessionStatus.completed,
        sourceBvid: 'BV1TEST',
        interruptions: <FocusInterruption>[
          FocusInterruption(
            id: 'break-1',
            occurredAt: DateTime(2026, 7, 18, 9),
            kind: FocusInterruptionKind.manualPause,
            reason: '接电话',
          ),
        ],
      ),
      _finishedSession(
        id: 'yesterday',
        finishedAt: DateTime(2026, 7, 17, 10),
        focusedDuration: const Duration(minutes: 10),
        status: FocusSessionStatus.endedEarly,
      ),
      _finishedSession(
        id: 'old',
        finishedAt: DateTime(2026, 7, 1, 10),
        focusedDuration: const Duration(minutes: 50),
        status: FocusSessionStatus.completed,
      ),
    ];

    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: history,
      range: FocusStatisticsRange.sevenDays,
      now: now,
    );

    expect(snapshot.totalFocusedDuration, const Duration(minutes: 40));
    expect(snapshot.completedCount, 1);
    expect(snapshot.endedEarlyCount, 1);
    expect(snapshot.completionRate, 0.5);
    expect(snapshot.focusDayCount, 2);
    expect(snapshot.currentStreakDays, 2);
    expect(snapshot.linkedVideoCount, 1);
    expect(snapshot.interruptionCount, 1);
    expect(snapshot.dailyTrend, hasLength(7));
  });

  /// 验证全部范围汇总完整历史，但趋势仍限制为最近三十天。
  test('全部范围保留完整指标并限制趋势长度', () {
    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: <FocusSession>[
        _finishedSession(
          id: 'old',
          finishedAt: DateTime(2025, 1, 1, 10),
          focusedDuration: const Duration(minutes: 45),
          status: FocusSessionStatus.completed,
        ),
      ],
      range: FocusStatisticsRange.all,
      now: DateTime(2026, 7, 18, 12),
    );

    expect(snapshot.totalFocusedDuration, const Duration(minutes: 45));
    expect(snapshot.sessionCount, 1);
    expect(snapshot.dailyTrend, hasLength(30));
  });

  /// 验证午夜前后各投入一部分时长，不会把整段都算到结束日期。
  test('跨午夜专注时长按自然日拆分', () {
    final FocusSession session = _finishedSession(
      id: 'midnight',
      finishedAt: DateTime(2026, 7, 19, 0, 20),
      focusedDuration: const Duration(minutes: 30),
      status: FocusSessionStatus.completed,
    );

    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: <FocusSession>[session],
      range: FocusStatisticsRange.sevenDays,
      now: DateTime(2026, 7, 19, 12),
    );

    expect(snapshot.dailyTrend[5].focusedDuration, const Duration(minutes: 10));
    expect(snapshot.dailyTrend[6].focusedDuration, const Duration(minutes: 20));
    expect(snapshot.focusDayCount, 2);
  });

  /// 验证正在计时的跨午夜任务也按日期拆分，而不是全部归入今天。
  test('活动专注跨午夜时按自然日拆分', () {
    final FocusSession active = FocusSession.start(
      id: 'active-midnight',
      goal: '跨午夜',
      plannedDuration: const Duration(hours: 1),
      now: DateTime(2026, 7, 18, 23, 50),
    );

    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: const <FocusSession>[],
      range: FocusStatisticsRange.sevenDays,
      now: DateTime(2026, 7, 19, 0, 10),
      activeSession: active,
    );

    expect(snapshot.totalFocusedDuration, const Duration(minutes: 20));
    expect(snapshot.dailyTrend[5].focusedDuration, const Duration(minutes: 10));
    expect(snapshot.dailyTrend[6].focusedDuration, const Duration(minutes: 10));
  });

  /// 验证范围起点之前的投入不会进入七天总时长，确保总计与折线求和一致。
  test('跨越范围起点时总时长只计算范围内片段', () {
    final FocusSession session = _finishedSession(
      id: 'range-boundary',
      finishedAt: DateTime(2026, 7, 13, 0, 10),
      focusedDuration: const Duration(minutes: 30),
      status: FocusSessionStatus.completed,
    );

    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: <FocusSession>[session],
      range: FocusStatisticsRange.sevenDays,
      now: DateTime(2026, 7, 19, 12),
    );
    final Duration trendTotal = snapshot.dailyTrend.fold<Duration>(
      Duration.zero,
      (Duration total, FocusDailyStatistic item) =>
          total + item.focusedDuration,
    );

    expect(snapshot.totalFocusedDuration, const Duration(minutes: 10));
    expect(trendTotal, snapshot.totalFocusedDuration);
  });

  /// 验证跨日暂停的空档不会被误算为某一天的实际投入。
  test('暂停后跨日恢复按真实运行片段统计', () {
    final FocusSession session =
        FocusSession.start(
              id: 'paused-across-days',
              goal: '分两晚学习',
              plannedDuration: const Duration(minutes: 30),
              now: DateTime(2026, 7, 16, 23, 50),
            )
            .pauseAt(DateTime(2026, 7, 17))
            .resumeAt(DateTime(2026, 7, 18, 23, 50))
            .finishAt(
              DateTime(2026, 7, 19),
              finalStatus: FocusSessionStatus.endedEarly,
            );

    final FocusStatisticsSnapshot snapshot = FocusStatisticsCalculator.build(
      history: <FocusSession>[session],
      range: FocusStatisticsRange.sevenDays,
      now: DateTime(2026, 7, 19, 12),
    );

    expect(snapshot.dailyTrend[3].focusedDuration, const Duration(minutes: 10));
    expect(snapshot.dailyTrend[5].focusedDuration, const Duration(minutes: 10));
    expect(snapshot.dailyTrend[4].focusedDuration, Duration.zero);
  });
}
