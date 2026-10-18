import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/subscription_snapshot_store.dart';

import 'subscription_service_test.dart' show Content, item, source;

/// Simulates the atomic-store mutation contract, including commit failure.
/// Android integration tests exercise the real sqflite backend separately.
class AtomicSnapshots implements SubscriptionSnapshotStore {
  String? value, backup, quarantine;
  bool failCommit = false;
  String? Function(String current, String proposed)? conflictOnce;
  int forcedConflicts = 0;
  Future<void> queue = Future.value();
  @override
  Future<String?> read() async {
    await queue;
    return value;
  }

  @override
  Future<String?> recover(bool Function(String) validate) async {
    await queue;
    if (value != null && validate(value!)) return value;
    if (backup == null || !validate(backup!)) return null;
    quarantine = value;
    value = backup;
    return value;
  }

  @override
  Future<T> transact<T>(
    FutureOr<T> Function(String?, void Function(String)) action,
  ) {
    final next = queue.then((_) async {
      String? pending;
      var result = await action(value, (v) => pending = v);
      if (value != null && pending != null && conflictOnce != null) {
        final concurrent = conflictOnce!(value!, pending!);
        if (concurrent != null) {
          // Simulate a different engine committing between read and CAS.
          // Discard this attempt's proposed snapshot and replay the SAME action.
          conflictOnce = null;
          forcedConflicts++;
          backup = value;
          value = concurrent;
          pending = null;
          result = await action(value, (v) => pending = v);
        }
      }
      if (pending != null) {
        if (failCommit) throw StateError('disk full');
        if (value != pending) backup = value;
        value = pending;
      }
      return result;
    });
    queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  int get generation => (jsonDecode(value!) as Map)['generation'] as int;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late AtomicSnapshots store;
  late Content content;
  final scheduled = <(bool, int)>[];
  var now = DateTime(2026, 10, 5);
  Future<SubscriptionService> create() async {
    final service = SubscriptionService(
      snapshotStore: store,
      contentService: content,
      clock: () => now,
      backgroundScheduler: (enabled, generation) async {
        scheduled.add((enabled, generation));
      },
    );
    addTearDown(service.dispose);
    await service.initialize();
    return service;
  }

  setUp(() {
    store = AtomicSnapshots();
    content = Content()
      ..pages[1] = [
        [item('old')],
      ];
    scheduled.clear();
    now = DateTime(2026, 10, 5);
  });
  Future<SubscriptionService> baseline() async {
    final ui = await create();
    await ui.addSource(source(1));
    await ui.setEnabled(true);
    ui.setForeground(true);
    await ui.refresh(manual: true);
    ui.setForeground(false);
    await ui.setNotificationsEnabled(true);
    await ui.setBackgroundRefreshEnabled(true);
    now = now.add(const Duration(hours: 2));
    return ui;
  }

  test(
    'default off, migration preserves old JSON and missing image fields',
    () async {
      final ui = await create();
      expect(ui.backgroundRefreshEnabled, false);
      expect(ui.maxSources, 50);
      expect(content.calls, isEmpty);
      final old = source(1).toJson()..remove('imageUrl');
      expect(SubscriptionSource.fromJson(old).imageUrl, '');
      final withImage = SubscriptionSource(
        kind: SubscriptionKind.creator,
        mid: 1,
        name: 'UP',
        token: 'x',
        imageUrl: 'https://example.com/avatar.png',
      );
      expect(
        SubscriptionSource.fromJson(
          withImage.withPaused(true).toJson(),
        ).imageUrl,
        withImage.imageUrl,
      );
      final prefs = await SharedPreferences.getInstance();
      final legacy = store.value!;
      await prefs.setString(SubscriptionService.storageKey, legacy);
      store = AtomicSnapshots();
      final migrated = await create();
      expect(migrated.backgroundRefreshEnabled, false);
      expect(prefs.getString(SubscriptionService.storageKey), legacy);
      expect(store.value, legacy);
    },
  );

  test(
    'fresh headless instance checks and durable claims survive restart',
    () async {
      final ui = await baseline();
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      var notifications = 0;
      final worker = await create();
      worker.notifySummary = (count) async {
        notifications += count;
        return true;
      };
      await worker.runBackgroundCheck(store.generation);
      expect(worker.unreadCount, 1);
      expect(worker.lastBackgroundCheckAt, now);
      expect(notifications, 1);
      await ui.reload();
      expect(ui.feed.single.bvid, 'new');
      final restarted = await create();
      restarted.notifySummary = worker.notifySummary;
      now = now.add(const Duration(hours: 2));
      await restarted.runBackgroundCheck(store.generation);
      expect(notifications, 1);
      expect(restarted.unreadCount, 1);
    },
  );

  test(
    'first background baseline never imports or notifies historical videos',
    () async {
      final ui = await create();
      await ui.addSource(source(1));
      await ui.setEnabled(true);
      await ui.setNotificationsEnabled(true);
      await ui.setBackgroundRefreshEnabled(true);
      final worker = await create();
      var notifications = 0;
      worker.notifySummary = (count) async {
        notifications += count;
        return true;
      };
      await worker.runBackgroundCheck(store.generation);
      expect(worker.feed, isEmpty);
      expect(worker.checkpoint(source(1).key)!.initialized, true);
      expect(notifications, 0);
    },
  );

  test(
    'foreground read state survives concurrent background discovery',
    () async {
      final ui = await baseline();
      content.pages[1] = [
        [item('one'), item('old')],
      ];
      final worker = await create();
      await worker.runBackgroundCheck(store.generation);
      await ui.reload();
      now = now.add(const Duration(hours: 2));
      content.pages[1] = [
        [item('two'), item('one'), item('old')],
      ];
      final hold = Completer<void>();
      content.hold = hold;
      final pending = worker.runBackgroundCheck(store.generation);
      await Future<void>.delayed(Duration.zero);
      await ui.markRead('one');
      hold.complete();
      await pending;
      await ui.reload();
      expect(ui.feed.firstWhere((e) => e.bvid == 'one').readAt, isNotNull);
      expect(ui.feed.map((e) => e.bvid), contains('two'));
    },
  );

  test(
    'disable invalidates in-flight worker and old scheduled generations',
    () async {
      final ui = await baseline();
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      final hold = Completer<void>();
      content.hold = hold;
      final worker = await create();
      var notifications = 0;
      worker.notifySummary = (count) async {
        notifications += count;
        return true;
      };
      final generation = store.generation;
      final pending = worker.runBackgroundCheck(generation);
      await Future<void>.delayed(Duration.zero);
      await ui.setBackgroundRefreshEnabled(false);
      hold.complete();
      await pending;
      await ui.reload();
      expect(ui.feed, isEmpty);
      expect(notifications, 0);
      expect(scheduled.last.$1, false);
      final calls = content.calls.length;
      await (await create()).runBackgroundCheck(generation);
      expect(content.calls.length, calls);
    },
  );

  test(
    'pause delete and new source cannot be overwritten by stale scan',
    () async {
      final ui = await baseline();
      final worker = await create();
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      final hold = Completer<void>();
      content.hold = hold;
      final pending = worker.runBackgroundCheck(store.generation);
      await Future<void>.delayed(Duration.zero);
      await ui.pauseSource(source(1).key, true);
      await ui.deleteSource(source(1).key);
      await ui.addSource(source(2));
      hold.complete();
      await pending;
      await ui.reload();
      expect(ui.sources.single.mid, 2);
      expect(ui.feed, isEmpty);
    },
  );

  test(
    'denied notifications keep unread; persisted claim prevents duplicate hints',
    () async {
      await baseline();
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      var attempts = 0;
      final worker = await create();
      worker.notifySummary = (_) async {
        attempts++;
        return false;
      };
      await worker.runBackgroundCheck(store.generation);
      expect(worker.unreadCount, 1);
      now = now.add(const Duration(hours: 2));
      final restarted = await create();
      restarted.notifySummary = worker.notifySummary;
      await restarted.runBackgroundCheck(store.generation);
      expect(attempts, 1);
      expect(restarted.unreadCount, 1);
    },
  );

  test(
    'failed transaction rolls back configuration without losing sources',
    () async {
      final ui = await baseline();
      final before = store.value;
      store.failCommit = true;
      await expectLater(
        ui.setBackgroundRefreshEnabled(false),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(store.value, before);
      expect(ui.backgroundRefreshEnabled, true);
      expect(ui.sources.length, 1);
      store.failCommit = false;
      await ui.setBackgroundRefreshEnabled(false);
      expect(ui.backgroundRefreshEnabled, false);
    },
  );
  test(
    'corrupt primary recovers transactional backup and preserves corrupt evidence',
    () async {
      await baseline();
      final expected = store.backup;
      store.value = '{broken';
      final recovered = await create();
      expect(recovered.storageError, contains('恢复'));
      expect(store.value, expected);
      expect(store.quarantine, '{broken');
      expect(recovered.sources.single.mid, 1);
    },
  );
  test(
    'corrupt primary and backup fail closed without importing stale preferences',
    () async {
      await baseline();
      store.value = '{broken';
      store.backup = '{also broken';
      final recovered = await create();
      expect(recovered.storageError, contains('无法读取'));
      expect(store.value, '{broken');
      await expectLater(
        recovered.addSource(source(2)),
        throwsA(isA<SubscriptionStorageException>()),
      );
    },
  );
  test('50 sources accepted; 51st fails without changing snapshot', () async {
    final ui = await create();
    for (var mid = 1; mid <= 50; mid++) {
      await ui.addSource(source(mid));
    }
    final before = store.value;
    await expectLater(ui.addSource(source(51)), throwsStateError);
    expect(ui.sources.length, 50);
    expect(store.value, before);
  });

  test(
    'two concurrent engines discover and claim each item only once',
    () async {
      await baseline();
      content.pages[1] = [
        [item('new'), item('old')],
      ];
      final hold = Completer<void>();
      content.hold = hold;
      final a = await create(), b = await create();
      var notified = 0;
      a.notifySummary = b.notifySummary = (count) async {
        notified += count;
        return true;
      };
      final generation = store.generation;
      final both = Future.wait([
        a.runBackgroundCheck(generation),
        b.runBackgroundCheck(generation),
      ]);
      await Future<void>.delayed(Duration.zero);
      hold.complete();
      await both;
      await a.reload();
      expect(a.feed.length, 1);
      expect(notified, 1);
    },
  );

  test(
    'scheduling failure is visible and restart reconciliation can retry',
    () async {
      final ui = SubscriptionService(
        snapshotStore: store,
        contentService: content,
        backgroundScheduler: (_, _) async {
          throw StateError('scheduler unavailable');
        },
      );
      addTearDown(ui.dispose);
      await ui.initialize();
      await ui.setEnabled(true);
      await ui.setBackgroundRefreshEnabled(true);
      expect(ui.backgroundStatus, contains('安排失败'));
      expect(ui.backgroundRefreshEnabled, true);
      final restarted = await create();
      await restarted.reconcileBackgroundSchedule();
      expect(scheduled.last.$1, true);
    },
  );
  test(
    'CAS replay preserves scanned discoveries and concurrent read state',
    () async {
      await baseline();
      content.pages[1] = [
        [item('prior'), item('old')],
      ];
      final worker = await create();
      await worker.runBackgroundCheck(store.generation);
      now = now.add(const Duration(hours: 2));
      content.pages[1] = [
        [item('new'), item('prior'), item('old')],
      ];
      final readAt = now.toIso8601String();
      store.conflictOnce = (current, proposed) {
        final next = jsonDecode(proposed) as Map<String, dynamic>;
        if (!(next['feed'] as List).any((e) => (e as Map)['bvid'] == 'new')) {
          return null;
        }
        final latest = jsonDecode(current) as Map<String, dynamic>;
        for (final item in latest['feed'] as List) {
          if ((item as Map)['bvid'] == 'prior') item['readAt'] = readAt;
        }
        return jsonEncode(latest);
      };
      var notifications = 0;
      worker.notifySummary = (count) async {
        notifications += count;
        return true;
      };
      await worker.runBackgroundCheck(store.generation);
      expect(store.forcedConflicts, 1);
      expect(worker.feed.map((e) => e.bvid), containsAll(['new', 'prior']));
      expect(
        worker.feed
            .firstWhere((e) => e.bvid == 'prior')
            .readAt!
            .toIso8601String(),
        readAt,
      );
      expect(worker.checkpoint(source(1).key)!.seen, contains('new'));
      expect(notifications, 1);
      final restarted = await create();
      expect(restarted.feed.map((e) => e.bvid), contains('new'));
      expect(
        restarted.feed.firstWhere((e) => e.bvid == 'prior').readAt,
        isNotNull,
      );
      now = now.add(const Duration(hours: 2));
      restarted.notifySummary = worker.notifySummary;
      await restarted.runBackgroundCheck(store.generation);
      expect(notifications, 1);
    },
  );
}
