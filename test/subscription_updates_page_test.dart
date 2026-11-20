import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/platform/app_platform.dart';
import 'subscription_background_test.dart' show AtomicSnapshots;
import 'subscription_service_test.dart' show Content, item, source;

class _CountingSnapshots extends AtomicSnapshots {
  int writes = 0;

  @override
  Future<T> transact<T>(
    FutureOr<T> Function(String?, void Function(String)) action,
  ) => super.transact(
    (current, save) => action(current, (value) {
      writes++;
      save(value);
    }),
  );
}

class _PlaybackSpy extends Fake implements BilibiliService {
  final lookups = <String>[];

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookups.add(input);
    throw StateError('Selection must not start playback.');
  }
}

class Permission extends FocusNotificationService {
  int requests = 0;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return false;
  }
}

class HeldContent implements BilibiliPublicContentService {
  final profile = Completer<CreatorProfile>();
  final collections = Completer<CreatorContentPage<CreatorCollection>>();
  int collectionCalls = 0;
  @override
  Future<CreatorProfile> loadProfile(int mid) => profile.future;
  @override
  Future<CreatorContentPage<CreatorCollection>> loadCollections(
    int mid, {
    int page = 1,
  }) {
    collectionCalls++;
    return collections.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('feed checkbox swipe selects only filtered rows without writes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final content = Content()
      ..pages[1] = [
        [item('baseline')],
      ];
    final service = SubscriptionService(contentService: content);
    addTearDown(service.dispose);
    await service.addSource(source(1));
    await service.setEnabled(true);
    service.setForeground(true);
    await service.refresh(manual: true);
    content.pages[1] = [
      [
        item('alpha'),
        item('bravo'),
        item('charlie'),
        item('delta'),
        item('baseline'),
      ],
    ];
    await service.refresh(manual: true);
    await service.markRead('bravo');
    service.setForeground(false);
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionUpdatesPage(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅未读'));
    await tester.pumpAndSettle();
    expect(find.text('bravo'), findsNothing);

    Finder box(String id, {bool selected = false}) => find.descendant(
      of: find.byKey(ValueKey('subscription-feed-$id')),
      matching: find.byIcon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
      ),
    );

    await tester.longPress(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(box('alpha', selected: true));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.done_all))
          .onPressed,
      isNull,
    );
    final alphaGlyph = tester.getRect(box('alpha'));
    final alphaAnchor = alphaGlyph.center + const Offset(12, 0);
    expect(alphaGlyph.contains(alphaAnchor), isFalse);
    final drag = await tester.startGesture(alphaAnchor);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    await drag.moveTo(tester.getCenter(box('delta')));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    expect(
      tester.getSemantics(box('charlie', selected: true)),
      isSemantics(hasCheckedState: true, isChecked: true, hasTapAction: true),
    );
    expect(
      service.feed.where((entry) => entry.readAt != null).map((e) => e.bvid),
      ['bravo'],
    );
    await tester.tap(find.byTooltip('标为已读'));
    await tester.pumpAndSettle();
    expect(find.text('焦点订阅'), findsOneWidget);
    expect(service.feed.every((item) => item.readAt != null), isTrue);
  });

  testWidgets('feed uncheck sweep stays at zero through day and read headers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var now = DateTime(2026, 4, 10, 12);
    final content = Content();
    var videos = [item('baseline')];
    content.pages[1] = [videos];
    final store = _CountingSnapshots();
    final service = SubscriptionService(
      contentService: content,
      clock: () => now,
      snapshotStore: store,
    );
    addTearDown(service.dispose);
    await service.addSource(source(1));
    await service.setEnabled(true);
    service.setForeground(true);
    await service.refresh(manual: true);
    for (final id in ['older-read', 'middle-unread', 'latest-unread']) {
      now = now.add(const Duration(days: 1));
      videos = [item(id, publishedAt: now), ...videos];
      content.pages[1] = [videos];
      await service.refresh(manual: true);
    }
    await service.markRead('older-read');
    service.setForeground(false);
    expect(service.feed.map((entry) => entry.bvid), [
      'latest-unread',
      'middle-unread',
      'older-read',
    ]);
    final snapshotsBefore = store.value;
    final writesBefore = store.writes;
    final videoService = _PlaybackSpy();
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionUpdatesPage(
          service: service,
          videoService: videoService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder box(String id, {bool checked = false}) => find.descendant(
      of: find.byKey(ValueKey('subscription-feed-$id')),
      matching: find.byIcon(
        checked ? Icons.check_circle : Icons.radio_button_unchecked,
      ),
    );
    await tester.longPress(find.text('latest-unread'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    final start = tester.getCenter(box('latest-unread', checked: true));
    final negative = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('已选 0 项'), findsOneWidget);

    final middleDay = find.textContaining('4月12日');
    final readSection = find.text('已读');
    final readDay = find.textContaining('4月11日');
    for (final destination in [
      middleDay,
      box('middle-unread'),
      readSection,
      readDay,
      box('older-read'),
    ]) {
      await negative.moveTo(Offset(start.dx, tester.getCenter(destination).dy));
      await tester.pump();
      expect(find.text('已选 0 项'), findsOneWidget);
    }
    await negative.up();
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出多选'), findsOneWidget);

    final positive = await tester.startGesture(
      tester.getCenter(box('latest-unread')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    await positive.moveTo(tester.getCenter(box('older-read')));
    await tester.pump();
    await positive.up();
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    expect(box('middle-unread', checked: true), findsOneWidget);
    expect(videoService.lookups, isEmpty);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isFalse,
    );
    expect(store.writes, writesBefore);
    expect(store.value, snapshotsBefore);
  });

  testWidgets('source swipe can uncheck to zero and deletion still confirms', (
    tester,
  ) async {
    final service = SubscriptionService(contentService: Content());
    addTearDown(service.dispose);
    for (final id in [1, 2, 3]) {
      await service.addSource(source(id));
    }
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionSettingsPage(service: service)),
    );
    await tester.pumpAndSettle();

    Finder box(int id, {bool selected = false}) => find.descendant(
      of: find.byKey(ValueKey('subscription-source-creator:$id')),
      matching: find.byIcon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
      ),
    );
    await tester.longPress(find.text('源1'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 个来源'), findsOneWidget);
    final sourceGlyph = tester.getRect(box(2));
    final sourceAnchor = sourceGlyph.center + const Offset(12, 0);
    expect(sourceGlyph.contains(sourceAnchor), isFalse);
    final add = await tester.startGesture(sourceAnchor);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    await add.moveTo(tester.getCenter(box(3)));
    await tester.pump();
    await add.up();
    await tester.pumpAndSettle();
    expect(find.text('已选 3 个来源'), findsOneWidget);

    final remove = await tester.startGesture(
      tester.getCenter(box(1, selected: true)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await tester.pump();
    await remove.moveTo(tester.getCenter(box(3, selected: true)));
    await tester.pump();
    await remove.up();
    await tester.pumpAndSettle();
    expect(find.text('已选 0 个来源'), findsOneWidget);
    expect(
      tester.getSemantics(box(2)),
      isSemantics(hasCheckedState: true, isChecked: false, hasTapAction: true),
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.delete_outline),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(box(2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除所选'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除所选 1 个订阅源'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 个来源'), findsOneWidget);
    expect(service.sources.map((entry) => entry.key), [
      'creator:1',
      'creator:2',
      'creator:3',
    ]);
    expect(service.sources.every((entry) => !entry.paused), isTrue);
  });
  testWidgets(
    'off default, permission only on explicit notifications switch; rejection keeps list',
    (tester) async {
      final s = SubscriptionService();
      addTearDown(s.dispose);
      await s.initialize();
      final permission = Permission();
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionUpdatesPage(
            service: s,
            notificationService: permission,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('焦点订阅'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      await tester.tap(find.byTooltip('焦点订阅设置'));
      await tester.pumpAndSettle();
      expect(find.text('开启焦点订阅'), findsOneWidget);
      expect(permission.requests, 0);
      expect(s.enabled, false);
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      expect(s.enabled, true);
      expect(permission.requests, 0);
      await tester.tap(find.widgetWithText(SwitchListTile, '系统通知（默认关闭）'));
      await tester.pumpAndSettle();
      expect(permission.requests, 1);
      expect(s.notificationsEnabled, false);
      expect(find.text('通知未获授权，更新列表仍可使用。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('unresponsive source preview times out and remains cancellable', (
    tester,
  ) async {
    final content = HeldContent();
    final s = SubscriptionService(contentService: content);
    addTearDown(s.dispose);
    await s.setEnabled(true);
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionUpdatesPage(service: s)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('焦点订阅设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加 UP 主或 UGC 合集'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '1');
    await tester.tap(find.text('预览名称'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法预览'), findsOneWidget);
    expect(s.sources, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    content.profile.completeError(StateError('late error'));
    await tester.pump();
  });
  testWidgets(
    'cancel collection preview stops later pagination and leaves subscriptions unchanged',
    (tester) async {
      final content = HeldContent();
      final s = SubscriptionService(contentService: content);
      addTearDown(s.dispose);
      await s.setEnabled(true);
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionUpdatesPage(service: s)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('焦点订阅设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加 UP 主或 UGC 合集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UGC合集'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '1');
      await tester.enterText(find.byType(TextField).at(1), '2');
      await tester.tap(find.text('预览名称'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      content.collections.complete(
        const CreatorContentPage(
          items: [],
          page: 1,
          hasMore: true,
          totalCount: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(content.collectionCalls, 1);
      expect(s.sources, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'resolved source confirmation can cancel and prevents duplicate subscriptions',
    (tester) async {
      final s = SubscriptionService();
      addTearDown(s.dispose);
      await s.initialize();
      const source = SubscriptionSource(
        kind: SubscriptionKind.creator,
        mid: 42,
        name: '学习 UP',
        token: '42',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [FocusSubscriptionButton(service: s, source: source)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('加入焦点订阅'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确认来源：学习 UP'), findsOneWidget);
      expect(find.byType(SubscriptionSourceImage), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(s.sources, isEmpty);
      expect(s.enabled, isFalse);
      await tester.tap(find.byTooltip('加入焦点订阅'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认订阅'));
      await tester.pumpAndSettle();
      expect(s.sources.single.key, source.key);
      expect(s.enabled, isTrue);
      expect(find.byTooltip('取消焦点订阅'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('focus-subscribe-button')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('取消焦点订阅'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消订阅'));
      await tester.pumpAndSettle();
      expect(s.sources, isEmpty);
      expect(find.byTooltip('加入焦点订阅'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings back returns to feed without source controls', (
    tester,
  ) async {
    final s = SubscriptionService();
    addTearDown(s.dispose);
    await s.setEnabled(true);
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionUpdatesPage(service: s)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('焦点订阅设置'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('subscription-background-switch')),
      findsOneWidget,
    );
    expect(s.backgroundRefreshEnabled, isFalse);
    expect(find.text('最近后台检查：尚无记录'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('焦点订阅'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('添加 UP 主或 UGC 合集'), findsNothing);
  });
  testWidgets('source status explains initialization and failures honestly', (
    tester,
  ) async {
    final s = SubscriptionService();
    addTearDown(s.dispose);
    await s.setEnabled(true);
    const source = SubscriptionSource(
      kind: SubscriptionKind.creator,
      mid: 42,
      name: '状态来源',
      token: '42',
    );
    await s.addSource(source);
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionSettingsPage(service: s)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('正在读取最近两页'), 200);
    expect(find.text('基线已建立'), findsNothing);
    s.checkpoint(source.key)!.error = '网络不可用';
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionSettingsPage(key: UniqueKey(), service: s),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('获取已有内容失败 · 可重试此来源'), 200);
    s.checkpoint(source.key)!.initialized = true;
    s.checkpoint(source.key)!.error = null;
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionSettingsPage(key: UniqueKey(), service: s),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('已订阅更新'), 200);
    expect(find.text('已订阅更新'), findsOneWidget);
  });
  testWidgets(
    'failed subscription gives a reachable retry that resumes updates',
    (tester) async {
      final content = Content()
        ..pages[1] = [
          [item('existing')],
        ];
      final service = SubscriptionService(contentService: content);
      addTearDown(service.dispose);
      await service.addSource(source(1));
      await service.setEnabled(true);
      service.setForeground(true);
      await service.refresh(manual: true);
      expect(service.feed, isEmpty);

      content.pages[1] = [
        [item('new'), item('existing')],
      ];
      content.failPage = 1;
      await service.refresh(manual: true);
      expect(service.checkpoint('creator:1')!.retryAt, isNotNull);
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionSettingsPage(service: service)),
      );
      await tester.pumpAndSettle();
      final retry = find.text('重试此来源');
      await tester.scrollUntilVisible(retry, 150);
      content.failPage = null;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text('已订阅更新'), findsOneWidget);
      expect(service.feed.map((item) => item.bvid), ['new']);
      expect(tester.takeException(), isNull);
      service.setForeground(false);
    },
  );

  testWidgets(
    'creator link guidance and avatar preview preserve resolved metadata',
    (tester) async {
      final content = HeldContent();
      final s = SubscriptionService(contentService: content);
      addTearDown(s.dispose);
      await s.setEnabled(true);
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionSettingsPage(service: s)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加 UP 主或 UGC 合集'));
      await tester.pumpAndSettle();
      expect(find.textContaining('mid 是 UP 主空间网址中的数字'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'space.bilibili.com/42',
      );
      await tester.tap(find.text('预览名称'));
      content.profile.complete(
        const CreatorProfile(
          mid: 42,
          name: '头像来源',
          avatarUrl: 'https://example.com/avatar.jpg',
          sign: '',
          officialDescription: '',
        ),
      );
      await tester.pumpAndSettle();
      final image = tester.widget<SubscriptionSourceImage>(
        find.byType(SubscriptionSourceImage),
      );
      expect(image.source.mid, 42);
      expect(image.source.imageUrl, 'https://example.com/avatar.jpg');
      await tester.tap(find.text('确认订阅'));
      await tester.pumpAndSettle();
      expect(s.sources.single.imageUrl, 'https://example.com/avatar.jpg');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('ordinary series link is rejected before fetching collections', (
    tester,
  ) async {
    final content = HeldContent();
    final s = SubscriptionService(contentService: content);
    addTearDown(s.dispose);
    await s.setEnabled(true);
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionSettingsPage(service: s)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加 UP 主或 UGC 合集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UGC合集'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'https://space.bilibili.com/42/channel/seriesdetail?sid=9',
    );
    await tester.tap(find.text('预览名称'));
    await tester.pumpAndSettle();
    expect(find.text('暂不支持普通 series，请使用 UGC 合集'), findsOneWidget);
    expect(content.collectionCalls, 0);
    expect(s.sources, isEmpty);
  });
  testWidgets(
    'background polling is explicit and separate from notification permission',
    (tester) async {
      final scheduled = <bool>[];
      final s = SubscriptionService(
        platform: AppPlatform.android,
        backgroundScheduler: (enabled, generation) async {
          scheduled.add(enabled);
        },
      );
      addTearDown(s.dispose);
      await s.setEnabled(true);
      final permission = Permission();
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionSettingsPage(
            service: s,
            notificationService: permission,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(s.backgroundRefreshEnabled, isFalse);
      scheduled.clear();
      await tester.tap(find.byKey(const Key('subscription-background-switch')));
      await tester.pumpAndSettle();
      expect(s.backgroundRefreshEnabled, isTrue);
      expect(scheduled, contains(true));
      expect(s.notificationsEnabled, isFalse);
      expect(permission.requests, 0);
      expect(find.text('让每小时检查更可靠'), findsOneWidget);
      expect(find.textContaining('多任务界面加锁'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('subscription-background-switch')));
      await tester.pumpAndSettle();
      expect(s.backgroundRefreshEnabled, isFalse);
      expect(scheduled.last, isFalse);
    },
  );
}
