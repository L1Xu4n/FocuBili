import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/widgets/editable_card_board.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/home_drawer_scroll_physics.dart';
import 'package:focubili/services/dashboard_layout_service.dart';
import 'package:focubili/services/subscription_onboarding_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _hero = find.byKey(const Key('focus-home-hero'));
final _search = find.byKey(const Key('home-start-search'));
final _firstCard = find.byKey(const Key('test-first-home-card'));

Future<ScrollController> _mount(
  WidgetTester tester, {
  Size size = const Size(430, 900),
  double cardHeight = 240,
  TextScaler textScaler = TextScaler.noScaling,
  double topInset = 0,
  VoidCallback? onSearch,
  VoidCallback? onBuildCard,
  Map<String, Object> preferences = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    SubscriptionOnboardingService.choiceKey: 'declined',
    ...preferences,
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final focus = FocusTimerController(tickInterval: const Duration(days: 1));
  addTearDown(focus.dispose);
  final subscriptions = SubscriptionService(
    backgroundScheduler: (_, _) async {},
  );
  addTearDown(subscriptions.dispose);
  await focus.initialize();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: FocusDashboard(
            controller: focus,
            subscriptionService: subscriptions,
            onOpenVideo: onSearch ?? () {},
            onOpenStatistics: () {},
            onOpenProfile: () {},
            onOpenLearningList: () {},
            continueLearningCard: Builder(
              builder: (context) {
                onBuildCard?.call();
                return SizedBox(
                  height: cardHeight,
                  child: const Card(
                    key: Key('test-first-home-card'),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Text('第一张卡片'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester
      .widget<CustomScrollView>(find.byType(CustomScrollView).first)
      .controller!;
}

void main() {
  testWidgets('一次快速上滑全开、反向一次关闭，中间不需要第二次手势', (tester) async {
    final scroll = await _mount(tester);
    final open = tester.getSize(_hero).height + 12;
    await tester.flingFrom(const Offset(10, 400), const Offset(0, -120), 2500);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(open, 1));
    expect(tester.getTopLeft(_firstCard).dy, closeTo(0, 1));

    await tester.flingFrom(const Offset(10, 400), const Offset(0, 120), 2500);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(0, 1));
    expect(_search.hitTestable(), findsOneWidget);
  });

  testWidgets(
    '慢拉可以停在中间，内容和首屏按钮始终跟手且卡片不重建',
    (tester) async {
      var cardBuilds = 0;
      final scroll = await _mount(tester, onBuildCard: () => ++cardBuilds);
      final half = (tester.getSize(_hero).height + 12) / 2;
      final searchTop = tester.getTopLeft(_search).dy;
      final cardTop = tester.getTopLeft(_firstCard).dy;
      final buildsBefore = cardBuilds;
      final gesture = await tester.startGesture(const Offset(10, 740));
      await gesture.moveBy(const Offset(0, -42));
      await tester.pump();
      expect(scroll.offset, closeTo(42, .1));
      expect(searchTop - tester.getTopLeft(_search).dy, closeTo(42, .1));
      expect(cardTop - tester.getTopLeft(_firstCard).dy, closeTo(42, .1));
      await gesture.moveBy(Offset(0, 42 - half + 12));
      await tester.pump();
      expect(scroll.offset, closeTo(half - 12, .1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(half, 1));
      expect(cardBuilds, buildsBefore);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('砍断仍在进行的展开吸附，反向手势从当前帧起走', (tester) async {
    final scroll = await _mount(tester);
    final open = tester.getSize(_hero).height + 12;
    await tester.flingFrom(const Offset(10, 400), const Offset(0, -120), 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(scroll.offset, inInclusiveRange(120, open / 2));
    final before = scroll.offset;
    final undo = await tester.startGesture(const Offset(10, 330));
    await undo.moveBy(const Offset(0, 110));
    await tester.pump();
    expect(scroll.offset, closeTo(before - 110, .1));
    await undo.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(0, 1));
  });

  testWidgets('长列表保持同一拖动衔接，惯性返回止于列表顶部', (tester) async {
    final scroll = await _mount(tester, cardHeight: 1400);
    final open = tester.getSize(_hero).height + 12;
    final pull = await tester.startGesture(const Offset(10, 880));
    await pull.moveBy(Offset(0, -open + 20));
    await tester.pump();
    expect(scroll.offset, closeTo(open - 20, .1));
    await pull.moveBy(const Offset(0, -85));
    await tester.pump();
    expect(scroll.offset, closeTo(open + 65, .1));
    await pull.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(open + 65, 1));

    scroll.jumpTo(open + 510);
    await tester.pump();
    await tester.flingFrom(const Offset(10, 150), const Offset(0, 230), 5000);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(open, 1));
    expect(_search.hitTestable(), findsNothing);

    scroll.jumpTo(open + 30);
    await tester.pump();
    final close = await tester.startGesture(const Offset(10, 150));
    await close.moveBy(const Offset(0, 140));
    await tester.pump();
    expect(scroll.offset, closeTo(open - 110, .1));
    await close.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(0, 1));
  });

  testWidgets(
    '仍在列表顶部附近时，快速下拉明确越过边界可以一次关闭',
    (tester) async {
      final scroll = await _mount(tester, cardHeight: 1400);
      final open = tester.getSize(_hero).height + 12;
      for (final depth in [110.0, 320.0]) {
        scroll.jumpTo(open + depth);
        await tester.pump();
        await tester.flingFrom(
          const Offset(10, 250),
          Offset(0, depth + 150),
          5000,
        );
        await tester.pumpAndSettle();
        expect(scroll.offset, closeTo(0, 1), reason: 'list depth $depth');
        expect(_search.hitTestable(), findsOneWidget);
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('矮屏短列表能彻底收起欢迎区，不留透明墙或多余滚动范围', (tester) async {
    final scroll = await _mount(
      tester,
      size: const Size(350, 480),
      cardHeight: 50,
      topInset: 34,
      preferences: {
        DashboardLayoutService.storageKey('home'): jsonEncode({
          'order': ['home.continue_learning'],
          'hidden': [
            'home.focus_session',
            'home.today_summary',
            'home.recent_history',
            'home.quick_actions',
          ],
        }),
      },
    );
    final open = tester.getSize(_hero).height + 12;
    expect(scroll.position.maxScrollExtent, closeTo(open, .1));
    await tester.flingFrom(const Offset(10, 320), const Offset(0, -120), 2500);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(open, 1));
    expect(tester.getTopLeft(_firstCard).dy, closeTo(34, 1));
    expect(_search.hitTestable(), findsNothing);
  });

  testWidgets('抽屉关掉或卡片全部隐藏，不响应上拉也不拦搜索', (tester) async {
    for (final preferences in [
      {'dashboard.home_drawer_enabled': false},
      {
        DashboardLayoutService.storageKey('home'): jsonEncode({
          'order': <String>[],
          'hidden': [
            'home.continue_learning',
            'home.focus_session',
            'home.today_summary',
            'home.recent_history',
            'home.quick_actions',
          ],
        }),
      },
    ]) {
      var searches = 0;
      final scroll = await _mount(
        tester,
        preferences: preferences,
        onSearch: () => searches++,
      );
      expect(find.byType(EditableCardBoard), findsNothing);
      expect(find.byKey(const Key('home-scroll-hint')), findsNothing);
      expect(scroll.position.maxScrollExtent, 0);
      await tester.flingFrom(
        const Offset(10, 450),
        const Offset(0, -250),
        2500,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      await tester.tap(_search);
      expect(searches, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('极窄大字首屏保留自然滚动，不在搜索前抢吸附', (tester) async {
    final scroll = await _mount(
      tester,
      size: const Size(320, 344),
      topInset: 28,
      textScaler: const TextScaler.linear(2.5),
    );
    final physics =
        tester
                .widget<CustomScrollView>(find.byType(CustomScrollView).first)
                .physics!
            as HomeDrawerScrollPhysics;
    expect(physics.enabled(), isFalse);
    await tester.dragFrom(const Offset(8, 210), const Offset(0, -130));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(130, 1));
    await tester.ensureVisible(_search);
    await tester.pumpAndSettle();
    expect(_search.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄桌面窗口鼠标滚轮连续移动，亦支持按住拖动', (tester) async {
    final scroll = await _mount(tester, size: const Size(720, 560));
    final open = tester.getSize(_hero).height + 12;
    final pointer = TestPointer(42, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(10, 280)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 128)));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(128, 1));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -128)));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(0, 1));

    final gesture = await tester.startGesture(
      const Offset(10, 280),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(scroll.offset, closeTo(100, 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(open, 1));
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));
}
