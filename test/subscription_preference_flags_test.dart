import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription_history.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/subscription_history_store.dart';
import 'package:focubili/services/subscription_service.dart';

import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;

const flagKeys = {
  'enabled',
  'notificationsEnabled',
  'backgroundRefreshEnabled',
};
const disabledFlags = {
  'enabled': false,
  'notificationsEnabled': false,
  'backgroundRefreshEnabled': false,
};

class _ReadOnlyPreferences extends Fake implements SharedPreferences {
  _ReadOnlyPreferences(String? raw)
    : values = {SubscriptionService.storageKey: ?raw};
  final Map<String, String> values;
  final reads = <String>[];
  int reloads = 0, writes = 0;
  @override
  Future<void> reload() async {
    reloads++;
  }

  @override
  String? getString(String key) {
    reads.add(key);
    return values[key];
  }

  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    throw StateError('Preference export must not write');
  }

  @override
  Future<bool> remove(String key) async {
    writes++;
    throw StateError('Preference export must not remove');
  }
}

class _NoHistory implements SubscriptionHistoryStore {
  int reads = 0, writes = 0;
  @override
  Future<SubscriptionHistoryBatch?> read(String job, int batch) async {
    reads++;
    throw StateError('Preference export must not read history');
  }

  @override
  Future<void> write(
    String job,
    int batch,
    SubscriptionHistoryBatch value,
  ) async {
    writes++;
    throw StateError('Preference export must not write history');
  }
}

class _NoContent extends Fake implements BilibiliPublicContentService {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Preference export must not request content');
  }
}

class _ReadOnlySnapshots extends CountingSnapshots {
  int recoveries = 0;
  @override
  Future<String?> recover(bool Function(String) validate) async {
    recoveries++;
    throw StateError('Preference export must not recover');
  }
}

class _ColdService extends SubscriptionService {
  _ColdService({
    required super.preferencesLoader,
    required super.contentService,
    required super.historyStore,
    super.snapshotStore,
    super.backgroundScheduler,
  });
  int initializations = 0;
  @override
  Future<void> initialize() async {
    initializations++;
    throw StateError('Preference export must not initialize');
  }
}

class _Fixture {
  _Fixture(String? raw, {this.snapshots}) : prefs = _ReadOnlyPreferences(raw) {
    service = _ColdService(
      preferencesLoader: () async {
        loads++;
        return prefs;
      },
      snapshotStore: snapshots,
      contentService: content,
      historyStore: history,
      backgroundScheduler: (_, _) async {
        schedules++;
      },
    );
    service.addListener(() => notifications++);
    addTearDown(service.dispose);
  }
  final _ReadOnlyPreferences prefs;
  final _ReadOnlySnapshots? snapshots;
  final content = _NoContent();
  final history = _NoHistory();
  late final _ColdService service;
  int loads = 0, schedules = 0, notifications = 0;

  void expectReadOnly() {
    expect(service.initializations, 0);
    expect(prefs.writes, 0);
    expect(
      prefs.reads.every((key) => key == SubscriptionService.storageKey),
      isTrue,
    );
    expect(history.reads, 0);
    expect(history.writes, 0);
    expect(content.calls, 0);
    expect(schedules, 0);
    expect(notifications, 0);
    if (snapshots != null) {
      expect(snapshots!.transactions, 0);
      expect(snapshots!.saves, 0);
      expect(snapshots!.recoveries, 0);
    }
  }
}

class _DelayedCommitSnapshots extends _ReadOnlySnapshots {
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<String?> read() async {
    // Like a DB read outside a pending transaction, this can return the old
    // committed value. The API itself must await the service write barrier.
    reads++;
    return value;
  }

