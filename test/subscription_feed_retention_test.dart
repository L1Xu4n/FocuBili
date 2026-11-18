import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/subscription_notification_delivery.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_performance_probe_test.dart' show CountingSnapshots;
import 'subscription_service_test.dart' show Content, item, source;

final _start = DateTime.utc(2026, 10, 20, 12);

Map<String, dynamic> _data(
  List<SubscriptionFeedItem> feed, {
  List<SubscriptionSource> sources = const [],
  bool enabled = false,
  bool notifications = false,
}) => {
  'version': 2,
  'enabled': enabled,
  'notificationsEnabled': notifications,
  'backgroundRefreshEnabled': false,
  'sources': [for (final source in sources) source.toJson()],
  'checkpoints': {
    for (final source in sources)
      source.key: SourceCheckpoint(
        algorithm: 3,
        initialized: true,
        fullBaseline: true,
        baselineAt: _start,
        lastSuccess: _start,
      ).toJson(),
  },
  'feed': [for (final row in feed) row.toJson()],
  'announced': <String>[],
  'notificationClaims': <String>[],
};

SubscriptionFeedItem _row(
  String id, {
  DateTime? found,
  DateTime? published,
  DateTime? read,
  SubscriptionSource? origin,
}) => SubscriptionFeedItem(
  bvid: id,
  title: id,
  coverUrl: '',
  sources: {if (origin != null) origin.key: origin.name},
  discoveredAt: found ?? _start,
  publishedAt: published,
  readAt: read,
);

