import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/focus_session.dart';

/// 注册专注记录的时间计算、序列化和损坏数据测试。
void main() {
  /// 验证运行时长由绝对时间计算，暂停期间不会继续消耗剩余时间。
  test('专注记录按绝对时间计算并支持暂停继续', () {
    final DateTime start = DateTime(2026, 7, 18, 9);
    final FocusSession running = FocusSession.start(
      id: 'focus-1',
      goal: '学习 Flutter',
      plannedDuration: const Duration(minutes: 25),
      now: start,
    );

    expect(
      running.elapsedAt(start.add(const Duration(minutes: 8))),
      const Duration(minutes: 8),
    );
    final FocusSession paused = running.pauseAt(
      start.add(const Duration(minutes: 8)),
    );
    expect(
      paused.remainingAt(start.add(const Duration(minutes: 18))),
      const Duration(minutes: 17),
    );
    final FocusSession resumed = paused.resumeAt(
      start.add(const Duration(minutes: 18)),
    );
    expect(
      resumed.remainingAt(start.add(const Duration(minutes: 23))),
      const Duration(minutes: 12),
    );
  });

  /// 验证记录写入 JSON 后可以完整恢复时间、目标和状态。
  test('专注记录可以安全序列化和恢复', () {
    final DateTime start = DateTime(2026, 7, 18, 10);
    final FocusSession completed =
        FocusSession.start(
          id: 'focus-2',
          goal: '看完课程第一章',
          plannedDuration: const Duration(minutes: 45),
          now: start,
        ).finishAt(
          start.add(const Duration(minutes: 45)),
          finalStatus: FocusSessionStatus.completed,
        );

    final FocusSession? restored = FocusSession.tryParse(completed.toJson());

    expect(restored?.id, completed.id);
    expect(restored?.goal, completed.goal);
    expect(restored?.status, FocusSessionStatus.completed);
    expect(restored?.accumulatedFocusDuration, const Duration(minutes: 45));
  });

  /// 验证越界时长和状态矛盾的损坏记录会被拒绝，而不是让应用启动崩溃。
  test('损坏的专注记录不会被恢复', () {
    expect(
      FocusSession.tryParse(<String, dynamic>{
        'id': 'broken',
        'goal': '无效记录',
        'plannedMs': 100,
        'startedAt': DateTime(2026).toIso8601String(),
        'accumulatedMs': 0,
        'status': 'running',
      }),
      isNull,
    );
  });

  /// 验证播放器来源字段和续时后的计划时长可以安全保存与恢复。
  test('专注记录保存播放器来源并支持续时', () {
    final FocusSession extended = FocusSession.start(
      id: 'focus-player',
      goal: '看完当前分P',
      plannedDuration: const Duration(minutes: 20),
      now: DateTime(2026, 7, 18, 11),
      sourceBvid: 'BV1TEST',
      sourceVideoTitle: '测试视频',
      sourcePartCid: 123,
      sourcePartPageNumber: 2,
      sourcePartTitle: '第二P',
    ).extendBy(const Duration(minutes: 5));

    final FocusSession? restored = FocusSession.tryParse(extended.toJson());

    expect(restored?.plannedDuration, const Duration(minutes: 25));
    expect(restored?.sourceBvid, 'BV1TEST');
    expect(restored?.sourcePartPageNumber, 2);
    expect(restored?.sourcePartTitle, '第二P');
  });

  /// 验证旧记录只保存 BV 号时仍可打开视频，但不会误认为已经精确关联分P。
  test('旧专注记录只含 BV 号时仍可浏览视频', () {
    final FocusSession legacy = FocusSession.start(
      id: 'legacy-focus',
      goal: '旧版记录',
      plannedDuration: const Duration(minutes: 25),
      now: DateTime(2026, 7, 18, 11),
      sourceBvid: 'BV1LEGACY',
      startImmediately: false,
    );

    expect(legacy.hasBrowsableVideo, isTrue);
    expect(legacy.hasVideoAssociation, isFalse);
  });

  /// 验证视频画面、播放位置、打断原因和提醒时间都能完整写入并恢复。
  test('专注记录保存视频 Pin 和打断详情', () {
    final DateTime start = DateTime(2026, 7, 18, 12);
    final DateTime reminder = start.add(const Duration(hours: 2));
    final FocusSession interrupted =
        FocusSession.start(
          id: 'focus-pin',
          goal: '完成课程',
          plannedDuration: const Duration(minutes: 30),
          now: start,
          sourceBvid: 'BV1TEST',
          sourceVideoTitle: '课程视频',
          sourcePartCid: 456,
          sourcePartPageNumber: 2,
          sourcePartTitle: '第二讲',
          sourceFramePath: 'C:\\focus-frame.jpg',
          sourcePosition: const Duration(minutes: 8),
        ).addInterruption(
          start.add(const Duration(minutes: 10)),
          interruption: FocusInterruption(
            id: 'break-1',
            occurredAt: start.add(const Duration(minutes: 10)),
            kind: FocusInterruptionKind.playerExit,
            reason: '临时接电话',
            reminderAt: reminder,
          ),
        );

    final FocusSession? restored = FocusSession.tryParse(interrupted.toJson());

    expect(restored?.sourceFramePath, 'C:\\focus-frame.jpg');
    expect(restored?.sourcePosition, const Duration(minutes: 8));
    expect(restored?.interruptions, hasLength(1));
    expect(restored?.latestInterruptionReason, '临时接电话');
    expect(restored?.interruptions.single.reminderAt, reminder);
  });

  /// 验证暂停数小时后恢复时，逐日桶只记录真实播放片段而不填满暂停空档。
  test('专注记录持久化跨日运行片段', () {
    final FocusSession firstRun = FocusSession.start(
      id: 'focus-daily-buckets',
      goal: '分两晚学习',
      plannedDuration: const Duration(minutes: 30),
      now: DateTime(2026, 7, 18, 23, 50),
    );
    final FocusSession paused = firstRun.pauseAt(DateTime(2026, 7, 19));
    final FocusSession resumed = paused.resumeAt(DateTime(2026, 7, 20, 23, 50));
    final FocusSession finished = resumed.finishAt(
      DateTime(2026, 7, 21),
      finalStatus: FocusSessionStatus.endedEarly,
    );
    final FocusSession? restored = FocusSession.tryParse(finished.toJson());

    expect(finished.accumulatedFocusDuration, const Duration(minutes: 20));
    expect(finished.dailyFocusMilliseconds, <String, int>{
      '2026-07-18': const Duration(minutes: 10).inMilliseconds,
      '2026-07-20': const Duration(minutes: 10).inMilliseconds,
    });
    expect(restored?.dailyFocusMilliseconds, finished.dailyFocusMilliseconds);
  });
}
