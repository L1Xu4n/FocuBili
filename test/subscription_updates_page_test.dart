import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/focus_notification_service.dart';

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
      expect(find.byTooltip('已加入焦点订阅'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('focus-subscribe-button')))
            .onPressed,
        isNull,
      );
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
    await tester.scrollUntilVisible(find.text('正在获取已有内容'), 200);
    expect(find.text('基线已建立'), findsNothing);
    s.checkpoint(source.key)!.error = '网络不可用';
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionSettingsPage(key: UniqueKey(), service: s),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('获取已有内容失败 · 请刷新重试'), 200);
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
      await tester.tap(find.byKey(const Key('subscription-background-switch')));
      await tester.pumpAndSettle();
      expect(s.backgroundRefreshEnabled, isFalse);
      expect(scheduled.last, isFalse);
    },
  );
}
