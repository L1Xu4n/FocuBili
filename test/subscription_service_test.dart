import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
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
  Future<CreatorContentPage<CreatorVideo>> page(int mid, int index) async {
    calls.add('$mid:$index');
    if (hold != null && (holdMid == null || holdMid == mid)) {
      await hold!.future;
    }
    if (index == failPage) throw StateError('429 / network');
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
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final service = SubscriptionService(
      contentService: content,
      preferencesLoader: () async => prefs,
      pageBudget: budget,
      clock: clock,
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
    'collection scans every page: old publication added on page2, reordering silent',
    () async {
      final c = Content()
        ..pages[1] = [
          [item('a')],
          [item('b')],
        ];
      final s = await create(c);
      await baseline(s, [source(1, collection: true)]);
      c.pages[1] = [
        [item('a')],
        [item('historical', publishedAt: DateTime(2010)), item('b')],
      ];
      await s.refresh(manual: true);
      expect(s.feed.single.bvid, 'historical');
      expect(s.feed.single.collectionAdded, true);
      await s.markRead('historical');
      c.pages[1] = [
        [item('b'), item('historical')],
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
    'half-page failure preserves cache and successful baseline; retries after backoff',
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
      expect(s.feed, isEmpty);
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
  test('creator known boundary includes overlapping following page', () async {
    final c = Content()
      ..pages[1] = [
        [item('a')],
        [item('b')],
        [item('c')],
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
    expect(c.calls, ['1:1', '1:2']);
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
      final resumed = s.refresh(manual: true);
      c.hold = null;
      hold.complete();
      await Future.wait([stale, resumed]);
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
}
