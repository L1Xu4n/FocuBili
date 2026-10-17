import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/subscription_history.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/subscription_history_store.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'subscription_background_test.dart' show AtomicSnapshots;
import 'subscription_performance_probe_test.dart' show feedFixture;
import 'support/subscription_public_pages.dart';

class InterruptingHistory extends MemorySubscriptionHistoryStore {
  InterruptingHistory(this.snapshots);
  final AtomicSnapshots snapshots;
  bool interruptOnce = true;
  @override
  Future<void> write(
    String job,
    int batch,
    SubscriptionHistoryBatch value,
  ) async {
    await super.write(job, batch, value);
    if (interruptOnce) {
      interruptOnce = false;
      snapshots.failCommit = true;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'legacy partial baseline migration is repeatable and retains pending, reads and claims',
    () async {
      final data =
          jsonDecode(feedFixture(count: 2, sourceCount: 1))
              as Map<String, dynamic>;
      final cp = (data['checkpoints'] as Map)['creator:1'] as Map;
      cp.removeWhere(
        (key, _) => [
          'algorithm',
          'baselineAt',
          'fullBaseline',
          'watermark',
          'scanNewest',
          'knownPages',
          'blocked',
          'anchors',
          'signatures',
          'secondPage',
        ].contains(key),
      );
      cp['initialized'] = false;
      cp['nextPage'] = 51;
      cp['pending'] = [(data['feed'] as List).first];
      (data['feed'] as List).last['readAt'] = '2026-01-01T12:00:00.000Z';
      data['announced'] = ['fixture1'];
      data['notificationClaims'] = ['fixture1'];
      final raw = jsonEncode(data);
      final store = AtomicSnapshots()..value = raw;
      final api = PublicPages(10000);
      Future<SubscriptionService> create() async {
        final service = SubscriptionService(
          snapshotStore: store,
          contentService: BilibiliHttpPublicContentService(
            requestJson: api.call,
          ),
          clock: () => DateTime.utc(2026, 1, 2),
        );
        addTearDown(service.dispose);
        await service.initialize();
        return service;
      }

      final service = await create();
      service.setForeground(true);
      await service.refresh();
      expect(api.pages, [1, 2]);
      expect(service.checkpoint('creator:1')!.initialized, true);
      expect(service.checkpoint('creator:1')!.pending.keys, ['fixture0']);
      expect(
        service.feed.firstWhere((e) => e.bvid == 'fixture1').readAt,
        isNotNull,
      );
      expect((jsonDecode(store.value!) as Map)['notificationClaims'], [
        'fixture1',
      ]);
      expect(
        (await SharedPreferences.getInstance()).getString(
          '${SubscriptionService.storageKey}_pre_beta4',
        ),
        raw,
      );
      final next = await create();
      expect(next.checkpoint('creator:1')!.algorithm, 2);
      expect(
        next.feed.map((e) => e.bvid),
        containsAll(['fixture0', 'fixture1']),
      );
      expect((await next.historyItems('creator:1')).single.bvid, 'fixture0');
    },
  );
  test(
    'future schemas remain untouched; corrupt history job recovers backup',
    () async {
      final raw = feedFixture(count: 2, sourceCount: 1);
      final unknown = jsonDecode(raw) as Map<String, dynamic>;
      unknown['version'] = 999;
      final store = AtomicSnapshots()
        ..value = jsonEncode(unknown)
        ..backup = raw;
      final original = store.value;
      final service = SubscriptionService(snapshotStore: store);
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.storageError, isNotNull);
      expect(store.value, original);
      final corrupt = jsonDecode(raw) as Map<String, dynamic>;
      corrupt['version'] = 2;
      corrupt['historyJobs'] = {
        'creator:1': {'status': 'broken'},
      };
      store.value = jsonEncode(corrupt);
      final recovered = SubscriptionService(snapshotStore: store);
      addTearDown(recovered.dispose);
      await recovered.initialize();
      expect(recovered.feed.length, 2);
      expect(store.quarantine, isNotNull);
    },
  );
  test(
    'interruption between immutable history page and cursor commit reuses durable page',
    () async {
      var now = DateTime.utc(2026, 1, 2);
      final store = AtomicSnapshots();
      final history = InterruptingHistory(store);
      final api = PublicPages(60);
      final source = SubscriptionSource(
        kind: SubscriptionKind.creator,
        mid: 1,
        name: '源',
        token: '1',
      );
      Future<SubscriptionService> create() async {
        final result = SubscriptionService(
          snapshotStore: store,
          historyStore: history,
          contentService: BilibiliHttpPublicContentService(
            requestJson: api.call,
          ),
          clock: () => now,
        );
        addTearDown(result.dispose);
        await result.initialize();
        return result;
      }

      final a = await create();
      await a.addSource(source);
      await a.setEnabled(true);
      a.setForeground(true);
      await a.refresh();
      api.calls.clear();
      await expectLater(
        a.startHistory(source.key, limit: null),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(a.historyJob(source.key)!.ids, isEmpty);
      store.failCommit = false;
      now = now.add(const Duration(minutes: 3));
      a.setForeground(false);
      final b = await create();
      b.setForeground(true);
      await b.refresh();
      await b.resumeHistory(source.key);
      expect(b.historyJob(source.key)!.ids.length, 60);
      expect(api.pages.where((page) => page == 1), hasLength(1));
      expect(b.feed, isEmpty);
    },
  );
  test(
    'file history pages survive reopening; immutable writes and corrupt bytes remain preserved',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focubili-history-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileSubscriptionHistoryStore(
        directory: () async => directory,
      );
      const first = SubscriptionHistoryBatch(
        page: 51,
        items: [],
        hasMore: true,
        signature: 'page51',
      );
      await store.write('job', 0, first);
      await store.write(
        'job',
        0,
        const SubscriptionHistoryBatch(
          page: 52,
          items: [],
          hasMore: false,
          signature: 'other',
        ),
      );
      final reopened = FileSubscriptionHistoryStore(
        directory: () async => directory,
      );
      expect((await reopened.read('job', 0))!.page, 51);
      await Future.wait(
        List.generate(
          30,
          (i) => reopened.write(
            'race',
            0,
            SubscriptionHistoryBatch(
              page: i + 1,
              items: [],
              hasMore: true,
              signature: 'writer$i',
            ),
          ),
        ),
      );
      final winner = (await reopened.read('race', 0))!;
      await store.write('race', 0, first);
      expect((await store.read('race', 0))!.signature, winner.signature);
      final file = File(
        '${directory.path}/subscription-history/job/0/page.json',
      );
      await file.writeAsString('broken');
      await expectLater(reopened.read('job', 0), throwsFormatException);
      expect(await file.readAsString(), 'broken');
      await expectLater(reopened.read('../escape', 0), throwsFormatException);
    },
  );
  test(
    'collection automatic check is bounded while explicit history retains deep additions',
    () async {
      final store = AtomicSnapshots();
      final api = PublicPages(100);
      var now = DateTime.utc(2026, 1, 2);
      final source = SubscriptionSource(
        kind: SubscriptionKind.collection,
        mid: 1,
        seasonId: 7,
        name: '合集',
        token: '7',
      );
      final s = SubscriptionService(
        snapshotStore: store,
        pageBudget: 3,
        clock: () => now,
        contentService: BilibiliHttpPublicContentService(requestJson: api.call),
      );
      addTearDown(s.dispose);
      await s.initialize();
      await s.addSource(source);
      await s.setEnabled(true);
      s.setForeground(true);
      await s.refresh();
      expect(s.checkpoint(source.key)!.initialized, true);
      expect(s.checkpoint(source.key)!.partial, false);
      expect(api.pages, [1, 1, 2, 2]);
      expect(s.checkpoint(source.key)!.seen, hasLength(80));
      expect(s.feed, isEmpty);
      now = now.add(const Duration(hours: 2));
      api.videos[55] = PublicPages.video(99999, published: DateTime.utc(2010));
      api.calls.clear();
      await s.refresh();
      expect(api.pages, [1, 1, 2, 2]);
      expect(
        s.feed,
        isEmpty,
      ); // Bounded coverage does not claim arbitrary middle changes.
      expect(s.checkpoint(source.key)!.lastSuccess, now);
      await s.startHistory(source.key, limit: null);
      expect(
        (await s.historyItems(source.key)).map((e) => e.bvid),
        contains('BV0000099999'),
      );
      expect(s.feed, isEmpty); // Historical import is not a new notification.
      api.videos.add(PublicPages.video(100000, published: now));
      api.calls.clear();
      await s.refresh(manual: true);
      expect(api.pages, [1, 1, 2, 2]);
      expect(s.feed.single.bvid, 'BV0000100000');
    },
  );
}
