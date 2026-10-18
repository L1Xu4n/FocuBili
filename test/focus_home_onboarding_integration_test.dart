import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/core/widgets/editable_card_board.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/home_drawer_scroll_physics.dart';
import 'package:focubili/features/subscriptions/subscription_introduction.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/services/subscription_onboarding_service.dart';
import 'package:focubili/services/subscription_service.dart';

class DelayedSubscriptionInitialization extends SubscriptionService {
  DelayedSubscriptionInitialization()
    : super(backgroundScheduler: (_, _) async {});

  final ready = Completer<void>();

  @override
  Future<void> initialize() async {
    await ready.future;
    await super.initialize();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FocusTimerController> mountDashboard(
    WidgetTester tester, {
    Widget? learningCard,
    Size size = const Size(430, 900),
    double textScale = 1,
    bool startFocus = false,
    SubscriptionService? subscriptionService,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final subscriptions =
        subscriptionService ??
        SubscriptionService(backgroundScheduler: (_, _) async {});
    addTearDown(subscriptions.dispose);
    final focus = FocusTimerController(tickInterval: const Duration(days: 1));
    addTearDown(focus.dispose);
    await focus.initialize();
    if (startFocus) {
      await focus.startFocus(
        goal: '合成专注测试',
        duration: const Duration(minutes: 25),
        startImmediately: true,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: FocusDashboard(
            controller: focus,
            subscriptionService: subscriptions,
            continueLearningCard: learningCard,
            onOpenVideo: () {},
            onOpenStatistics: () {},
            onOpenProfile: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return focus;
  }

  CustomScrollView outerView(WidgetTester tester) =>
      tester.widget<CustomScrollView>(find.byType(CustomScrollView).first);

  testWidgets('首次提示异步出现时清理旧手势，后续手势按当前高度吸附', (tester) async {
    final subscriptions = DelayedSubscriptionInitialization();
    await mountDashboard(tester, subscriptionService: subscriptions);
    expect(find.byKey(const Key('new-focus-subscription')), findsNothing);
    final scroll = outerView(tester).controller!;
    final physics = outerView(tester).physics! as HomeDrawerScrollPhysics;
    final gesture = await tester.startGesture(const Offset(8, 650));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(physics.gestureStart(), isNotNull);
    subscriptions.ready.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SubscriptionIntroduction), findsOneWidget);
    expect(find.byKey(const Key('new-focus-subscription')), findsOneWidget);
    expect(physics.gestureStart(), isNull);
    await gesture.up();
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(CustomScrollView).first,
      const Offset(0, -120),
      2500,
    );
    await tester.pumpAndSettle();
    expect(
      scroll.offset,
      closeTo(
        physics.cardOffset().clamp(0.0, scroll.position.maxScrollExtent) / 2,
        2,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑卡片时接受订阅引导重置编辑手势，专注会话连续且恢复三档吸附', (tester) async {
    final focus = await mountDashboard(tester, startFocus: true);
    final sessionId = focus.activeSession!.id;
    final originalKey = tester
        .widget<EditableCardBoard>(find.byType(EditableCardBoard))
        .key;
    final scroll = outerView(tester).controller!;
    await tester.ensureVisible(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(
      (outerView(tester).physics! as HomeDrawerScrollPhysics).enabled(),
      isFalse,
    );
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-focus-subscription')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('好，开启焦点订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('好的'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      tester.widget<EditableCardBoard>(find.byType(EditableCardBoard)).key,
      isNot(originalKey),
    );
    expect(find.text('自定义'), findsOneWidget);
    final physics = outerView(tester).physics! as HomeDrawerScrollPhysics;
    expect(physics.enabled(), isTrue);
    expect(physics.gestureStart(), isNull);
    expect(focus.activeSession?.id, sessionId);
    expect(focus.activeSession?.status, FocusSessionStatus.running);
    final view = find.byType(CustomScrollView).first;
    await tester.fling(view, const Offset(0, -120), 2500);
    await tester.pumpAndSettle();
    expect(
      scroll.offset,
      closeTo(
        physics.cardOffset().clamp(0.0, scroll.position.maxScrollExtent) / 2,
        2,
      ),
    );
    expect(focus.activeSession?.id, sessionId);
    expect(focus.activeSession?.status, FocusSessionStatus.running);
    await focus.pauseFocus();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字拒绝订阅提示后恢复高度，下一次手势使用新抽屉范围', (tester) async {
    await mountDashboard(tester, size: const Size(360, 720), textScale: 2.5);
    final hero = find.byKey(const Key('focus-home-hero'));
    final visibleHeight = tester.getSize(hero).height;
    final scroll = outerView(tester).controller!;
    await tester.ensureVisible(find.byKey(const Key('new-focus-subscription')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-focus-subscription')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我不需要焦点订阅'));
    await tester.pumpAndSettle();
    final hiddenHeight = tester.getSize(hero).height;
    expect(hiddenHeight, lessThan(visibleHeight));
    final physics = outerView(tester).physics! as HomeDrawerScrollPhysics;
    expect(physics.cardOffset(), closeTo(hiddenHeight + 12, .01));
    expect(physics.gestureStart(), isNull);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(physics.enabled(), isTrue);
    await tester.fling(
      find.byType(CustomScrollView).first,
      const Offset(0, -120),
      2500,
    );
    await tester.pumpAndSettle();
    expect(
      scroll.offset,
      closeTo(
        physics.cardOffset().clamp(0.0, scroll.position.maxScrollExtent) / 2,
        2,
      ),
    );
    expect(find.byKey(const Key('new-focus-subscription')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片内部滚动与内容区长甩不会关闭已打开的首页抽屉', (tester) async {
    SharedPreferences.setMockInitialValues({
      SubscriptionOnboardingService.choiceKey: 'declined',
    });
    final inner = ScrollController();
    addTearDown(inner.dispose);
    await mountDashboard(
      tester,
      learningCard: SizedBox(
        height: 280,
        child: ListView.builder(
          key: const Key('synthetic-inner-list'),
          controller: inner,
          itemCount: 60,
          itemExtent: 50,
          itemBuilder: (_, index) => Text('合成学习条目 $index'),
        ),
      ),
    );
    final scroll = outerView(tester).controller!;
    final physics = outerView(tester).physics! as HomeDrawerScrollPhysics;
    final openOffset = physics.cardOffset();
    scroll.jumpTo(openOffset);
    await tester.pumpAndSettle();
    await tester.fling(
      find.byKey(const Key('synthetic-inner-list')),
      const Offset(0, -150),
      3000,
    );
    await tester.pumpAndSettle();
    expect(inner.offset, greaterThan(0));
    expect(scroll.offset, closeTo(openOffset, .01));
    expect(physics.gestureStart(), isNull);

    scroll.jumpTo(openOffset + 350);
    await tester.pumpAndSettle();
    await tester.flingFrom(const Offset(8, 350), const Offset(0, 450), 5000);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(openOffset, 2));
    expect(tester.takeException(), isNull);
  });
}
