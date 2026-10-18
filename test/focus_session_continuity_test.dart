import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/focus_statistics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('一场会话跨视频、分P、暂停视频与完播连续计时且只归档一次', () async {
    var now = DateTime(2026, 10, 18, 10);
    final controller = FocusTimerController(
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '学习数学',
      duration: const Duration(minutes: 25),
    );
    final id = controller.activeSession!.id;
    expect(controller.activeSession!.status, FocusSessionStatus.running);
    expect(
      await controller.startFocus(
        goal: '重复开始',
        duration: const Duration(minutes: 25),
      ),
      false,
    );
    for (var index = 0; index < 6; index++) {
      now = now.add(const Duration(minutes: 2));
      await controller.updatePlaybackState(
        bvid: index < 3 ? 'BVfirst' : 'BVsecond',
        partCid: index + 1,
        isPlaying: index.isEven,
        videoTitle: '课程$index',
        partPageNumber: index + 1,
        partTitle: '第$index节',
        position: const Duration(seconds: 12),
      );
      await controller.updatePlaybackState(
        bvid: 'BVstale',
        partCid: 99,
        isPlaying: false,
      );
      expect(
        await controller.completeForPlaybackPart(
          bvid: 'BVsecond',
          partCid: index + 1,
        ),
        false,
      );
      expect(controller.activeSession!.id, id);
      expect(controller.elapsedDuration, Duration(minutes: (index + 1) * 2));
      expect(controller.history, isEmpty);
    }
    expect(controller.activeSession!.sourceBvid, 'BVsecond');
    await controller.endFocusEarly(reason: '计划完成');
    await controller.endFocusEarly();
    expect(controller.history, hasLength(1));
    expect(
      controller.history.single.accumulatedFocusDuration,
      const Duration(minutes: 12),
    );
    final stats = FocusStatisticsCalculator.build(
      history: controller.history,
      range: FocusStatisticsRange.all,
      now: now,
    );
    expect(stats.sessionCount, 1);
    expect(stats.totalFocusedDuration, const Duration(minutes: 12));
  });

  test('手动暂停不被换P或播放事件恢复，主动继续无需视频', () async {
    var now = DateTime(2026, 10, 18, 10);
    final controller = FocusTimerController(
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '阅读与复习',
      duration: const Duration(minutes: 25),
    );
    now = now.add(const Duration(minutes: 3));
    await controller.pauseFocus();
    await controller.associateVideo(
      bvid: 'BVnext',
      videoTitle: '新视频',
      partCid: 2,
      partPageNumber: 2,
      partTitle: '第二节',
      isPlaying: true,
    );
    now = now.add(const Duration(minutes: 10));
    expect(controller.elapsedDuration, const Duration(minutes: 3));
    await controller.resumeFocus();
    now = now.add(const Duration(minutes: 2));
    expect(controller.elapsedDuration, const Duration(minutes: 5));
  });

  test('后台重复事件只记一次打断，前台不会偷偷继续，检查点重启不重复', () async {
    var now = DateTime(2026, 10, 18, 23, 58);
    final controller = FocusTimerController(
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    await controller.initialize();
    await controller.startFocus(
      goal: '跨日学习',
      duration: const Duration(minutes: 25),
    );
    now = now.add(const Duration(minutes: 4));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.activeSession!.accumulatedFocusDuration,
      const Duration(minutes: 4),
    );
    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(controller.activeSession!.interruptions, hasLength(1));
    now = now.add(const Duration(hours: 1));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.activeSession!.status, FocusSessionStatus.paused);
    expect(controller.elapsedDuration, const Duration(minutes: 4));
    expect(controller.todayFocusedDuration(), const Duration(minutes: 2));
    controller.dispose();
    final restored = FocusTimerController(
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.elapsedDuration, const Duration(minutes: 4));
    await restored.resumeFocus();
    now = now.add(const Duration(minutes: 1));
    expect(restored.elapsedDuration, const Duration(minutes: 5));
  });

  test('旧按分P任务保留累计和书签，迁移后按会话计划结束且不重复归档', () async {
    var now = DateTime(2026, 10, 18, 10);
    final legacy =
        FocusSession.start(
          id: 'legacy',
          goal: '旧任务',
          plannedDuration: const Duration(minutes: 25),
          now: now,
          sourceBvid: 'BVlegacy',
          sourcePartCid: 1,
          completeOnPartEnd: true,
        ).pauseAt(
          now.add(const Duration(minutes: 5)),
          reason: FocusPauseReason.playback,
        );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'focubili_focus_active_session',
      jsonEncode(legacy.toJson()),
    );
    final controller = FocusTimerController(
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.activeSession!.id, 'legacy');
    expect(controller.activeSession!.completeOnPartEnd, false);
    expect(controller.activeSession!.sourceBvid, 'BVlegacy');
    expect(controller.elapsedDuration, const Duration(minutes: 5));
    await controller.resumeFocus();
    now = now.add(const Duration(minutes: 20));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(controller.history, hasLength(1));
    expect(controller.history.single.status, FocusSessionStatus.completed);
    expect(
      controller.history.single.accumulatedFocusDuration,
      const Duration(minutes: 25),
    );
  });

  test('统计防御重复会话ID且终态历史优先于同ID活动快照', () {
    final now = DateTime(2026, 10, 18, 10);
    final active = FocusSession.start(
      id: 'same',
      goal: '重复快照',
      plannedDuration: const Duration(minutes: 25),
      now: now,
    );
    final ended = active.finishAt(
      now.add(const Duration(minutes: 5)),
      finalStatus: FocusSessionStatus.endedEarly,
    );
    final stats = FocusStatisticsCalculator.build(
      history: [ended, ended],
      activeSession: active,
      range: FocusStatisticsRange.all,
      now: now.add(const Duration(minutes: 5)),
    );
    expect(stats.totalFocusedDuration, const Duration(minutes: 5));
    expect(stats.sessionCount, 1);
  });
}
