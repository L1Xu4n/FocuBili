import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/bilibili_lookup_exception.dart';
import 'package:focubili/services/subscription_history_store.dart';
import 'package:focubili/services/subscription_service.dart';
import 'learning_batch_test.dart' show RejectingPreferences;

CreatorVideo item(String bv, {DateTime? publishedAt}) => CreatorVideo(
  bvid: bv,
  title: bv,
  coverUrl: '',
  duration: const Duration(minutes: 1),
  publishedAt: publishedAt,
);
SubscriptionSource source(int mid, {bool collection = false}) =>
    SubscriptionSource(
      kind: collection ? SubscriptionKind.collection : SubscriptionKind.creator,
      mid: mid,
      seasonId: collection ? 100 : null,
      name: '源$mid',
      token: '$mid',
    );

class Content implements BilibiliPublicContentService {
  final Map<int, List<List<CreatorVideo>>> pages = {};
  final List<String> calls = [];
  int? failPage;
  Completer<void>? hold;
  int? holdMid;
  int? holdPage;
  Object? Function(int mid, int page)? failure;

  /// Serves a synthetic page with optional latency and structured failures.
  Future<CreatorContentPage<CreatorVideo>> page(int mid, int index) async {
    calls.add('$mid:$index');
    if (hold != null &&
        (holdMid == null || holdMid == mid) &&
        (holdPage == null || holdPage == index)) {
      await hold!.future;
    }
    if (index == failPage) throw StateError('429 / network');
    final error = failure?.call(mid, index);
    if (error != null) throw error;
    final data = pages[mid] ?? [[]];
    return CreatorContentPage(
      items: index <= data.length ? data[index - 1] : [],
      page: index,
      hasMore: index < data.length,
      totalCount: data.fold<int>(0, (n, e) => n + e.length),
    );
  }

  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) => this.page(mid, page);
  @override
  Future<CreatorContentPage<CreatorVideo>> loadCollectionVideos(
    int ownerMid,
    int collectionId, {
    int page = 1,
  }) => this.page(ownerMid, page);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<SubscriptionService> create(
    Content content, {
    int budget = 20,
    DateTime Function()? clock,
    SubscriptionHistoryStore? historyStore,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final service = SubscriptionService(
      contentService: content,
      preferencesLoader: () async => prefs,
      pageBudget: budget,
      clock: clock,
      historyStore: historyStore,
    );
    addTearDown(service.dispose);
    await service.initialize();
    return service;
  }

  Future<void> baseline(
    SubscriptionService service,
    List<SubscriptionSource> sources,
  ) async {
    for (final s in sources) {
      await service.addSource(s);
    }
    await service.setEnabled(true);
    service.setForeground(true);
    await service.refresh(manual: true);
  }

  test(
    'completed live coverage shortens the next scan and excludes history',
    () async {
      final now = DateTime(2026, 10, 4, 12);
      final c = Content();
      final old = List.generate(
        4,
        (i) => [
          item('old$i', publishedAt: now.subtract(const Duration(days: 1))),
        ],
      );
      final burst = List.generate(
        4,
        (page) => List.generate(
          20,
          (index) => item('new${page}_$index', publishedAt: now),
        ),
      );
      c.pages[1] = [...old, ...burst];
      final s = await create(c, clock: () => now);
      await baseline(s, [source(1)]);
      await s.startHistory(source(1).key, limit: null);
      expect(s.historyJob(source(1).key)!.ids, contains('new3_0'));
      expect(
        s.checkpoint(source(1).key)!.liveCoveredIds,
        isNot(contains('new3_0')),
      );
      c.pages[1] = [...burst, ...old];
      c.calls.clear();
      await s.refresh(manual: true);
      expect(c.calls, ['1:1', '1:2', '1:3', '1:4', '1:5', '1:6']);
      expect(
        s.feed.map((e) => e.bvid),
        containsAll(burst.expand((page) => page).map((video) => video.bvid)),
      );
      expect(s.checkpoint(source(1).key)!.liveCoveredIds, contains('new3_0'));

      c.pages[1] = [
        [
          item('later', publishedAt: now.add(const Duration(minutes: 1))),
          ...burst.first,
        ],
        ...burst.skip(1),
        ...old,
      ];
      c.calls.clear();
      await s.refresh(manual: true);
      expect(c.calls, ['1:1', '1:2', '1:3']);
      expect(s.feed.map((e) => e.bvid), contains('later'));
      final legacy = s.checkpoint(source(1).key)!.toJson()
        ..remove('liveCoveredIds')
        ..remove('consecutiveIdleScans');
      final restored = SourceCheckpoint.fromJson(legacy);
      expect(restored.liveCoveredIds, isEmpty);
      expect(restored.consecutiveIdleScans, 0);
    },
  );

  test('idle scans move from hourly to two and four hours, then reset', () async {
    var now = DateTime(2026, 10, 4);
    final c = Content()
      ..pages[1] = [
        [item('old')],
      ];
    final s = await create(c, clock: () => now);
    await baseline(s, [source(1)]);

    /// Advances the injected clock and checks calls through the automatic path.
    Future<void> advance(int hours, {required bool due}) async {
      now = now.add(Duration(hours: hours));
      final calls = c.calls.length;
      await s.refresh();
      expect(c.calls.length - calls, due ? 1 : 0);
    }

    expect(s.checkpoint(source(1).key)!.consecutiveIdleScans, 0);
    await advance(1, due: true);
    await advance(1, due: true);
    expect(s.checkpoint(source(1).key)!.consecutiveIdleScans, 2);
    await advance(1, due: false);
    await advance(1, due: true);
    await advance(2, due: true);
    expect(s.checkpoint(source(1).key)!.consecutiveIdleScans, 4);
    await advance(3, due: false);
    await advance(1, due: true);
    c.pages[1] = [
      [item('new', publishedAt: now), item('old')],
    ];
    await s.refresh(manual: true);
    expect(s.checkpoint(source(1).key)!.consecutiveIdleScans, 0);
    await advance(1, due: true);
  });

  for (final error in [
    const BilibiliLookupException('risk', httpStatus: 412),
    const BilibiliLookupException('risk', apiCode: -352),
  ]) {
    test(
      'risk ${error.httpStatus ?? error.apiCode} pauses the site for five minutes',
      () async {
        var now = DateTime(2026, 10, 4);
        final c = Content()
          ..pages[2] = [
            [item('ok2')],
          ]
          ..pages[3] = [
            [item('ok3')],
          ]
          ..failure = (mid, _) => mid != 2 ? error : null;
        final s = await create(c, clock: () => now);
        await baseline(s, [source(1), source(2), source(3)]);
        expect(c.calls, contains('1:1'));
        expect(c.calls, isNot(contains('3:1')));
        c.calls.clear();
        now = now.add(const Duration(minutes: 4, seconds: 59));
        await s.retrySource(source(1).key);
        await s.refresh(manual: true);
        expect(c.calls, isEmpty);

        now = now.add(const Duration(seconds: 1));
        final hold = Completer<void>();
        c
          ..failure = null
          ..hold = hold;
        final round = s.refresh(manual: true);
        await Future<void>.delayed(Duration.zero);
        expect(c.calls, ['1:1']);
        hold.complete();
        await round;
        c.hold = null;
        await s.refresh(manual: true);
        expect(s.checkpoint(source(3).key)!.initialized, isTrue);
      },
    );
  }

  test(
    'deleting a source reclaims its history directory after commit',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'focubili-history-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final storage = FileSubscriptionHistoryStore(directory: () async => root);
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ]
        ..pages[2] = [
          [item('kept')],
        ];
      final now = DateTime(2026, 10, 4);
      final s = await create(c, clock: () => now, historyStore: storage);
      await baseline(s, [source(1), source(2)]);
      final shared = item('shared', publishedAt: now);
      c.pages[1]!.first.insert(0, shared);
      c.pages[2]!.first.insert(0, shared);
      await s.refresh(manual: true);
      expect(s.feed.single.sources, hasLength(2));
      await s.startHistory(source(1).key);
      await s.startHistory(source(2).key);
      final deleted = s.historyJob(source(1).key)!.id;
      final kept = s.historyJob(source(2).key)!.id;
      final folder = Directory('${root.path}/subscription-history/$deleted');
      expect(await folder.exists(), isTrue);
      await s.deleteSources({source(1).key});
      expect(s.historyJob(source(1).key), isNull);
      expect(await folder.exists(), isFalse);
      expect(await storage.read(kept, 0), isNotNull);
      expect(s.feed.single.bvid, 'shared');
    },
  );

  testWidgets('resuming supersedes a deferred inactive transition', (
    tester,
  ) async {
    final c = Content()
      ..pages[1] = [
        [item('old')],
      ];
    final s = await create(c);
    await baseline(s, [source(1)]);
    s.scheduleBackground();
    await tester.pump(const Duration(seconds: 2));
    s.setForeground(true);
    await tester.pump(const Duration(seconds: 2));
    final beforeManual = c.calls.length;
    await s.refresh(manual: true);
    expect(c.calls.length, beforeManual + 1);
    s.scheduleBackground();
    await tester.pump(const Duration(seconds: 3));
    await s.refresh(manual: true);
    expect(c.calls.length, beforeManual + 1);
  });

  test(
    'source and focus opt-in are saved atomically without notifications',
    () async {
      var reject = false;
      final prefs = await SharedPreferences.getInstance();
      final service = SubscriptionService(
        contentService: Content(),
        preferencesLoader: () async => reject
            ? RejectingPreferences(prefs, SubscriptionService.storageKey)
            : prefs,
      );
      addTearDown(service.dispose);
      await service.initialize();
      reject = true;
      await expectLater(
        service.addSource(source(1), enableFocus: true),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(service.sources, isEmpty);
      expect(service.enabled, isFalse);

      reject = false;
      await service.addSource(source(1), enableFocus: true);
      final reopened = await create(Content());
      expect(reopened.sources.single.key, 'creator:1');
      expect(reopened.enabled, isTrue);
      expect(reopened.notificationsEnabled, isFalse);
    },
  );

  test(
    'off by default, no network until explicit enabled + foreground',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final s = await create(c);
      s.setForeground(true);
      await s.refresh(manual: true);
      expect(s.enabled, false);
      expect(c.calls, isEmpty);
      await s.addSource(source(1));
      await s.refresh(manual: true);
      expect(c.calls, isEmpty);
      await s.setEnabled(true);
      await s.refresh(manual: true);
      expect(s.feed, isEmpty);
      expect(s.checkpoint('creator:1')!.initialized, true);
      await s.setEnabled(false);
      final count = c.calls.length;
      await s.refresh(manual: true);
      expect(c.calls.length, count);
    },
  );
  test(
    'first full baseline silent, cross-source BV merges one unread card + one summary',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ]
        ..pages[2] = [
          [item('old')],
        ];
      final s = await create(c);
      var notifications = 0, count = 0;
      s.notifySummary = (n) async {
        notifications++;
        count = n;
        return true;
      };
      await s.setNotificationsEnabled(true);
      await baseline(s, [source(1), source(2)]);
      expect(s.feed, isEmpty);
      expect(notifications, 0);
      c.pages[1] = [
        [item('new'), item('old')],
      ];
      c.pages[2] = [
        [item('new'), item('old')],
      ];
      await s.refresh(manual: true);
      expect(s.feed.length, 1);
      expect(s.feed.single.sources.length, 2);
      expect(s.unreadCount, 1);
      expect(notifications, 1);
      expect(count, 1);
      await s.markRead('new');
      await s.refresh(manual: true);
      expect(s.unreadCount, 0);
      expect(notifications, 1);
    },
  );
  test(
    'collection scans page 2 for recent additions and never reannounces after reordering',
    () async {
      final now = DateTime.utc(2026, 10, 14);
      final c = Content()
        ..pages[1] = [
          [item('a')],
          [item('b')],
        ];
      final s = await create(c, clock: () => now);
      await baseline(s, [source(1, collection: true)]);
      c.pages[1] = [
        [item('a')],
        [
          item('recent', publishedAt: now.subtract(const Duration(days: 9))),
          item('b'),
        ],
      ];
      await s.refresh(manual: true);
      expect(s.feed.single.bvid, 'recent');
      expect(s.feed.single.collectionAdded, true);
      await s.markRead('recent');
      c.pages[1] = [
        [item('b'), item('recent')],
        [item('a')],
      ];
      await s.refresh(manual: true);
      expect(s.feed.length, 1);
      expect(s.unreadCount, 0);
      await s.clearDisplayCache();
      await s.refresh(manual: true);
      expect(s.feed, isEmpty);
    },
  );
  test(
    'page failure preserves committed discoveries and the last complete checkpoint',
    () async {
      var now = DateTime(2026);
      final c = Content()
        ..pages[1] = [
          [item('old')],
          [item('old2')],
        ];
      final s = await create(c, clock: () => now);
      await baseline(s, [source(1, collection: true)]);
      final last = s.checkpoint('collection:1:100')!.lastSuccess;
      c.pages[1] = [
        [item('new'), item('old')],
        [item('old2')],
      ];
      c.failPage = 2;
      await s.refresh(manual: true);
      final cp = s.checkpoint('collection:1:100')!;
      expect(cp.partial, true);
      expect(cp.lastSuccess, last);
      expect(s.feed.single.bvid, 'new');
      final calls = c.calls.length;
      await s.refresh(manual: true);
      expect(c.calls.length, calls);
      c.failPage = null;
      now = now.add(const Duration(hours: 1));
      await s.refresh(manual: true);
      expect(s.feed.single.bvid, 'new');
      expect(s.checkpoint('collection:1:100')!.partial, false);
    },
  );
  test(
    'explicit source retry resumes a transient failure without waiting for backoff',
    () async {
      var now = DateTime(2026);
      final c = Content()
        ..pages[1] = [
          [item('old1')],
          [item('old2')],
        ]
        ..pages[2] = [
          [item('other-source')],
        ];
      final s = await create(c, clock: () => now);
      await baseline(s, [source(1), source(2)]);
      c.pages[1] = [
        [item('new1')],
        [item('new2')],
        [item('new3')],
        [item('new4'), item('old2')],
      ];
      c.failPage = 4;
      await s.refresh(manual: true);
      expect(s.checkpoint('creator:1')!.nextPage, 4);
      expect(s.checkpoint('creator:1')!.retryAt, isNotNull);
      expect(s.feed.map((item) => item.bvid), ['new1', 'new2', 'new3']);

      c.failPage = null;
      c.calls.clear();
      now = now.add(const Duration(seconds: 30));
      await s.retrySource('creator:1');
      expect(c.calls, ['1:1', '1:3', '1:4']);
      expect(s.checkpoint('creator:1')!.lastSuccess, now);
      expect(s.checkpoint('creator:1')!.partial, isFalse);
      expect(s.checkpoint('creator:1')!.retryAt, isNull);
      expect(s.feed.map((item) => item.bvid), ['new4', 'new1', 'new2', 'new3']);
    },
  );

  test(
    'mark all read suppresses a pending notification even after display eviction',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('old1')],
          [item('old2')],
        ];
      final s = await create(c);
      await s.setNotificationsEnabled(true);
      await baseline(s, [source(1)]);
      final notifications = <String>[];
      s.notifyItems = (items) async {
        notifications.addAll(items.map((item) => item.bvid));
        return true;
      };
      c.pages[1] = [
        [item('read-before-notify'), item('old1')],
        [
          for (var i = 0; i < SubscriptionService.displayLimit; i++)
            item('new-$i'),
        ],
      ];
      c.holdPage = 2;
      final gate = c.hold = Completer<void>();
      final round = s.refresh(manual: true);
      await Future<void>.delayed(Duration.zero);
      expect(c.calls.last, '1:2');
      expect(s.feed.single.bvid, 'read-before-notify');
      await s.markAllRead();
      expect(s.unreadCount, 0);
      gate.complete();
      await round;

      expect(s.feed, hasLength(SubscriptionService.displayLimit));
      expect(
        s.feed.map((item) => item.bvid),
        isNot(contains('read-before-notify')),
      );
      expect(notifications, hasLength(SubscriptionService.displayLimit));
      expect(notifications, isNot(contains('read-before-notify')));
    },
  );

  test(
    'initial partial baseline persists across restart and never emits historical cards',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('a')],
          [item('b')],
          [item('c')],
        ];
      final s = await create(c, budget: 1);
      await baseline(s, [source(1, collection: true)]);
      expect(s.checkpoint('collection:1:100')!.initialized, false);
      expect(s.checkpoint('collection:1:100')!.nextPage, 2);
      s.setForeground(false);
      final restored = await create(c, budget: 1);
      restored.setForeground(true);
      await restored.refresh(manual: true);
      await restored.refresh(manual: true);
      expect(restored.checkpoint('collection:1:100')!.initialized, true);
      expect(restored.feed, isEmpty);
    },
  );
  test('creator does not stop at one known BV in a mixed page', () async {
    final c = Content()
      ..pages[1] = [
        [item('a')],
        [item('b'), item('c')],
      ];
    final s = await create(c);
    await baseline(s, [source(1)]);
    c.calls.clear();
    c.pages[1] = [
      [item('new'), item('a')],
      [item('late'), item('b')],
      [item('c')],
    ];
    await s.refresh(manual: true);
    expect(c.calls, ['1:1', '1:2', '1:3']);
    expect(s.feed.map((e) => e.bvid).toSet(), {'new', 'late'});
  });
  for (final action in ['disable', 'delete', 'pause', 'background']) {
    test(
      '$action cancels delayed result; no subsequent request or feed write',
      () async {
        final c = Content()
          ..pages[1] = [
            [item('old')],
          ];
        final s = await create(c);
        await baseline(s, [source(1)]);
        c.pages[1] = [
          [item('new'), item('old')],
        ];
        c.hold = Completer<void>();
        final refresh = s.refresh(manual: true);
        await Future<void>.delayed(Duration.zero);
        if (action == 'disable') await s.setEnabled(false);
        if (action == 'delete') await s.deleteSource('creator:1');
        if (action == 'pause') await s.pauseSource('creator:1', true);
        if (action == 'background') s.setForeground(false);
        final calls = c.calls.length;
        c.hold!.complete();
        await refresh;
        expect(s.feed, isEmpty);
        expect(c.calls.length, calls);
        if (action == 'delete') expect(s.sources, isEmpty);
      },
    );
  }
  test(
    'focus only badge, notification error never drops unread, auto < hour skipped',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final s = await create(c);
      var notifications = 0;
      s.notifySummary = (_) async {
        notifications++;
        throw StateError('permission revoked');
      };
      await s.setNotificationsEnabled(true);
      await baseline(s, [source(1)]);
      final calls = c.calls.length;
      await s.refresh();
      expect(c.calls.length, calls);
      s.suppressNotifications = () => true;
      c.pages[1] = [
        [item('new'), item('old')],
      ];
      await s.refresh(manual: true);
      expect(notifications, 0);
      expect(s.unreadCount, 1);
      s.suppressNotifications = () => false;
      c.pages[1] = [
        [item('new2'), item('new'), item('old')],
      ];
      await s.refresh(manual: true);
      expect(notifications, 1);
      expect(s.unreadCount, 2);
      await s.refresh(manual: true);
      expect(notifications, 1);
    },
  );
  test(
    'corrupt primary restores valid backup and quarantines; no cookies or play URL stored',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final s = await create(c);
      await baseline(s, [source(1)]);
      await s.markAllRead();
      s.setForeground(false);
      final prefs = await SharedPreferences.getInstance();
      final backup = prefs.getString(SubscriptionService.backupKey)!;
      await prefs.setString(SubscriptionService.storageKey, '{broken');
      final restored = await create(c);
      expect(restored.sources.length, 1);
      expect(restored.storageError, contains('恢复'));
      expect(
        prefs.getString('${SubscriptionService.storageKey}_quarantine'),
        '{broken',
      );
      expect(jsonDecode(backup), isA<Map>());
      expect(backup, isNot(contains('cookie')));
    },
  );
  test(
    'storage failure rolls back, read failure cannot empty-overwrite data',
    () async {
      final c = Content();
      final prefs = await SharedPreferences.getInstance();
      final s = SubscriptionService(
        contentService: c,
        preferencesLoader: () async =>
            RejectingPreferences(prefs, SubscriptionService.storageKey),
      );
      addTearDown(s.dispose);
      await s.initialize();
      await expectLater(
        s.addSource(source(1)),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(s.sources, isEmpty);
      expect(prefs.getString(SubscriptionService.storageKey), null);
      await prefs.remove(SubscriptionService.backupKey);
      await prefs.setString(SubscriptionService.storageKey, '{bad');
      final unreadable = await create(c);
      await expectLater(
        unreadable.setEnabled(true),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(prefs.getString(SubscriptionService.storageKey), '{bad');
    },
  );
  test(
    'resume during canceled HTTP queues a fresh round before callers finish',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final s = await create(c);
      await baseline(s, [source(1)]);
      c.pages[1] = [
        [item('new'), item('old')],
      ];
      final hold = Completer<void>();
      c.hold = hold;
      final stale = s.refresh(manual: true);
      await Future<void>.delayed(Duration.zero);
      s.setForeground(false);
      s.setForeground(true);
      c.hold = null;
      hold.complete();
      // Production only invokes automatic refresh on resume; manual intent
      // must come from the invalidated user-requested round.
      await stale;
      expect(s.feed.map((e) => e.bvid), ['new']);
      expect(c.calls.where((e) => e == '1:1').length, greaterThanOrEqualTo(3));
    },
  );

  test(
    'source added mid-round receives silent baseline and merges existing card',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final s = await create(c);
      await baseline(s, [source(1)]);
      c.pages[1] = [
        [item('new'), item('old')],
      ];
      await s.refresh(manual: true);
      await s.markRead('new');
      final readAt = s.feed.single.readAt;
      c.pages[2] = [
        [item('new'), item('historic')],
      ];
      final hold = Completer<void>();
      c.hold = hold;
      final round = s.refresh(manual: true);
      await Future<void>.delayed(Duration.zero);
      await s.addSource(source(2, collection: true));
      c.hold = null;
      hold.complete();
      await round;
      expect(s.checkpoint('collection:2:100')!.initialized, true);
      expect(s.feed.length, 1);
      expect(s.feed.single.sources.length, 2);
      expect(s.feed.single.collectionAdded, true);
      expect(s.feed.single.readAt, readAt);
      expect(s.unreadCount, 0);
      expect(c.calls.where((e) => e == '1:1').length, 3);
    },
  );
  test(
    'unresponsive source times out while independent source completes baseline',
    () async {
      final held = Completer<void>();
      final c = Content()
        ..pages[1] = [
          [item('blocked')],
        ]
        ..pages[2] = [
          [item('healthy')],
        ]
        ..hold = held
        ..holdMid = 1;
      final s = SubscriptionService(
        contentService: c,
        requestTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(s.dispose);
      await s.initialize();
      await s.addSource(source(1));
      await s.addSource(source(2));
      await s.setEnabled(true);
      s.setForeground(true);
      await s.refresh(manual: true);
      expect(s.checkpoint('creator:1')!.initialized, false);
      expect(s.checkpoint('creator:1')!.retryAt, isNotNull);
      expect(s.checkpoint('creator:2')!.initialized, true);
      expect(s.feed, isEmpty);
      s.setForeground(false);
      held.complete();
    },
  );
  testWidgets(
    'failed disable write restores enabled state and hourly polling',
    (tester) async {
      var now = DateTime(2026, 10, 4), reject = false;
      final prefs = await SharedPreferences.getInstance();
      final c = Content()
        ..pages[1] = [
          [item('old')],
        ];
      final s = SubscriptionService(
        contentService: c,
        clock: () => now,
        preferencesLoader: () async => reject
            ? RejectingPreferences(prefs, SubscriptionService.storageKey)
            : prefs,
      );
      await s.initialize();
      await baseline(s, [source(1)]);
      final calls = c.calls.length;
      reject = true;
      await expectLater(
        s.setEnabled(false),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(s.enabled, true);
      reject = false;
      now = now.add(const Duration(hours: 1));
      await tester.pump(const Duration(hours: 1));
      await tester.pumpAndSettle();
      expect(c.calls.length, greaterThan(calls));
      expect(s.checkpoint('creator:1')!.lastSuccess, now);
      s.dispose();
      await tester.pump();
    },
  );
  for (final action in ['disable', 'pause', 'delete']) {
    test(
      '$action write rollback replaces the invalidated manual scan',
      () async {
        var reject = false;
        final prefs = await SharedPreferences.getInstance();
        final c = Content()
          ..pages[1] = [
            [item('old')],
          ];
        final s = SubscriptionService(
          contentService: c,
          preferencesLoader: () async => reject
              ? RejectingPreferences(prefs, SubscriptionService.storageKey)
              : prefs,
        );
        addTearDown(s.dispose);
        await s.initialize();
        await baseline(s, [source(1)]);
        final lastSuccess = s.checkpoint('creator:1')!.lastSuccess;
        c.pages[1] = [
          [item('new'), item('old')],
        ];
        final hold = Completer<void>();
        c.hold = hold;
        final pending = s.refresh(manual: true);
        await Future<void>.delayed(Duration.zero);
        final calls = c.calls.length;
        reject = true;
        final mutation = switch (action) {
          'disable' => s.setEnabled(false),
          'pause' => s.pauseSource('creator:1', true),
          _ => s.deleteSource('creator:1'),
        };
        await expectLater(
          mutation,
          throwsA(isA<SubscriptionStorageException>()),
        );
        expect(s.enabled, true);
        expect(s.sources.single.paused, false);
        expect(s.checkpoint('creator:1')!.lastSuccess, lastSuccess);
        reject = false;
        c.hold = null;
        hold.complete();
        await pending;
        // No extra manual request or lifecycle event: rollback itself queues it.
        expect(c.calls.length, calls + 1);
        expect(s.feed.single.bvid, 'new');
        final stored = jsonDecode(
          prefs.getString(SubscriptionService.storageKey)!,
        );
        expect((stored['feed'] as List).single['bvid'], 'new');
      },
    );
  }
}
