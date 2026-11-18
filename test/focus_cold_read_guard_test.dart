import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/focus/focus_statistics_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/services/focus_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cold read outage followed by Start cannot erase yesterday or replace active goal',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final saved = FocusSessionService(preferencesLoader: () async => prefs);
      final now = DateTime(2026, 1, 3);
      FocusSession old(String id) => FocusSession.start(
        id: id,
        goal: id,
        plannedDuration: const Duration(minutes: 25),
        now: now,
      );
      final history = old('yesterday').finishAt(
        now.add(const Duration(minutes: 25)),
        finalStatus: FocusSessionStatus.completed,
      );
      expect(
        await saved.saveState(
          activeSession: old('existing'),
          history: [history],
        ),
        isTrue,
      );
      var failOnce = true;
      final recovering = FocusSessionService(
        preferencesLoader: () async {
          if (failOnce) {
            failOnce = false;
            throw StateError('temporary read outage');
          }
          return prefs;
        },
      );
      final timer = FocusTimerController(
        service: recovering,
        clock: () => now,
        tickInterval: const Duration(days: 1),
      );
      addTearDown(timer.dispose);
      await timer.initialize();
      expect(timer.isReady, isFalse);
      expect(timer.loadFailed, isTrue);
      final accepted = await timer.startFocus(
        goal: 'new',
        duration: const Duration(minutes: 25),
      );
      final onDisk = await saved.loadState();
      expect(
        [
          accepted,
          onDisk.activeSession?.id,
          onDisk.history.map((s) => s.id).join(','),
        ],
        [false, 'existing', 'yesterday'],
      );
      // A retry can recover on the same controller. A restored running
      // session pauses once rather than being silently discarded or restarted.
      await timer.initialize();
      expect(timer.isReady, isTrue);
      expect(timer.loadFailed, isFalse);
      expect(timer.activeSession?.id, 'existing');
      expect(timer.activeSession?.status, FocusSessionStatus.paused);
      expect(timer.history.single.id, 'yesterday');
      await timer.initialize();
      expect(timer.activeSession?.interruptions.length, 1);
    },
  );
  testWidgets('读取失败不能分享空统计；连续重试只读取一次，恢复后可在本页继续', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    final pending = Completer<SharedPreferences>();
    final timer = FocusTimerController(
      service: FocusSessionService(
        preferencesLoader: () async {
          if (++calls == 1) throw StateError('synthetic storage error');
          return await pending.future;
        },
      ),
    );
    addTearDown(timer.dispose);
    await timer.initialize();
    await tester.pumpWidget(
      MaterialApp(home: FocusStatisticsPage(controller: timer)),
    );
    expect(find.textContaining('原有记录不会被覆盖'), findsOneWidget);
    final share = find.byKey(const Key('share-focus-statistics'));
    expect(tester.widget<IconButton>(share).onPressed, isNull);
    await tester.tap(find.text('重新读取'));
    final pendingRetry = timer.initialize();
    await tester.pump();
    expect(find.text('正在重新读取…'), findsOneWidget);
    expect(calls, 2);
    pending.complete(prefs);
    await pendingRetry;
    await tester.pumpAndSettle();
    expect(timer.isReady, isTrue);
    expect(find.text('重新读取'), findsNothing);
    expect(tester.widget<IconButton>(share).onPressed, isNotNull);
  });
}
