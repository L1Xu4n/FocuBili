import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/subscription_history.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/subscription_history_store.dart';
import 'subscription_background_test.dart' show AtomicSnapshots;
import 'support/subscription_public_pages.dart';

export 'support/subscription_public_pages.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late AtomicSnapshots store;
  late MemorySubscriptionHistoryStore history;
  late PublicPages api;
  late SubscriptionService service;
  var notices = 0;
  final source = SubscriptionSource(
    kind: SubscriptionKind.creator,
    mid: 1,
    name: '万条课程',
    token: 'source-1',
  );
  Future<SubscriptionService> create({
    PublicPages? pages,
    int budget = 20,
  }) async {
    final result = SubscriptionService(
      snapshotStore: store,
      historyStore: history,
      contentService: BilibiliHttpPublicContentService(
        requestJson: (pages ?? api).call,
      ),
      clock: () => now,
      pageBudget: budget,
      backgroundScheduler: (_, _) async {},
    );
    result.notifySummary = (count) async {
      notices += count;
      return true;
    };
    addTearDown(result.dispose);
    await result.initialize();
    return result;
  }

  Future<void> baseline({int count = 10000, int budget = 20}) async {
    api = PublicPages(count);
    service = await create(budget: budget);
    await service.addSource(source);
    await service.setEnabled(true);
    service.setForeground(true);
    await service.refresh();
    await service.setNotificationsEnabled(true);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime.utc(2026, 1, 2);
    store = AtomicSnapshots();
    history = MemorySubscriptionHistoryStore();
    notices = 0;
  });
  for (final count in [100, 1000, 10000]) {
    test(
      '$count videos: two-page live baseline, one shared nav, no historical feed',
      () async {
        await baseline(count: count);
        expect(api.pages, [1, 2]);
        expect(api.navCalls, 1);
        expect(service.checkpoint(source.key)!.initialized, true);
        expect(service.checkpoint(source.key)!.seen.length, 40);
        expect(service.feed, isEmpty);
        expect(notices, 0);
        for (var i = 0; i < 100; i++) {
          await service.refresh();
        }
        expect(api.calls.length, 3);
        await service.refresh(manual: true);
        expect(api.pages, [1, 2, 1, 2]);
        expect(api.navCalls, 1);
      },
    );
  }
  test(
    '10000-item explicit import reaches page 51 and 500, independent of feed and notifications',
    () async {
      await baseline();
      api.calls.clear();
      await service.startHistory(source.key, limit: null);
      final job = service.historyJob(source.key)!;
      expect(job.status, HistoryImportStatus.complete);
      expect(job.ids.length, 10000);
      expect(job.batches, 500);
      expect(api.pages, List.generate(500, (i) => i + 1));
      expect(api.navCalls, 0);
      expect(service.feed, isEmpty);
      expect(notices, 0);
      expect(
        (await service.historyItems(
          source.key,
          offset: 9990,
          count: 10,
        )).length,
        10,
      );
      expect(service.checkpoint(source.key)!.seen.length, 40);
    },
  );
  test(
    '1000 new videos and an old head do not stop at one known BV; partial rounds persist',
    () async {
      await baseline();
      api.calls.clear();
      now = now.add(const Duration(minutes: 1));
      final pinned = api.videos.removeAt(0);
      api.videos = [
        pinned,
        ...List.generate(
          1000,
          (i) => PublicPages.video(20000 + i, published: now),
        ),
        ...api.videos,
      ];
      await service.refresh(manual: true);
      expect(service.checkpoint(source.key)!.partial, true);
      expect(service.feed, isNotEmpty);
      for (var i = 0; i < 5 && service.checkpoint(source.key)!.partial; i++) {
        await service.refresh(manual: true);
      }
      expect(service.checkpoint(source.key)!.partial, false);
      expect(notices, 1000);
      expect(service.feed.length, 500);
      expect((jsonDecode(store.value!) as Map)['announced'], hasLength(1000));
      expect(api.pages, contains(51));
      await service.refresh(manual: true);
      expect(notices, 1000);
    },
  );
  test(
    'repeated page and wrong page halt without pretending full coverage',
    () async {
      await baseline(count: 1000);
      api.repeatPage = 3;
      await service.startHistory(source.key, limit: null);
      expect(
        service.historyJob(source.key)!.status,
        HistoryImportStatus.blocked,
      );
      expect(service.historyJob(source.key)!.ids.length, 40);
      expect(api.pages.last, 3);
      api.repeatPage = null;
      api.wrongPage = 3;
      await service.resumeHistory(source.key);
      expect(
        service.historyJob(source.key)!.status,
        HistoryImportStatus.blocked,
      );
      api.wrongPage = null;
      await service.resumeHistory(source.key);
      expect(service.historyJob(source.key)!.ids.length, 1000);
    },
  );
  test(
    'a changing head during catch-up gets a new coverage pass without losing a burst',
    () async {
      await baseline(count: 1000, budget: 3);
      now = now.add(const Duration(minutes: 1));
      api.videos.insertAll(
        0,
        List.generate(100, (i) => PublicPages.video(20000 + i, published: now)),
      );
      await service.refresh(manual: true);
      expect(service.checkpoint(source.key)!.partial, true);
      // More than one page inserted between rounds; an overlap alone cannot
      // recover everything that shifted behind the new head probe.
      api.videos.insertAll(
        0,
        List.generate(80, (i) => PublicPages.video(30000 + i, published: now)),
      );
      for (var i = 0; i < 30 && service.checkpoint(source.key)!.partial; i++) {
        await service.refresh(manual: true);
      }
      expect(service.checkpoint(source.key)!.partial, false);
      expect(service.feed, hasLength(180));
      expect(notices, 180);
      await service.refresh(manual: true);
      expect(notices, 180);
    },
  );
  test(
    'failed page resumes after backoff and a fresh engine keeps imported data',
    () async {
      await baseline(count: 120);
      api.failPage = 3;
      await service.startHistory(source.key, limit: null);
      expect(service.historyJob(source.key)!.ids.length, 40);
      final requests = api.calls.length;
      await service.resumeHistory(source.key);
      expect(api.calls.length, requests);
      api.failPage = null;
      now = now.add(const Duration(minutes: 3));
      service.setForeground(false);
      final next = await create();
      next.setForeground(true);
      await next.refresh();
      await next.resumeHistory(source.key);
      expect(next.historyJob(source.key)!.ids.length, 120);
      expect((await next.historyItems(source.key)).length, 100);
      expect(next.feed, isEmpty);
    },
  );
  test(
    'pause rejects late response; completed pages survive and resume',
    () async {
      await baseline(count: 120);
      api.holdPage = 3;
      api.held = Completer<void>();
      api.entered = Completer<void>();
      final run = service.startHistory(source.key, limit: null);
      await api.entered!.future;
      await service.pauseHistory(source.key);
      api.held!.complete();
      await run;
      expect(service.historyJob(source.key)!.ids.length, 40);
      expect(
        service.historyJob(source.key)!.status,
        HistoryImportStatus.paused,
      );
      api.holdPage = null;
      await service.resumeHistory(source.key);
      expect(service.historyJob(source.key)!.ids.length, 120);
    },
  );
  test(
    'history metadata must not suppress live events; manual refresh takes page-boundary priority',
    () async {
      await baseline(count: 120);
      now = now.add(const Duration(minutes: 1));
      api.videos.insert(0, PublicPages.video(99999, published: now));
      api.holdPage = 2;
      api.held = Completer<void>();
      api.entered = Completer<void>();
      final run = service.startHistory(source.key);
      await api.entered!.future;
      final refresh = service.refresh(manual: true);
      api.holdPage = null;
      api.held!.complete();
      await refresh;
      await run;
      expect(service.feed.single.bvid, 'BV0000099999');
      expect(notices, 1);
      expect(service.historyJob(source.key)!.ids.length, 100);
      await service.startHistory(source.key, limit: null);
      expect(service.historyJob(source.key)!.ids.length, 121);
    },
  );
  test(
    'concurrent foreground/background engines share a durable network lease',
    () async {
      await baseline(count: 120);
      await service.setBackgroundRefreshEnabled(true);
      now = now.add(const Duration(hours: 2));
      api.calls.clear();
      api.holdPage = 1;
      api.held = Completer<void>();
      api.entered = Completer<void>();
      final worker = await create();
      final foreground = service.refresh(manual: true);
      await api.entered!.future;
      await worker.runBackgroundCheck(store.generation);
      expect(api.pages, [1]);
      api.holdPage = null;
      api.held!.complete();
      await foreground;
      expect(api.pages, [1, 2]);
    },
  );
}
