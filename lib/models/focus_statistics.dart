import 'focus_session.dart';

/// 定义统计看板可以切换的时间范围。
enum FocusStatisticsRange { sevenDays, thirtyDays, all }

/// 保存某个本地自然日的专注时长和已结束记录数。
class FocusDailyStatistic {
  /// 创建一天的趋势数据，日期统一为当天零点。
  const FocusDailyStatistic({
    required this.date,
    required this.focusedDuration,
    required this.sessionCount,
  });

  final DateTime date;
  final Duration focusedDuration;
  final int sessionCount;
}

/// 保存统计看板一次计算得到的指标、趋势和完成情况。
class FocusStatisticsSnapshot {
  /// 创建不可变的统计快照，页面只负责展示而不重复计算业务规则。
  const FocusStatisticsSnapshot({
    required this.range,
    required this.totalFocusedDuration,
    required this.averageFocusedDuration,
    required this.longestFocusedDuration,
    required this.completedCount,
    required this.endedEarlyCount,
    required this.focusDayCount,
    required this.currentStreakDays,
    required this.linkedVideoCount,
    required this.interruptionCount,
    required this.dailyTrend,
  });

  final FocusStatisticsRange range;
  final Duration totalFocusedDuration;
  final Duration averageFocusedDuration;
  final Duration longestFocusedDuration;
  final int completedCount;
  final int endedEarlyCount;
  final int focusDayCount;
  final int currentStreakDays;
  final int linkedVideoCount;
  final int interruptionCount;
  final List<FocusDailyStatistic> dailyTrend;

  /// 返回当前范围内已经结束的专注总次数。
  int get sessionCount => completedCount + endedEarlyCount;

  /// 返回 0 到 1 之间的按时完成比例，没有结束记录时为零。
  double get completionRate =>
      sessionCount == 0 ? 0 : (completedCount / sessionCount).clamp(0.0, 1.0);
}