  @override
  Future<T> transact<T>(
    FutureOr<T> Function(String?, void Function(String)) action,
  ) => super.transact((current, save) async {
    if (gate != null) {
      if (!entered!.isCompleted) entered!.complete();
      await gate!.future;
    }
    return action(current, save);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'empty storage defaults all flags without creating a preference or DB snapshot',
    () async {
      final store = _ReadOnlySnapshots();
      final fixture = _Fixture(null, snapshots: store);
      final flags = await fixture.service.exportPreferenceFlags();
      expect(flags, disabledFlags);
      expect(() => flags['enabled'] = true, throwsUnsupportedError);
      expect(fixture.prefs.values, isEmpty);
      expect(store.value, isNull);
      fixture.expectReadOnly();
    },
  );

  for (final version in [1, 2]) {
    test(
      'legacy version $version reads all boolean combinations without migration or content access',
      () async {
        for (var bits = 0; bits < 8; bits++) {
          final flags = {
            'enabled': bits & 1 != 0,
            'notificationsEnabled': bits & 2 != 0,
            'backgroundRefreshEnabled': bits & 4 != 0,
          };
          final raw = jsonEncode({
            'version': version,
            ...flags,
            'sources': 'UNSELECTED_SOURCE_CONTENT',
            'feed': {'malformed': 'UNSELECTED_FEED_CONTENT'},
            'historyJobs': ['UNSELECTED_HISTORY_METADATA'],
          });
          final fixture = _Fixture(raw);
          final exported = await fixture.service.exportPreferenceFlags();
          expect(exported, flags);
          expect(exported.keys.toSet(), flagKeys);
          expect(jsonEncode(exported), isNot(contains('UNSELECTED_')));
          expect(fixture.service.enabled, isFalse);
          expect(fixture.service.sources, isEmpty);
          expect(fixture.service.feed, isEmpty);
          expect(fixture.prefs.values, {SubscriptionService.storageKey: raw});
          expect(fixture.prefs.reloads, 1);
          fixture.expectReadOnly();
        }
      },
    );
  }

  test('missing flags default independently to false', () async {
    for (final key in flagKeys) {
      final fixture = _Fixture(jsonEncode({'version': 2, key: true}));
      expect(await fixture.service.exportPreferenceFlags(), {
        ...disabledFlags,
        key: true,
      });
      fixture.expectReadOnly();
    }
  });

  test(
    'authoritative DB flags win without even opening legacy preferences',
    () async {
      final store = _ReadOnlySnapshots()
        ..value = jsonEncode({
          'version': 2,
          'enabled': true,
          'notificationsEnabled': true,
        });
      final fixture = _Fixture('{broken legacy JSON', snapshots: store);
      expect(await fixture.service.exportPreferenceFlags(), {
        ...disabledFlags,
        'enabled': true,
        'notificationsEnabled': true,
      });
      expect(fixture.loads, 0);
      expect(fixture.prefs.reloads, 0);
      expect(store.reads, 1);
      fixture.expectReadOnly();
    },
  );

  test(
    'a missing DB snapshot falls back to legacy without saving or recovery',
    () async {
      final store = _ReadOnlySnapshots();
      final fixture = _Fixture(
        jsonEncode({'version': 1, 'enabled': true}),
        snapshots: store,
      );
      expect(
        (await fixture.service.exportPreferenceFlags())['enabled'],
        isTrue,
      );
      expect(store.reads, 1);
      expect(fixture.loads, 1);
      expect(store.value, isNull);
      fixture.expectReadOnly();
    },
  );

  test(
    'malformed authoritative DB is not replaced with a valid legacy snapshot',
    () async {
      final store = _ReadOnlySnapshots()..value = jsonEncode({'version': 99});
      final fixture = _Fixture(jsonEncode({'version': 1}), snapshots: store);
      await expectLater(
        fixture.service.exportPreferenceFlags(),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(fixture.loads, 0);
      expect(store.value, jsonEncode({'version': 99}));
      fixture.expectReadOnly();
    },
  );

  test(
    'known storage failure rejects before reading either backing store',
    () async {
      final store = _ReadOnlySnapshots()..value = jsonEncode({'version': 2});
      final fixture = _Fixture(null, snapshots: store);
      fixture.service.storageError = 'synthetic prior storage failure';
      await expectLater(
        fixture.service.exportPreferenceFlags(),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(fixture.loads, 0);
      expect(store.reads, 0);
      fixture.expectReadOnly();
    },
  );

  test(
    'malformed JSON and non-map roots are rejected without repair',
    () async {
      for (final raw in ['{broken', 'null', '[]', 'true', '42', '"text"']) {
        final fixture = _Fixture(raw);
        await expectLater(
          fixture.service.exportPreferenceFlags(),
          raw == '{broken'
              ? throwsFormatException
              : throwsA(isA<SubscriptionStorageException>()),
        );
        expect(fixture.prefs.values[SubscriptionService.storageKey], raw);
        fixture.expectReadOnly();
      }
    },
  );

  test(
    'missing, future, fractional and wrongly typed versions are rejected',
    () async {
      for (final version in <Object?>[null, 0, 3, 1.0, 1.5, '2', true, []]) {
        final fixture = _Fixture(jsonEncode({'version': version}));
        await expectLater(
          fixture.service.exportPreferenceFlags(),
          throwsA(isA<SubscriptionStorageException>()),
        );
        fixture.expectReadOnly();
      }
      final fixture = _Fixture('{}');
      await expectLater(
        fixture.service.exportPreferenceFlags(),
        throwsA(isA<SubscriptionStorageException>()),
      );
      fixture.expectReadOnly();
    },
  );

  for (final key in flagKeys) {
    test('$key rejects explicit null and every non-boolean shape', () async {
      for (final value in <Object?>[null, 0, 1, 'true', [], {}]) {
        final fixture = _Fixture(jsonEncode({'version': 2, key: value}));
        await expectLater(
          fixture.service.exportPreferenceFlags(),
          throwsA(isA<SubscriptionStorageException>()),
        );
        fixture.expectReadOnly();
      }
    });
  }

  test(
    'unselected bad feed permits flags but complete content export remains strict',
    () async {
      final fixture = _Fixture(
        jsonEncode({
          'version': 2,
          'enabled': true,
          'sources': [],
          'checkpoints': {},
          'feed': 'malformed',
          'historyJobs': {'invalid': 'unread'},
        }),
      );
      expect(
        (await fixture.service.exportPreferenceFlags())['enabled'],
        isTrue,
      );
      await expectLater(
        fixture.service.exportLocalData(),
        throwsA(isA<SubscriptionStorageException>()),
      );
      fixture.expectReadOnly();
    },
  );

  for (final rejectCommit in [false, true]) {
    test(
      'flags await an existing ${rejectCommit ? 'failed' : 'successful'} write before reading',
      () async {
        final seed = jsonDecode(feedFixture(count: 0, sourceCount: 0)) as Map;
        seed['version'] = 2;
        seed['enabled'] = false;
        final store = _DelayedCommitSnapshots()..value = jsonEncode(seed);
        final prefs = _ReadOnlyPreferences(null);
        final history = _NoHistory();
        final content = _NoContent();
        var schedules = 0;
        final service = SubscriptionService(
          preferencesLoader: () async => prefs,
          snapshotStore: store,
          historyStore: history,
          contentService: content,
          backgroundScheduler: (_, _) async {
            schedules++;
          },
        );
        addTearDown(service.dispose);
        // Only fixture setup initializes; the method under test must not do so.
        await service.initialize();
        expect(service.storageError, isNull);
        store.resetCounts();
        schedules = 0;
        store.gate = Completer<void>();
        store.entered = Completer<void>();
        store.failCommit = rejectCommit;
        addTearDown(() {
          if (!store.gate!.isCompleted) store.gate!.complete();
        });
        final write = service.setEnabled(true);
        await store.entered!.future;
        var finished = false;
        final read = service.exportPreferenceFlags().whenComplete(
          () => finished = true,
        );
        final rejectedRead = rejectCommit
            ? expectLater(read, throwsA(isA<SubscriptionStorageException>()))
            : null;
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        expect(store.reads, 0);
        store.gate!.complete();
        if (rejectCommit) {
          await expectLater(
            write,
            throwsA(isA<SubscriptionStorageException>()),
          );
          await rejectedRead;
          expect(store.reads, 0);
        } else {
          await write;
          expect((await read)['enabled'], isTrue);
          expect(store.reads, 1);
        }
        expect(store.transactions, 1);
        expect(schedules, 1); // Only the explicit setEnabled fixture operation.
        expect(prefs.writes, 0);
        expect(history.reads, 0);
        expect(history.writes, 0);
        expect(content.calls, 0);
      },
    );
  }
}
