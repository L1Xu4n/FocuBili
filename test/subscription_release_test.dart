import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/subscription_notification_service.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/features/profile/collection_detail_page.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_introduction.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/models/dashboard_layout.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/dashboard_layout_service.dart';
import 'package:focubili/services/subscription_onboarding_service.dart';
import 'package:focubili/services/subscription_service.dart';

import 'subscription_background_test.dart' show AtomicSnapshots;
import 'subscription_compact_ui_test.dart'
    show loadBetaReviewFonts, captureSubscriptionUi;
import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;
import 'subscription_service_test.dart' show Content, source, item;

class BatchVideos implements BilibiliService {
  @override
  Future<VideoPreview> lookupVideo(String id) async => VideoPreview(
    bvid: id,
    cid: 10,
    title: id,
    ownerName: '学习UP',
    parts: const [
      VideoPart(
        pageNumber: 1,
        cid: 10,
        title: '第一课',
        duration: Duration(minutes: 5),
      ),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final now = DateTime(2026, 10, 17, 12);
  Map<String, dynamic> fixture(int count) =>
      jsonDecode(feedFixture(count: count, sourceCount: 2))
          as Map<String, dynamic>;

  test(
    'startup and periodic cleanup use readAt exact seven-day boundary, preserving dedupe',
    () async {
      var time = now;
      final data = fixture(5);
      final feed = data['feed'] as List;
      feed[0]['readAt'] = now
          .subtract(const Duration(days: 7))
          .toIso8601String();
      feed[1]['readAt'] = now
          .subtract(const Duration(days: 7, seconds: 1))
          .toIso8601String();
      feed[2]['readAt'] = now
          .subtract(
            const Duration(days: 6, hours: 23, minutes: 59, seconds: 59),
          )
          .toIso8601String();
      feed[3]['readAt'] = null;
      feed[4]['readAt'] = now.add(const Duration(days: 1)).toIso8601String();
      data['announced'] = [for (var i = 0; i < 5; i++) 'fixture$i'];
      final store = AtomicSnapshots()..value = jsonEncode(data);
      final s = SubscriptionService(snapshotStore: store, clock: () => time);
      addTearDown(s.dispose);
      await s.initialize();
      expect(s.feed.map((e) => e.bvid), ['fixture3', 'fixture2', 'fixture4']);
      expect((jsonDecode(store.value!) as Map)['announced'], hasLength(5));
      time = now.add(const Duration(seconds: 1));
      await s.clearExpiredRead();
      expect(s.feed.map((e) => e.bvid), ['fixture3', 'fixture4']);
      final restarted = SubscriptionService(
        snapshotStore: store,
        clock: () => time,
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.feed.map((e) => e.bvid), ['fixture3', 'fixture4']);
    },
  );

  test(
    'cleanup replays against concurrent authoritative state without losing unread or read updates',
    () async {
      final data = fixture(2);
      final store = AtomicSnapshots()..value = jsonEncode(data);
      final s = SubscriptionService(snapshotStore: store, clock: () => now);
      addTearDown(s.dispose);
      await s.initialize();
      store.conflictOnce = (current, proposed) {
        final state = jsonDecode(current) as Map<String, dynamic>;
        state['feed'][1]['readAt'] = now.toIso8601String();
        return jsonEncode(state);
      };
      await s.markRead('fixture0');
      expect(store.forcedConflicts, 1);
      expect(s.feed.every((e) => e.readAt == now), true);
    },
  );

  test(
    'message order follows arrival dates even when a collection adds an old publication',
    () async {
      final data = fixture(2);
      data['feed'][0]['publishedAt'] = DateTime(2010).toIso8601String();
      data['feed'][1]['publishedAt'] = DateTime(2027).toIso8601String();
      final store = AtomicSnapshots()..value = jsonEncode(data);
      final s = SubscriptionService(snapshotStore: store, clock: () => now);
      addTearDown(s.dispose);
      await s.initialize();
      expect(s.feed.map((e) => e.bvid), ['fixture0', 'fixture1']);
    },
  );

  test(
    'bulk mark read commits once and moves all selected below unread ordered by date',
    () async {
      final store = CountingSnapshots()..value = jsonEncode(fixture(4));
      final s = SubscriptionService(snapshotStore: store, clock: () => now);
      addTearDown(s.dispose);
      await s.initialize();
      store.resetCounts();
      await s.markReadBatch({'fixture0', 'fixture2', 'deleted'});
      expect(store.transactions, 1);
      expect(s.feed.map((e) => e.bvid), [
        'fixture1',
        'fixture3',
        'fixture0',
        'fixture2',
      ]);
      expect(s.unreadCount, 2);
    },
  );

  test(
    'huge collection establishes a two-page baseline and never automatically scans history',
    () async {
      final content = Content()
        ..pages[1] = [
          for (var i = 0; i < 500; i++) [item('old$i')],
        ];
      final s = SubscriptionService(contentService: content, clock: () => now);
      addTearDown(s.dispose);
      await s.addSource(source(1, collection: true));
      await s.setEnabled(true);
      s.setForeground(true);
      await s.refresh(manual: true);
      expect(content.calls, ['1:1', '1:2']);
      expect(s.feed, isEmpty);
      expect(s.checkpoint('collection:1:100')!.initialized, true);
      expect(s.checkpoint('collection:1:100')!.partial, false);
      content.calls.clear();
      content.pages[1]![0] = [item('new'), item('old0')];
      await s.refresh(manual: true);
      expect(content.calls, ['1:1', '1:2']);
      expect(s.feed.single.bvid, 'new');
    },
  );

  test(
    'legacy partial collection restarts bounded baseline while feed, seen and history survive',
    () async {
      final data = fixture(1);
      final collection = source(1, collection: true);
      data['sources'] = [collection.toJson()];
      data['checkpoints'] = {
        collection.key: SourceCheckpoint(
          algorithm: 2,
          nextPage: 400,
          seen: {'old0', 'deep-known'},
          initialized: false,
          pending: {
            'fixture0': SubscriptionFeedItem.fromJson(
              Map<String, dynamic>.from(data['feed'][0]),
            ),
          },
        ).toJson(),
      };
      final content = Content()
        ..pages[1] = [
          for (var i = 0; i < 500; i++) [item('old$i')],
        ];
      final store = AtomicSnapshots()..value = jsonEncode(data);
      final s = SubscriptionService(
        snapshotStore: store,
        contentService: content,
        clock: () => now,
      );
      addTearDown(s.dispose);
      await s.initialize();
      s.setForeground(true);
      await s.refresh(manual: true);
      expect(content.calls, ['1:1', '1:2']);
      expect(s.feed.single.bvid, 'fixture0');
      expect(s.checkpoint(collection.key)!.seen, contains('deep-known'));
      expect(s.checkpoint(collection.key)!.pending, contains('fixture0'));
      expect(s.checkpoint(collection.key)!.algorithm, 3);
    },
  );

  test(
    'collection live adapter covers both ends while ordinary/history keeps original order',
    () async {
      final calls = <Uri>[];
      final content = BilibiliHttpPublicContentService(
        requestJson: (uri) async {
          calls.add(uri);
          return jsonEncode({
            'code': 0,
            'data': {
              'archives': [],
              'meta': {'total': 100},
            },
          });
        },
      );
      await content.loadRecentCollectionVideos(1, 100);
      await content.loadCollectionVideos(1, 100);
      expect(calls.map((uri) => uri.queryParameters['sort_reverse']), [
        'false',
        'true',
        'false',
      ]);
    },
  );

  test(
    'bulk deleting a source cancels its late response without removing existing messages',
    () async {
      final content = Content();
      final store = AtomicSnapshots()..value = jsonEncode(fixture(1));
      final s = SubscriptionService(
        snapshotStore: store,
        contentService: content,
        clock: () => now,
      );
      addTearDown(s.dispose);
      await s.initialize();
      content.hold = Completer<void>();
      content.pages[1] = [
        [item('late')],
      ];
      s.setForeground(true);
      final refreshing = s.refresh(manual: true);
      for (var i = 0; i < 100 && content.calls.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await s.deleteSources({'creator:1', 'creator:2'});
      content.hold!.complete();
      await refreshing;
      expect(s.sources, isEmpty);
      expect(s.feed.single.bvid, 'fixture0');
    },
  );

  test('bulk pause/resume is one persisted generation change', () async {
    final store = CountingSnapshots()..value = jsonEncode(fixture(1));
    final s = SubscriptionService(snapshotStore: store);
    addTearDown(s.dispose);
    await s.initialize();
    final generation = s.notificationGeneration;
    store.resetCounts();
    await s.pauseSources({'creator:1', 'creator:2'}, true);
    expect(s.sources.every((e) => e.paused), true);
    expect(store.transactions, 1);
    expect(s.notificationGeneration, generation + 1);
    await s.pauseSources({'creator:1', 'creator:2'}, false);
    expect(s.sources.any((e) => e.paused), false);
  });

  for (final platform in [
    AppPlatform.android,
    AppPlatform.ios,
    AppPlatform.macos,
  ]) {
    test(
      'native subscription notification on $platform receives video title and source subtitle',
      () async {
        const channel = MethodChannel('test/subscription-notification');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return true;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final notifications = SubscriptionNotificationService(
          channel: channel,
          platform: platform,
        );
        final entry = SubscriptionFeedItem(
          bvid: 'BVtest',
          title: '视频标题',
          coverUrl: '',
          sources: const {'collection:1:2': '课程合集'},
          discoveredAt: now,
        );
        expect(
          await notifications.showItems(
            [entry],
            generation: 9,
            background: platform == AppPlatform.android,
          ),
          true,
        );
        final args = calls.single.arguments as Map;
        expect(args['title'], '视频标题');
        expect(args['source'], '来自课程合集');
        expect(args['generation'], 9);
        expect(args['count'], 1);
      },
    );
  }

  test('notification payload retains merged sources', () async {
    final content = Content()
      ..pages[1] = [
        [item('old')],
      ]
      ..pages[2] = [
        [item('old')],
      ];
    final s = SubscriptionService(contentService: content);
    addTearDown(s.dispose);
    await s.addSource(source(1));
    await s.addSource(source(2));
    await s.setEnabled(true);
    await s.setNotificationsEnabled(true);
    s.setForeground(true);
    await s.refresh(manual: true);
    List<SubscriptionFeedItem>? payload;
    s.notifyItems = (items) async {
      payload = items;
      return true;
    };
    content.pages[1] = [
      [item('new'), item('old')],
    ];
    content.pages[2] = [
      [item('new'), item('old')],
    ];
    await s.refresh(manual: true);
    expect(payload, hasLength(1));
    expect(payload!.single.sources, hasLength(2));
    expect(payload!.single.title, 'new');
  });

  test(
    'decline is permanent, keeps sources and layout intact, never enables polling',
    () async {
      final s = SubscriptionService(contentService: Content());
      addTearDown(s.dispose);
      final layouts = DashboardLayoutService();
      await layouts.save(
        'home',
        DashboardLayout(order: ['custom'], hidden: ['hidden']),
      );
      final intro = SubscriptionOnboardingService(
        subscriptions: s,
        layoutService: layouts,
      );
      expect(await intro.shouldPrompt(), true);
      await intro.decline();
      expect(s.enabled, false);
      expect(
        await SubscriptionOnboardingService(subscriptions: s).shouldPrompt(),
        false,
      );
      final layout = await layouts.load('home', const []);
      expect(layout.order, ['custom']);
      expect(layout.hidden, {'hidden'});
    },
  );

  test(
    'accept/restart is idempotent: enable and promote one card, preserve all other layout',
    () async {
      final s = SubscriptionService(contentService: Content());
      addTearDown(s.dispose);
      final layouts = DashboardLayoutService();
      await layouts.save(
        'home',
        DashboardLayout(
          order: ['custom', SubscriptionOnboardingService.homeCardId, 'later'],
          hidden: [SubscriptionOnboardingService.homeCardId, 'later'],
        ),
      );
      final intro = SubscriptionOnboardingService(
        subscriptions: s,
        layoutService: layouts,
      );
      await Future.wait([intro.accept(), intro.accept(), intro.accept()]);
      expect(s.enabled, true);
      expect(await intro.shouldPrompt(), false);
      var layout = await layouts.load('home', const []);
      expect(layout.order, [
        SubscriptionOnboardingService.homeCardId,
        'custom',
        'later',
      ]);
      expect(layout.hidden, {'later'});
      await layouts.save(
        'home',
        layout.move(
          SubscriptionOnboardingService.homeCardId,
          'later',
          after: true,
        ),
      );
      await SubscriptionOnboardingService(
        subscriptions: s,
        layoutService: layouts,
      ).accept();
      layout = await layouts.load('home', const []);
      expect(layout.order.last, SubscriptionOnboardingService.homeCardId);
    },
  );

  test(
    'interrupted opt-in recovers, existing beta opt-in keeps customized layout',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SubscriptionOnboardingService.choiceKey,
        'enabling',
      );
      final s = SubscriptionService(contentService: Content());
      addTearDown(s.dispose);
      final layouts = DashboardLayoutService();
      final intro = SubscriptionOnboardingService(
        subscriptions: s,
        layoutService: layouts,
      );
      expect(await intro.shouldPrompt(), false);
      expect(s.enabled, true);
      expect(
        (await layouts.load('home', const [])).order.first,
        SubscriptionOnboardingService.homeCardId,
      );
      await prefs.remove(SubscriptionOnboardingService.choiceKey);
      await layouts.save(
        'home',
        DashboardLayout(
          order: ['keep'],
          hidden: [SubscriptionOnboardingService.homeCardId],
        ),
      );
      expect(
        await SubscriptionOnboardingService(
          subscriptions: s,
          layoutService: layouts,
        ).shouldPrompt(),
        false,
      );
      expect((await layouts.load('home', const [])).order, ['keep']);
    },
  );

  testWidgets(
    'message long-press selects, select-all and batch read move beneath read divider',
    (tester) async {
      final store = AtomicSnapshots()..value = jsonEncode(fixture(3));
      final s = SubscriptionService(snapshotStore: store, clock: () => now);
      addTearDown(s.dispose);
      await s.initialize();
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionUpdatesPage(service: s)),
      );
      await tester.pumpAndSettle();
      expect(find.text('播放'), findsNothing);
      expect(find.textContaining('收到 '), findsNothing);
      await tester.longPress(
        find.byKey(const ValueKey('subscription-feed-fixture0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.byTooltip('焦点订阅设置'), findsNothing);
      await tester.tap(find.byTooltip('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 项'), findsOneWidget);
      await tester.tap(find.byTooltip('标为已读'));
      await tester.pumpAndSettle();
      expect(s.unreadCount, 0);
      expect(find.text('已读'), findsOneWidget);
      expect(find.text('焦点订阅'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source filters narrow feed and floating filters collapse/reveal during scroll',
    (tester) async {
      final data = fixture(40);
      for (var i = 0; i < 40; i++) {
        data['feed'][i]['sources'] = {
          i.isEven ? 'creator:1' : 'creator:2': '频道',
        };
      }
      final store = AtomicSnapshots()..value = jsonEncode(data);
      final s = SubscriptionService(snapshotStore: store, clock: () => now);
      addTearDown(s.dispose);
      await s.initialize();
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionUpdatesPage(service: s)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-filter-creator:2')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subscription-feed-fixture0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('subscription-feed-fixture1')),
        findsOneWidget,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('subscription-source-filters')).hitTestable(),
        findsNothing,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('source-filter-creator:2')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch learning saves selected tasks without changing reads and avoids duplicates',
    (tester) async {
      final store = AtomicSnapshots()..value = jsonEncode(fixture(2));
      final s = SubscriptionService(snapshotStore: store);
      addTearDown(s.dispose);
      final learning = LearningListService();
      final videos = BatchVideos();
      await learning.addVideo(await videos.lookupVideo('fixture0'));
      await s.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionUpdatesPage(
            service: s,
            videoService: videos,
            learningService: learning,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(
        find.byKey(const ValueKey('subscription-feed-fixture0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('加入学习清单'));
      await tester.pumpAndSettle();
      expect(await learning.loadEntries(), hasLength(2));
      expect(s.unreadCount, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source taps open creator and collection pages with subscription cancellation still available',
    (tester) async {
      final s = SubscriptionService(contentService: Content());
      addTearDown(s.dispose);
      await s.addSource(source(1));
      await s.addSource(source(2, collection: true));
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionSettingsPage(service: s)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('源1'), 200);
      await tester.tap(find.text('源1'));
      await tester.pumpAndSettle();
      expect(find.byType(UserProfilePage), findsOneWidget);
      expect(find.byTooltip('取消焦点订阅'), findsOneWidget);
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('源2'), 200);
      await tester.tap(find.text('源2'));
      await tester.pumpAndSettle();
      expect(find.byType(CollectionDetailPage), findsOneWidget);
      expect(find.byTooltip('取消焦点订阅'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source long-press/all pauses and deletes a selected batch', (
    tester,
  ) async {
    final store = AtomicSnapshots()..value = jsonEncode(fixture(1));
    final s = SubscriptionService(snapshotStore: store);
    addTearDown(s.dispose);
    await s.initialize();
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionSettingsPage(service: s)),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('subscription-source-creator:1'));
    await tester.scrollUntilVisible(first, 250);
    await tester.longPress(first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 个来源'), findsOneWidget);
    await tester.tap(find.byTooltip('批量暂停或恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停所选'));
    await tester.pumpAndSettle();
    expect(s.sources.every((e) => e.paused), true);
    await tester.longPress(first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除所选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(s.sources, isEmpty);
    expect(s.feed, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home introduction enables one first card and shortcut and stays dismissed after restart',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await loadBetaReviewFonts(tester);
      final controller = FocusTimerController(
        tickInterval: const Duration(days: 1),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final s = SubscriptionService(contentService: Content());
      addTearDown(s.dispose);
      final layouts = DashboardLayoutService();
      final boundary = GlobalKey();
      Widget host() => RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily:
                const String.fromEnvironment('BETA3_CAPTURE_DIR').isEmpty
                ? null
                : 'BetaReview',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: FocusDashboard(
              controller: controller,
              subscriptionService: s,
              layoutService: layouts,
              onOpenVideo: () {},
              onOpenStatistics: () {},
              onOpenProfile: () {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-subscription-card')), findsNothing);
      await captureSubscriptionUi(tester, boundary, 'introduction-home');
      await tester.tap(find.text('新增焦点订阅'));
      await tester.pumpAndSettle();
      await captureSubscriptionUi(tester, boundary, 'introduction-dialog');
      await tester.tap(find.text('好，开启焦点订阅'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('好的'));
      await tester.pumpAndSettle();
      expect(find.text('焦点订阅设置'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-subscription-button')), findsOneWidget);
      expect(
        (await layouts.load('home', const [])).order.first,
        SubscriptionOnboardingService.homeCardId,
      );
      await tester.ensureVisible(
        find.byKey(const Key('home-subscription-card')),
      );
      await tester.pumpAndSettle();
      await captureSubscriptionUi(tester, boundary, 'introduction-first-card');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.text('新增焦点订阅'), findsNothing);
      expect(find.byKey(const Key('home-subscription-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final accept in [true, false]) {
    testWidgets(
      'first-run prompt choice $accept persists exact behavior on reopen',
      (tester) async {
        final s = SubscriptionService(contentService: Content());
        addTearDown(s.dispose);
        var enabledCallbacks = 0;
        final layouts = DashboardLayoutService();
        Widget app(Key key) => MaterialApp(
          home: Scaffold(
            body: SubscriptionIntroduction(
              key: key,
              service: s,
              layoutService: layouts,
              onEnabled: () => enabledCallbacks++,
            ),
          ),
        );
        await tester.pumpWidget(app(const ValueKey('first')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('新增焦点订阅'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('当你需要焦点订阅时，在“我的页面”仍然能够再次开启'),
          findsOneWidget,
        );
        await tester.tap(find.text(accept ? '好，开启焦点订阅' : '我不需要焦点订阅'));
        await tester.pumpAndSettle();
        expect(s.enabled, accept);
        if (accept) {
          expect(find.text('首页已经添加“焦点订阅”卡片和快捷按钮'), findsOneWidget);
          await tester.tap(find.text('好的'));
          await tester.pumpAndSettle();
          expect(find.text('焦点订阅设置'), findsOneWidget);
          expect(enabledCallbacks, 1);
        } else {
          expect(find.text('焦点订阅设置'), findsNothing);
          expect(enabledCallbacks, 0);
          expect((await layouts.load('home', const [])).order, isEmpty);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(app(const ValueKey('restart')));
        await tester.pumpAndSettle();
        expect(find.text('新增焦点订阅'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
