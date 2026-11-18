import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/widgets/editable_card_board.dart';
import 'package:focubili/features/focus/focus_dashboard.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/home_drawer_scroll_physics.dart';
import 'package:focubili/features/focus/home_drawer_hero_depth.dart';
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
  bool reduceMotion = false,
  bool accessibleNavigation = false,
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
        data: MediaQuery.of(context).copyWith(
          textScaler: textScaler,
          disableAnimations: reduceMotion,
          accessibleNavigation: accessibleNavigation,
        ),
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
    '慢拉可以停在中间，卡片跟手不重建，欢迎内容按正式版下坠',
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
      expect(tester.getTopLeft(_search).dy - searchTop, closeTo(42 * .32, .1));
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

  testWidgets('欢迎区按 v1.8.1 的连续曲线下坠和模糊，出屏后不保留滤镜', (tester) async {
    var builds = 0;
    final scroll = await _mount(
      tester,
      cardHeight: 1500,
      onBuildCard: () => builds++,
    );
    final initialBuilds = builds;
    final restingSearch = tester.getTopLeft(_search).dy;
    final restingCard = tester.getTopLeft(_firstCard).dy;
    final firstSearchElement = _search.evaluate().single;
    final subtree = find.byKey(
      const Key('focus-home-hero'),
      skipOffstage: false,
    );
    final filter = find.descendant(
      of: subtree,
      matching: find.byType(ImageFiltered, skipOffstage: false),
      skipOffstage: false,
    );
    final opacity = find
        .descendant(
          of: subtree,
          matching: find.byType(Opacity, skipOffstage: false),
          skipOffstage: false,
        )
        .first;
    expect(tester.widget<ImageFiltered>(filter).enabled, isFalse);
    final open = tester.getSize(_hero).height + 12;
    for (final offset in [1.0, 42.0, 140.0, 280.0, open / 2, 140.0, 42.0]) {
      scroll.jumpTo(offset);
      await tester.pump();
      final p = (offset / 280).clamp(0.0, 1.0);
      final visual = tester.widget<ImageFiltered>(filter);
      expect(visual.enabled, isTrue);
      expect(
        visual.imageFilter,
        ui.ImageFilter.blur(sigmaX: p * 7, sigmaY: p * 7),
      );
      expect(
        tester.widget<Opacity>(opacity).opacity,
        closeTo(1 - .88 * p, 1e-8),
      );
      expect(
        tester.getTopLeft(_search).dy,
        closeTo(restingSearch + offset * .32, .01),
      );
      expect(
        tester.getTopLeft(_firstCard).dy,
        closeTo(restingCard - offset, .01),
      );
      expect(_search.evaluate().single, same(firstSearchElement));
    }
    scroll.jumpTo(open);
    await tester.pump();
    expect(tester.widget<ImageFiltered>(filter).enabled, isFalse);
    expect(_search.hitTestable(), findsNothing);
    for (var i = 0; i < 20; i++) {
      scroll.jumpTo(open + 5.0 * i);
      await tester.pump();
      expect(tester.widget<ImageFiltered>(filter).enabled, isFalse);
    }
    expect(builds, initialBuilds);
    scroll.jumpTo(0);
    await tester.pump();
    expect(tester.widget<ImageFiltered>(filter).enabled, isFalse);
    expect(tester.getTopLeft(_search).dy, closeTo(restingSearch, .01));
    expect(_search.hitTestable(), findsOneWidget);
  });

  for (final screenReader in [false, true]) {
    testWidgets('减少动态效果或辅助导航保留清晰、自然滚动和搜索：辅助导航=$screenReader', (tester) async {
      var searches = 0;
      final scroll = await _mount(
        tester,
        reduceMotion: !screenReader,
        accessibleNavigation: screenReader,
        onSearch: () => searches++,
      );
      final y = tester.getTopLeft(_search).dy;
      scroll.jumpTo(85);
      await tester.pumpAndSettle();
      final filter = find.descendant(
        of: _hero,
        matching: find.byType(ImageFiltered),
      );
      expect(tester.widget<ImageFiltered>(filter).enabled, isFalse);
      expect(tester.getTopLeft(_search).dy, closeTo(y - 85, .01));
      expect(_search.hitTestable(), findsOneWidget);
      await tester.tap(_search);
      expect(searches, 1);
    });
  }

  testWidgets('59 个滚动采样不重建或重绘静态欢迎子树', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var builds = 0;
    var paints = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: scroll,
            slivers: [
              SliverToBoxAdapter(
                child: HomeDrawerHeroDepth(
                  height: 720,
                  enabled: true,
                  child: Builder(
                    builder: (context) {
                      builds++;
                      return CustomPaint(painter: _PaintProbe(() => paints++));
                    },
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 1800)),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final initialBuilds = builds, initialPaints = paints;
    expect(initialPaints, greaterThan(0));
    for (var i = 1; i <= 59; i++) {
      scroll.jumpTo(i * 16.0);
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(builds, initialBuilds);
    expect(paints, initialPaints);
  });

  testWidgets('工作期间切换系统减动，不要换掉当前键盘焦点', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final reduce = ValueNotifier(false);
    addTearDown(reduce.dispose);
    final node = FocusNode();
    addTearDown(node.dispose);
    const buttonKey = ValueKey('stable-keyboard-control');
    await t.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: reduce,
          builder: (context, value, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value),
            child: child!,
          ),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: HomeDrawerHeroDepth(
                  height: 640,
                  enabled: true,
                  child: Center(
                    child: TextButton(
                      key: buttonKey,
                      focusNode: node,
                      onPressed: () {},
                      child: const Text('搜索'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    node.requestFocus();
    await t.pump();
    final old = find.byKey(buttonKey).evaluate().single;
    for (final update in [true, false]) {
      reduce.value = update;
      await t.pumpAndSettle();
      expect(find.byKey(buttonKey).evaluate().single, same(old));
      expect(node.hasFocus, isTrue);
    }
  });

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

  testWidgets(
    '窄桌面窗口鼠标滚轮连续移动，亦支持按住拖动',
    _checkDesktopPointer,
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}

Future<void> _checkDesktopPointer(WidgetTester tester) async {
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
}

class _PaintProbe extends CustomPainter {
  const _PaintProbe(this.painted);
  final VoidCallback painted;
  @override
  void paint(Canvas canvas, Size size) {
    painted();
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 30, Paint());
  }

  @override
  bool shouldRepaint(_PaintProbe oldDelegate) => false;
}
