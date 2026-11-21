import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/services/focus_session_service.dart';

const _activeKey = 'focubili_focus_active_session';
const _historyKey = 'focubili_focus_history';

/// 仅使用内存存储，同时模拟插件先修改本进程缓存、随后返回 false/抛错。
class _RejectingFocusPreferences implements SharedPreferences {
  _RejectingFocusPreferences(this.base);
  final SharedPreferences base;
  final mutations = <String>[];
  final _cache = <String, String?>{};
  bool rejectHistoryWrite = false;
  bool rejectActiveWrite = false;
  bool rejectActiveRemove = false;
  bool throwOnRejectedWrite = false;

  @override
  String? getString(String key) =>
      _cache.containsKey(key) ? _cache[key] : base.getString(key);

  @override
  Future<bool> setString(String key, String value) async {
    mutations.add('set:$key');
    if ((key == _historyKey && rejectHistoryWrite) ||
        (key == _activeKey && rejectActiveWrite)) {
      _cache[key] = value;
      if (throwOnRejectedWrite) throw StateError('synthetic write failure');
      return false;
    }
    return base.setString(key, value);
  }

  @override
  Future<bool> remove(String key) async {
    mutations.add('remove:$key');
    if (key == _activeKey && rejectActiveRemove) {
      _cache[key] = null;
      return false;
    }
    return base.remove(key);
  }

  @override
  Future<void> reload() async {
    await base.reload();
    _cache.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FocusSession _running(String id) => FocusSession.start(
  id: id,
  goal: '合成专注测试',
  plannedDuration: const Duration(minutes: 25),
  now: DateTime(2026, 10, 18, 10),
);

FocusSession _finished(
  FocusSession session, {
  FocusSessionStatus status = FocusSessionStatus.completed,
}) => session.finishAt(
  session.startedAt.add(const Duration(minutes: 25)),
  finalStatus: status,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('清活动键返回false时归档先提交，重启终态优先且不会再次计时或归档', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    final active = _running('completed-once');
    expect(await service.saveState(activeSession: active, history: []), true);
    store.mutations.clear();
    store.rejectActiveRemove = true;
    final completed = _finished(active);
    expect(
      await service.saveState(activeSession: null, history: [completed]),
      false,
    );
    expect(store.mutations, ['set:$_historyKey', 'remove:$_activeKey']);
    expect(prefs.getString(_activeKey), isNotNull);
    expect(
      store.getString(_activeKey),
      prefs.getString(_activeKey),
      reason: 'false返回后的临时缓存已reload',
    );
    final persistedHistory = prefs.getString(_historyKey);
    final controller = FocusTimerController(
      service: service,
      clock: () => DateTime(2026, 10, 18, 12),
      tickInterval: const Duration(days: 1),
    );
    await controller.initialize();
    expect(controller.activeSession, null);
    expect(controller.history.single.status, FocusSessionStatus.completed);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await controller.endFocusEarly();
    expect(controller.history, hasLength(1));
    expect(
      prefs.getString(_historyKey),
      persistedHistory,
      reason: '初始化不能以旧active覆盖真正完成记录',
    );
    controller.dispose();
  });

  test('归档写入返回false时不先清active，保留上次durable快照并清理失败缓存', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    final active = _running('retain-active');
    await service.saveState(activeSession: active, history: []);
    final beforeActive = prefs.getString(_activeKey);
    final beforeHistory = prefs.getString(_historyKey);
    store.rejectHistoryWrite = true;
    store.mutations.clear();
    expect(
      await service.saveState(
        activeSession: null,
        history: [_finished(active)],
      ),
      false,
    );
    expect(store.mutations, ['set:$_historyKey']);
    expect(prefs.getString(_activeKey), beforeActive);
    expect(prefs.getString(_historyKey), beforeHistory);
    expect(store.getString(_historyKey), beforeHistory);
    final state = await FocusSessionService(
      preferencesLoader: () async => store,
    ).loadState();
    expect(state.activeSession?.id, active.id);
    expect(state.history, isEmpty);
  });