/// 将本机专注记录转换为看板需要的汇总指标和逐日趋势。
abstract final class FocusStatisticsCalculator {
  /// 根据指定范围生成统计快照，并把正在进行的实际时长计入今日总时长。
  static FocusStatisticsSnapshot build({
    required List<FocusSession> history,
    required FocusStatisticsRange range,
    required DateTime now,
    FocusSession? activeSession,
  }) {
    final DateTime localNow = now.toLocal();
    final DateTime today = _dayStart(localNow);
    final DateTime? rangeStart = switch (range) {
      FocusStatisticsRange.sevenDays => today.subtract(const Duration(days: 6)),
      FocusStatisticsRange.thirtyDays => today.subtract(
        const Duration(days: 29),
      ),
      FocusStatisticsRange.all => null,
    };
    final List<FocusSession> filteredHistory = history
        .where((FocusSession session) {
          final DateTime? finishedAt = session.finishedAt?.toLocal();
          if (finishedAt == null) {
            return false;
          }
          return rangeStart == null || !finishedAt.isBefore(rangeStart);
        })
        .toList(growable: false);

    int totalMilliseconds = 0;
    int longestMilliseconds = 0;
    int completedCount = 0;
    int endedEarlyCount = 0;
    int linkedVideoCount = 0;
    int interruptionCount = 0;
    final Map<DateTime, _MutableDailyStatistic> daily =
        <DateTime, _MutableDailyStatistic>{};
    for (final FocusSession session in filteredHistory) {
      final int focusedMilliseconds = _addFocusBuckets(
        daily: daily,
        values: session.focusedMillisecondsByLocalDayAt(session.finishedAt!),
        rangeStart: rangeStart,
        rangeEnd: today,
      );
      totalMilliseconds += focusedMilliseconds;
      if (focusedMilliseconds > longestMilliseconds) {
        longestMilliseconds = focusedMilliseconds;
      }
      if (session.status == FocusSessionStatus.completed) {
        completedCount += 1;
      } else if (session.status == FocusSessionStatus.endedEarly) {
        endedEarlyCount += 1;
      }
      if (session.sourceBvid?.isNotEmpty == true) {
        linkedVideoCount += 1;
      }
      interruptionCount += session.interruptions.length;
      final DateTime finishedDay = _dayStart(session.finishedAt!.toLocal());
      final _MutableDailyStatistic finishedItem = daily.putIfAbsent(
        finishedDay,
        _MutableDailyStatistic.new,
      );
      finishedItem.sessionCount += 1;
    }
    final int finishedTotalMilliseconds = totalMilliseconds;

    final FocusSession? active = activeSession;
    if (active != null) {
      final int activeMillisecondsInRange = _addFocusBuckets(
        daily: daily,
        values: active.focusedMillisecondsByLocalDayAt(localNow),
        rangeStart: rangeStart,
        rangeEnd: today,
      );
      totalMilliseconds += activeMillisecondsInRange;
    }

    final int sessionCount = completedCount + endedEarlyCount;
    final Duration averageDuration = sessionCount == 0
        ? Duration.zero
        : Duration(milliseconds: finishedTotalMilliseconds ~/ sessionCount);
    final DateTime trendStart = range == FocusStatisticsRange.sevenDays
        ? today.subtract(const Duration(days: 6))
        : today.subtract(const Duration(days: 29));
    final int trendDays = today.difference(trendStart).inDays + 1;
    final List<FocusDailyStatistic> trend = List<FocusDailyStatistic>.generate(
      trendDays,
      (int index) {
        final DateTime date = trendStart.add(Duration(days: index));
        final _MutableDailyStatistic? item = daily[date];
        return FocusDailyStatistic(
          date: date,
          focusedDuration: Duration(
            milliseconds: item?.focusedMilliseconds ?? 0,
          ),
          sessionCount: item?.sessionCount ?? 0,
        );
      },
      growable: false,
    );

    return FocusStatisticsSnapshot(
      range: range,
      totalFocusedDuration: Duration(milliseconds: totalMilliseconds),
      averageFocusedDuration: averageDuration,
      longestFocusedDuration: Duration(milliseconds: longestMilliseconds),
      completedCount: completedCount,
      endedEarlyCount: endedEarlyCount,
      focusDayCount: daily.values
          .where((_MutableDailyStatistic item) => item.focusedMilliseconds > 0)
          .length,
      currentStreakDays: _calculateCurrentStreak(daily, today),
      linkedVideoCount: linkedVideoCount,
      interruptionCount: interruptionCount,
      dailyTrend: List<FocusDailyStatistic>.unmodifiable(trend),
    );
  }

  /// 把任意本地时间归一化为当天零点，作为每日统计字典的稳定键。
  static DateTime _dayStart(DateTime value) {
    final DateTime local = value.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// 将专注记录已经结算的本地日期桶加入当前范围，并返回范围内总毫秒数。
  static int _addFocusBuckets({
    required Map<DateTime, _MutableDailyStatistic> daily,
    required Map<String, int> values,
    required DateTime? rangeStart,
    required DateTime rangeEnd,
  }) {
    int includedMilliseconds = 0;
    for (final MapEntry<String, int> entry in values.entries) {
      final DateTime? parsedDay = DateTime.tryParse(entry.key);
      if (parsedDay == null || entry.value <= 0) {
        continue;
      }
      final DateTime day = _dayStart(parsedDay);
      if ((rangeStart != null && day.isBefore(rangeStart)) ||
          day.isAfter(rangeEnd)) {
        continue;
      }
      daily.putIfAbsent(day, _MutableDailyStatistic.new).focusedMilliseconds +=
          entry.value;
      includedMilliseconds += entry.value;
    }
    return includedMilliseconds;
  }

  /// 从今天或昨天向前计算连续有专注投入的自然日数量。
  static int _calculateCurrentStreak(
    Map<DateTime, _MutableDailyStatistic> daily,
    DateTime today,
  ) {
    DateTime cursor = today;
    if ((daily[cursor]?.focusedMilliseconds ?? 0) <= 0) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    int streak = 0;
    while ((daily[cursor]?.focusedMilliseconds ?? 0) > 0) {
      streak += 1;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }
}

/// 在统计计算过程中累加单日数据，完成后再转换为不可变对象。
class _MutableDailyStatistic {
  int focusedMilliseconds = 0;
  int sessionCount = 0;
}
