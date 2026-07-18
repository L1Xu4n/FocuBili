import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/focus/focus_share_preview.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/focus_statistics.dart';

/// 验证两类专注分享卡会展示品牌与核心指标。
void main() {
  /// 验证单次完成卡显示 Logo、目标、时长和关联视频。
  testWidgets('单次专注分享卡展示品牌和任务信息', (WidgetTester tester) async {
    final FocusSession session = FocusSession(
      id: 'share-1',
      goal: '看完集合课程',
      plannedDuration: const Duration(minutes: 25),
      startedAt: DateTime(2026, 7, 19, 8),
      accumulatedFocusDuration: const Duration(minutes: 25),
      status: FocusSessionStatus.completed,
      finishedAt: DateTime(2026, 7, 19, 8, 25),
      sourceVideoTitle: '集合的三种常见运算',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FocusSessionShareCard(
              session: session,
              todayFocusedDuration: const Duration(minutes: 40),
              cumulativeFocusedDuration: const Duration(hours: 3),
            ),
          ),
        ),
      ),
    );

    expect(find.text('焦点哔哩'), findsOneWidget);
    expect(find.text('看完集合课程'), findsOneWidget);
    expect(find.text('今日专注时长'), findsOneWidget);
    expect(find.text('40 分钟'), findsOneWidget);
    expect(find.text('累计专注时长'), findsOneWidget);
    expect(find.text('3 小时'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  /// 验证统计卡显示范围、总时长、完成率和趋势画布。
  testWidgets('统计分享卡展示核心指标和趋势', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FocusStatisticsSnapshot snapshot = FocusStatisticsSnapshot(
      range: FocusStatisticsRange.sevenDays,
      totalFocusedDuration: const Duration(minutes: 90),
      averageFocusedDuration: const Duration(minutes: 30),
      longestFocusedDuration: const Duration(minutes: 45),
      completedCount: 2,
      endedEarlyCount: 1,
      focusDayCount: 3,
      currentStreakDays: 2,
      linkedVideoCount: 2,
      interruptionCount: 1,
      dailyTrend: List<FocusDailyStatistic>.generate(
        7,
        // 趋势生成函数为每天提供递增十分钟数据，方便画笔覆盖多点情况。
        (int index) => FocusDailyStatistic(
          date: DateTime(2026, 7, 13 + index),
          focusedDuration: Duration(minutes: index * 10),
          sessionCount: index == 0 ? 0 : 1,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: FocusStatisticsShareCard(snapshot: snapshot)),
        ),
      ),
    );

    expect(find.text('我的专注足迹'), findsOneWidget);
    expect(find.text('1.5 小时'), findsOneWidget);
    expect(find.text('67%'), findsOneWidget);
    expect(find.text('LAST 7 DAYS'), findsOneWidget);
    expect(find.bySemanticsLabel('专注趋势图，纵轴为专注时长，横轴为日期'), findsOneWidget);
    expect(find.textContaining('关联视频 2 个'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