Future<void> _waitUntil(bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition did not become true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a corrected earlier publication persists and sets the cutoff after restart',
    () async {
      var now = _start;
      final a = source(1, collection: true);
      final b = source(2, collection: true);
      final content = Content()
        ..pages[a.mid] = [
          [item('dated')],
        ]
        ..pages[b.mid] = [[]];
      final store = CountingSnapshots()
        ..value = jsonEncode(_data([], sources: [a, b], enabled: true));
      final service = SubscriptionService(
        snapshotStore: store,
        clock: () => now,
        contentService: content,
      );
      addTearDown(service.dispose);
      await service.initialize();
      service.setForeground(true);
      await service.refresh(manual: true);
      expect(service.feed.single.publishedAt, isNull);

      now = _start.add(const Duration(hours: 2));
      final earlier = _start.subtract(const Duration(days: 13));
      content.pages[b.mid] = [
        [item('dated', publishedAt: earlier)],
      ];
      await service.refresh(manual: true);
      expect(service.feed.single.publishedAt, earlier);
      expect(service.feed.single.discoveredAt, _start);
      expect(service.feed.single.sources.keys, unorderedEquals([a.key, b.key]));

      // An undated or contradictory future observation must not postpone expiry.
      content.pages[b.mid] = [
        [item('dated', publishedAt: _start.add(const Duration(days: 30)))],
      ];
      await service.refresh(manual: true);
      expect(service.feed.single.publishedAt, earlier);
      final restart = SubscriptionService(
        snapshotStore: store,
        clock: () => now,
      );
      addTearDown(restart.dispose);
      now = _start.add(const Duration(days: 1));
      await restart.initialize();
      expect(restart.feed.single.bvid, 'dated');
      now = now.add(const Duration(microseconds: 1));
      await restart.reload();
      expect(restart.feed, isEmpty);
      expect(restart.unreadCount, 0);
      expect((jsonDecode(store.value!) as Map)['announced'], contains('dated'));
    },
  );

  test(
    'cold export preserves raw rows; cold browse uses strict content age for read and unread',
    () async {
      final origin = source(1);
      final cutoff = _start.subtract(const Duration(days: 14));
      final store = CountingSnapshots()
        ..value = jsonEncode(
          _data(
            [
              _row(
                'too-old-unread',
                published: cutoff.subtract(const Duration(microseconds: 1)),
                origin: origin,
              ),
              _row(
                'too-old-read',
                found: cutoff.subtract(const Duration(microseconds: 1)),
                read: _start,
                origin: origin,
              ),
              _row(
                'exact-read',
                published: cutoff,
                read: _start,
                origin: origin,
              ),
              _row('exact-unread', found: cutoff, origin: origin),
              _row(
                'future-pub',
                found: cutoff,
                published: _start.add(const Duration(days: 200)),
                origin: origin,
              ),
              _row(
                'recent-read',
                read: _start.subtract(const Duration(days: 90)),
                origin: origin,
              ),
            ],
            sources: [origin],
          ),
        );
      final original = store.value;
      final service = SubscriptionService(
        snapshotStore: store,
        clock: () => _start,
      );
      addTearDown(service.dispose);
      expect((await service.exportLocalData())['feed'], hasLength(6));
      expect(store.value, original);
      expect(store.transactions, 0);

      await service.initialize();
      expect(service.feed.map((row) => row.bvid), [
        'exact-unread',
        'future-pub',
        'exact-read',
        'recent-read',
      ]);
      expect(service.unreadCount, 2);
      final persisted = jsonDecode(store.value!) as Map;
      expect(persisted['feed'], hasLength(4));
      expect(
        persisted['announced'],
        unorderedEquals(['too-old-read', 'too-old-unread']),
      );
      expect(service.sources.single.key, origin.key);
      expect(
        persisted['checkpoints'],
        (jsonDecode(original!) as Map)['checkpoints'],
      );
    },
  );

  test('warm reload replays cleanup over a concurrent engine write', () async {
    var now = _start;
    final expiring = _row(
      'old',
      published: now.subtract(const Duration(days: 14)),
    );
    final survivor = _row('survivor');
    final store = CountingSnapshots()
      ..value = jsonEncode(_data([expiring, survivor]));
    final service = SubscriptionService(snapshotStore: store, clock: () => now);
    addTearDown(service.dispose);
    await service.initialize();
    final view = service.feed;
    store.resetCounts();
    await service.reload();
    expect(identical(service.feed, view), isTrue);
    expect(store.saves, 0);
    expect(store.transactions, 0);

    now = now.add(const Duration(milliseconds: 1));
    store.conflictOnce = (current, proposed) {
      final state = jsonDecode(current) as Map;
      final feed = state['feed'] as List;
      feed[1]['readAt'] = now.toIso8601String();
      feed.add(_row('worker-write', found: now).toJson());
      return jsonEncode(state);
    };
    expect(service.unreadCount, 1); // The storage still has the old badge row.
    expect((jsonDecode(store.value!) as Map)['feed'], hasLength(2));
    await service.reload();
    expect(store.forcedConflicts, 1);
    expect(service.feed.map((row) => row.bvid), ['worker-write', 'survivor']);
    expect(service.feed.last.readAt, now);
    final persisted = jsonDecode(store.value!) as Map;
    expect(persisted['announced'], contains('old'));
    expect(persisted['feed'], hasLength(2));
  });

  testWidgets(
    'open feed drops the row, unread count and its selection immediately after expiry',
    (tester) async {
      final frameStart = tester.binding.clock.now();
      DateTime clock() =>
          _start.add(tester.binding.clock.now().difference(frameStart));
      final expiry = _start.add(const Duration(seconds: 10));
      final store = CountingSnapshots()
        ..value = jsonEncode(
          _data([
            _row(
              'Expire this selected row',
              published: expiry.subtract(const Duration(days: 14)),
            ),
            _row('Keep this row', read: _start),
          ]),
        );
      final service = SubscriptionService(
        snapshotStore: store,
        clock: clock,
        retentionTimerFactory: Timer.new,
      );
      addTearDown(service.dispose);
      await service.initialize();
      service.setForeground(true);
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionUpdatesPage(service: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Expire this selected row'), findsOneWidget);
      expect(service.unreadCount, 1);
      await tester.longPress(find.text('Expire this selected row'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);

      await tester.pump(expiry.difference(clock()));
      expect(find.text('Expire this selected row'), findsOneWidget);
      expect(service.unreadCount, 1);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Expire this selected row'), findsNothing);
      expect(find.text('Keep this row'), findsOneWidget);
      expect(find.text('已选 1 项'), findsNothing);
      expect(service.unreadCount, 0);
      expect((jsonDecode(store.value!) as Map)['feed'], hasLength(1));
      service.setForeground(false);
    },
  );

  testWidgets(
    'each visible deadline still updates with a disk write waiting to retry',
    (tester) async {
      final frameStart = tester.binding.clock.now();
      DateTime clock() =>
          _start.add(tester.binding.clock.now().difference(frameStart));
      final cutoff = _start.subtract(const Duration(days: 14));
      final store = CountingSnapshots()
        ..value = jsonEncode(
          _data([
            _row('first', published: cutoff.add(const Duration(seconds: 1))),
            _row('second', published: cutoff.add(const Duration(seconds: 2))),
          ]),
        );
      final service = SubscriptionService(
        snapshotStore: store,
        clock: clock,
        retentionTimerFactory: Timer.new,
      );
      addTearDown(service.dispose);
      await service.initialize();
      service.setForeground(true);
      await tester.pump();
      final observed = <int>[];
      service.addListener(() => observed.add(service.unreadCount));
      store.failCommit = true;
      await tester.pump(const Duration(milliseconds: 1001));
      expect(observed, contains(1));
      expect(service.storageError, isNotNull);
      expect((jsonDecode(store.value!) as Map)['feed'], hasLength(2));
      await tester.pump(const Duration(seconds: 1));
      expect(observed.last, 0);
      expect(store.transactions, 1); // No tight retries or second disk write.
      store.failCommit = false;
      await tester.pump(const Duration(minutes: 5));
      expect(service.storageError, isNull);
      expect((jsonDecode(store.value!) as Map)['feed'], isEmpty);
      service.setForeground(false);
    },
  );

  test(
    'legacy preferences keeps the raw migration backup but persists cleanup',
    () async {
      final doc = _data([
        _row('old-local', found: _start.subtract(const Duration(days: 15))),
        _row('kept-local'),
      ]);
      doc['version'] = 1;
      final original = jsonEncode(doc);
      SharedPreferences.setMockInitialValues({
        SubscriptionService.storageKey: original,
      });
      final service = SubscriptionService(clock: () => _start);
      addTearDown(service.dispose);
      final prefs = await SharedPreferences.getInstance();
      expect((await service.exportLocalData())['feed'], hasLength(2));
      expect(prefs.getString(SubscriptionService.storageKey), original);
      await service.initialize();
      expect(service.feed.single.bvid, 'kept-local');
      await prefs.reload();
      expect(
        (jsonDecode(prefs.getString(SubscriptionService.storageKey)!)
            as Map)['feed'],
        hasLength(1),
      );
      expect(
        prefs.getString('${SubscriptionService.storageKey}_pre_beta4'),
        original,
      );
    },
  );

  test(
    'disabled local feed still cleans, and a failed cleanup stays hidden and can retry',
    () async {
      var now = _start;
      final store = CountingSnapshots()
        ..value = jsonEncode(
          _data([
            _row('past', published: _start.subtract(const Duration(days: 15))),
            _row('recent'),
          ]),
        )
        ..failCommit = true;
      final sourceContent = Content();
      final service = SubscriptionService(
        snapshotStore: store,
        clock: () => now,
        contentService: sourceContent,
      );
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.storageError, isNotNull);
      expect(service.feed.single.bvid, 'recent');
      expect((jsonDecode(store.value!) as Map)['feed'], hasLength(2));

      store.failCommit = false;
      now = now.add(const Duration(seconds: 1));
      await service.reload();
      expect(service.storageError, isNull);
      expect(service.unreadCount, 1);
      expect((jsonDecode(store.value!) as Map)['feed'], hasLength(1));
      expect(sourceContent.calls, isEmpty);
    },
  );

  test(
    'unordered live collection skips old items but leaves imported archive and dedupe intact',
    () async {
      var now = _start;
      final series = source(1, collection: true);
      final old = now.subtract(const Duration(days: 60));
      final content = Content()
        ..pages[series.mid] = [
          [
            item('old-upstream', publishedAt: old),
            item('valid', publishedAt: now),
          ],
          [
            item(
              'future-metadata',
              publishedAt: now.add(const Duration(days: 60)),
            ),
          ],
        ];
      final store = CountingSnapshots()
        ..value = jsonEncode(
          _data([], sources: [series], enabled: true, notifications: true),
        );
      final service = SubscriptionService(
        snapshotStore: store,
        clock: () => now,
        contentService: content,
      );
      addTearDown(service.dispose);
      final delivered = <String>[];
      service.notifyItems = (items) async {
        delivered.addAll(items.map((e) => e.bvid));
        return true;
      };
      await service.initialize();
      service.setForeground(true);
      await service.refresh(manual: true);
      expect(service.feed.map((row) => row.bvid), ['future-metadata', 'valid']);
      expect(delivered, ['future-metadata', 'valid']);
      expect(service.checkpoint(series.key)!.seen, contains('old-upstream'));
      await service.startHistory(series.key, limit: null);
      expect(
        (await service.historyItems(series.key)).map((e) => e.bvid),
        unorderedEquals(['old-upstream', 'valid', 'future-metadata']),
      );

      now = now.add(const Duration(days: 14, milliseconds: 1));
      // A repeat that has lost all timestamps must not resurrect any old card.
      content.pages[series.mid] = [
        [item('old-upstream'), item('valid'), item('future-metadata')],
      ];
      await service.refresh(manual: true);
      expect(service.feed, isEmpty);
      expect(service.unreadCount, 0);
      expect(delivered, ['future-metadata', 'valid']);
      expect(service.sources.single.key, series.key);
      expect(
        (await service.historyItems(series.key)).map((e) => e.bvid),
        unorderedEquals(['old-upstream', 'valid', 'future-metadata']),
      );
    },
  );

  test(
    'date correction on a later live page suppresses an already evicted notification candidate',
    () async {
      final series = source(1, collection: true);
      final content = Content()
        ..pages[series.mid] = [
          [
            for (var i = 0; i < 500; ++i)
              item('fresh${i.toString().padLeft(3, '0')}'),
            item('zz-evicted'),
          ],
          [
            item(
              'zz-evicted',
              publishedAt: _start.subtract(const Duration(days: 30)),
            ),
          ],
        ];
      final store = CountingSnapshots()
        ..value = jsonEncode(
          _data([], sources: [series], enabled: true, notifications: true),
        );
      final service = SubscriptionService(
        snapshotStore: store,
        clock: () => _start,
        contentService: content,
      );
      addTearDown(service.dispose);
      final delivery = <String>[];
      service.notifyItems = (items) async {
        delivery.addAll(items.map((e) => e.bvid));
        return true;
      };
      await service.initialize();
      service.setForeground(true);
      await service.refresh(manual: true);
      expect(service.feed, hasLength(500));
      expect(service.feed.map((e) => e.bvid), isNot(contains('zz-evicted')));
      expect(delivery, hasLength(500));
      expect(delivery, isNot(contains('zz-evicted')));
    },
  );

  test(
    'notification backend guard will not release a batch after its content expires',
    () async {
      var now = _start;
      final series = source(1, collection: true);
      final content = Content()
        ..pages[series.mid] = [
          [
            item(
              'about-to-expire',
              publishedAt: _start.subtract(const Duration(days: 14)),
            ),
          ],
        ];
      final store = CountingSnapshots()
        ..value = jsonEncode(
          _data([], sources: [series], enabled: true, notifications: true),
        );
      final service = SubscriptionService(
        snapshotStore: store,
        clock: () => now,
        contentService: content,
      );
      addTearDown(service.dispose);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var posted = false;
      service.notifyItems = (items) async {
        expect(items.single.bvid, 'about-to-expire');
        expect(SubscriptionNotificationDelivery.current?.call(), isTrue);
        entered.complete();
        await release.future;
        posted = SubscriptionNotificationDelivery.current?.call() ?? false;
        return posted;
      };
      await service.initialize();
      service.setForeground(true);
      final refresh = service.refresh(manual: true);
      await _waitUntil(() => entered.isCompleted);
      now = _start.add(const Duration(milliseconds: 1));
      release.complete();
      await refresh;
      expect(posted, isFalse);
      expect(service.unreadCount, 0);
    },
  );
}