  test('活动写入返回false时不改历史，也不让临时缓存伪装成新活动记录', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    final active = _running('old-active');
    await service.saveState(activeSession: active, history: []);
    store.rejectActiveWrite = true;
    store.mutations.clear();
    expect(
      await service.saveState(
        activeSession: _running('new-active'),
        history: [_finished(_running('older'))],
      ),
      false,
    );
    expect(store.mutations, ['set:$_activeKey']);
    final state = await service.loadState();
    expect(state.activeSession?.id, 'old-active');
    expect(state.history, isEmpty);
  });

  test('删除终态前清理旧active失败时保留终态防复活，重试成功后可清空', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    final active = _running('terminal-guard');
    await service.saveState(activeSession: active, history: []);
    store.rejectActiveRemove = true;
    await service.saveState(activeSession: null, history: [_finished(active)]);
    final terminal = prefs.getString(_historyKey);
    store.mutations.clear();
    expect(await service.saveState(activeSession: null, history: []), false);
    expect(store.mutations, ['remove:$_activeKey']);
    expect(prefs.getString(_historyKey), terminal);
    final restart = await service.loadState();
    expect(restart.activeSession, null);
    expect(restart.history.single.id, active.id);
    store.rejectActiveRemove = false;
    expect(await service.saveState(activeSession: null, history: []), true);
    expect((await service.loadState()).activeSession, null);
    expect((await service.loadState()).history, isEmpty);
  });

  test('清旧active成功后删除终态写入false仍保留原完成记录', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    final active = _running('keep-terminal');
    await service.saveState(activeSession: active, history: []);
    store.rejectActiveRemove = true;
    await service.saveState(activeSession: null, history: [_finished(active)]);
    store.rejectActiveRemove = false;
    store.rejectHistoryWrite = true;
    store.mutations.clear();
    expect(await service.saveState(activeSession: null, history: []), false);
    expect(store.mutations, ['remove:$_activeKey', 'set:$_historyKey']);
    final restart = await service.loadState();
    expect(restart.activeSession, null);
    expect(restart.history.single.status, FocusSessionStatus.completed);
  });

  test('重新打开已完成任务时历史写入false保留终态，重试成功才恢复活动任务', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    final completed = _finished(_running('reopen'));
    await service.saveState(activeSession: null, history: [completed]);
    final reopened = completed.reopenAt(
      DateTime(2026, 10, 18, 11),
      const Duration(minutes: 5),
    );
    store.rejectHistoryWrite = true;
    expect(
      await service.saveState(activeSession: reopened, history: []),
      false,
    );
    final failed = await service.loadState();
    expect(failed.activeSession, null);
    expect(failed.history.single.status, FocusSessionStatus.completed);
    store.rejectHistoryWrite = false;
    expect(await service.saveState(activeSession: reopened, history: []), true);
    final saved = await service.loadState();
    expect(saved.activeSession?.id, completed.id);
    expect(saved.activeSession?.status, FocusSessionStatus.paused);
    expect(saved.history, isEmpty);
  });

  for (final status in [
    FocusSessionStatus.completed,
    FocusSessionStatus.endedEarly,
  ]) {
    test('旧键冲突时$status终态优先于同ID活动快照', () async {
      final prefs = await SharedPreferences.getInstance();
      final active = _running('legacy-conflict');
      await prefs.setString(_activeKey, jsonEncode(active.toJson()));
      await prefs.setString(
        _historyKey,
        jsonEncode([_finished(active, status: status).toJson()]),
      );
      final state = await FocusSessionService().loadState();
      expect(state.activeSession, null);
      expect(state.history.single.status, status);
    });
  }

  test('自动完成遇到写入异常不会抛出未捕获future或卡住完成锁，后续可重新保存', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    var now = DateTime(2026, 10, 18, 10);
    final controller = FocusTimerController(
      service: service,
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    await controller.initialize();
    await controller.startFocus(
      goal: '第一轮',
      duration: const Duration(minutes: 1),
    );
    store.rejectHistoryWrite = true;
    store.throwOnRejectedWrite = true;
    now = now.add(const Duration(minutes: 1));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    await service.loadState();
    expect(controller.history, hasLength(1));
    store.rejectHistoryWrite = false;
    expect(
      await controller.startFocus(
        goal: '第二轮',
        duration: const Duration(minutes: 1),
      ),
      true,
    );
    now = now.add(const Duration(minutes: 1));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    final restart = await service.loadState();
    expect(restart.activeSession, null);
    expect(restart.history, hasLength(2));
    expect(restart.history.map((item) => item.id).toSet(), hasLength(2));
    controller.dispose();
  });
  test('上轮结束写历史失败后开始新一轮，仍先补存旧终态避免覆盖唯一旧活动记录', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = _RejectingFocusPreferences(prefs);
    final service = FocusSessionService(preferencesLoader: () async => store);
    final first = _running('first');
    final completed = _finished(first);
    final second = _running('second');
    await service.saveState(activeSession: first, history: []);
    store.rejectHistoryWrite = true;
    expect(
      await service.saveState(activeSession: null, history: [completed]),
      false,
    );
    store.mutations.clear();
    expect(
      await service.saveState(activeSession: second, history: [completed]),
      false,
    );
    expect(store.mutations, ['set:$_historyKey']);
    expect((await service.loadState()).activeSession?.id, first.id);
    store.rejectHistoryWrite = false;
    store.rejectActiveWrite = true;
    expect(
      await service.saveState(activeSession: second, history: [completed]),
      false,
    );
    final failedSecond = await service.loadState();
    expect(failedSecond.activeSession, null);
    expect(failedSecond.history.single.id, first.id);
    store.rejectActiveWrite = false;
    expect(
      await service.saveState(activeSession: second, history: [completed]),
      true,
    );
    final recovered = await service.loadState();
    expect(recovered.activeSession?.id, second.id);
    expect(recovered.history.single.id, first.id);
  });
}
