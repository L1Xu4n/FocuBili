import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/models/public_profile.dart';
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
      expect(find.text('开启订阅更新'), findsOneWidget);
      expect(permission.requests, 0);
      expect(s.enabled, false);
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      expect(s.enabled, true);
      expect(permission.requests, 0);
      await tester.tap(find.byType(SwitchListTile).last);
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
}
