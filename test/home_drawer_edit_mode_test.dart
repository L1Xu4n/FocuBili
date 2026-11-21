import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/core/widgets/editable_card_board.dart';
import 'package:focubili/features/home/home_page.dart';
import 'package:focubili/features/focus/focus_statistics_page.dart';
import 'package:focubili/features/focus/focus_timer_scope.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/profile/about_page.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/features/shell/main_shell.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/services/app_update_service.dart';
import 'package:focubili/services/dashboard_layout_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/following_group_service.dart';
import 'package:focubili/services/subscription_onboarding_service.dart';

import 'subscription_performance_probe_test.dart'
    show feedFixture, feedFixtureClock;

const _ids = [
  'home.continue_learning',
  'home.focus_finished',
  'home.focus_session',
  'home.today_summary',
  'home.recent_history',
  'home.quick_actions',
  'home.focus_subscriptions',
  'home.favorites',
  'home.followings',
];
const _favoriteKey = 'home_collection.v1.favorites.0';
Map<String, Object> _prefs({bool allHidden = false, bool enabled = true}) => {
  SubscriptionOnboardingService.choiceKey: 'declined',
  'dashboard.home_drawer_enabled': enabled,
  'dashboard.layout.home': jsonEncode({
    'version': 1,
    'order': _ids,
    'hidden': allHidden
        ? _ids
        : _ids
              .where(
                (id) => !['home.favorites', 'home.followings'].contains(id),
              )
              .toList(),
  }),
  'app_favorites.folders_v1': jsonEncode([
    {
      'id': 'qa',
      'name': '课程资料',
      'createdAt': '2026-01-01',
      'updatedAt': '2026-01-01',
    },
  ]),
  _favoriteKey: jsonEncode({
    'custom': true,
    'items': [
      {'kind': 'local', 'id': 'qa', 'label': '课程资料'},
    ],
  }),
};
Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  DashboardLayoutService? service,
  SubscriptionService? subscriptions,
  TargetPlatform? platform,
  bool useMainShell = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final focus = FocusTimerController(tickInterval: const Duration(days: 1));
  await focus.initialize();
  addTearDown(focus.dispose);
  final updates = useMainShell ? AppUpdateController() : null;
  if (updates != null) addTearDown(updates.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: (size.width > 900 ? ThemeData.dark() : ThemeData.light()).copyWith(
        platform: platform,
      ),
      onGenerateRoute: useMainShell ? AppRouter.onGenerateRoute : null,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(scale),
        ),
        child: FocusTimerScope(
          controller: focus,
          child: updates == null
              ? child!
              : AppUpdateScope(controller: updates, child: child!),
        ),
      ),
      home: useMainShell
          ? MainShell(subscriptionService: subscriptions)
          : Scaffold(
              body: HomePage(
                onSearchRequested: () {},
                onProfileRequested: () {},
                layoutService: service,
              ),
            ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await _settle(tester);
}

class _DelayedClose extends DashboardLayoutService {
  final closing = Completer<void>();
  final writes = <bool>[];
  @override
  Future<void> saveDrawerEnabled(bool enabled) async {
    writes.add(enabled);
    if (!enabled) await closing.future;
    await super.saveDrawerEnabled(enabled);
  }
}

class _RejectedClose extends DashboardLayoutService {
  @override
  Future<void> saveDrawerEnabled(bool enabled) async {
    if (!enabled) throw StateError('storage rejected');
    await super.saveDrawerEnabled(enabled);
  }
}

class _DelayedLayout extends DashboardLayoutService {
  final gate = Completer<bool>();
  @override
  Future<bool> loadDrawerEnabled() => gate.future;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await BilibiliAuthService().loadCurrentSession();
    await SubscriptionService.instance.initialize();
    await FollowingGroupService.instance.load(1);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(_prefs());
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.focubili.app/auth'),
          (call) async => call.method == 'readCookies' ? '' : null,
        );
  });
  testWidgets('真实首页底部自定义才开放两卡个性化，编辑不导航且退出恢复', (tester) async {
    await _mount(tester);
    expect(find.byTooltip('自定义首页'), findsNothing);
    expect(find.byTooltip('自定义内容'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(_favoriteKey);
    await _tap(tester, find.text('自定义'));
    expect(find.byTooltip('自定义内容'), findsNWidgets(2));
    await _tap(tester, find.text('课程资料'));
    expect(find.byType(AppFavoriteDetailPage), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('customize-home-favorites')));
    expect(find.text('保存'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-mode-custom')), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);
    expect(prefs.getString(_favoriteKey), before);
    await _tap(tester, find.byKey(const ValueKey('customize-home-followings')));
    expect(find.text('保存'), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);
    await _tap(tester, find.text('完成'));
    expect(find.byTooltip('自定义内容'), findsNothing);
    await _tap(tester, find.text('课程资料'));
    expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
  });
  testWidgets('编辑个性化保存与取消有不同结果，重启保留选择', (tester) async {
    await _mount(tester);
    await _tap(tester, find.text('自定义'));
    await _tap(tester, find.byKey(const ValueKey('customize-home-favorites')));
    await tester.tap(find.byKey(const ValueKey('home-mode-overview')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await _settle(tester);
    await _tap(tester, find.text('完成'));
    expect(find.text('课程资料'), findsNothing);
    expect(find.byTooltip('自定义内容'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _mount(tester);
    expect(find.text('课程资料'), findsNothing);
    await _tap(tester, find.text('自定义'));
    await _tap(tester, find.byKey(const ValueKey('customize-home-favorites')));
    await tester.tap(find.byKey(const ValueKey('home-mode-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.text('课程资料'), findsOneWidget);
  });
  testWidgets('隐藏最后卡片关闭抽屉，小按钮48dp恢复真实编辑且不擅自恢复顺序', (tester) async {
    await _mount(tester);
    await _tap(tester, find.text('自定义'));
    await _tap(
      tester,
      find.byKey(const ValueKey('dashboard-hide-home.favorites')),
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('dashboard-hide-home.followings')),
    );
    expect(find.byType(EditableCardBoard), findsNothing);
    final recovery = find.byKey(const Key('home-restore-drawer'));
    expect(recovery.hitTestable(), findsOneWidget);
    expect(tester.getSize(recovery).height, greaterThanOrEqualTo(48));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dashboard.home_drawer_enabled'), isFalse);
    final hidden = prefs.getString('dashboard.layout.home');
    await tester.pumpWidget(const SizedBox());
    await _mount(tester);
    expect(find.byType(EditableCardBoard), findsNothing);
    await _tap(tester, recovery);
    expect(find.text('添加卡片'), findsOneWidget);
    expect(find.text('自定义'), findsNothing);
    expect(find.text('我的收藏'), findsNothing);
    expect(prefs.getString('dashboard.layout.home'), hidden);
    await _tap(tester, find.text('添加卡片'));
    await _tap(tester, find.text('关闭'));
    expect(prefs.getString('dashboard.layout.home'), hidden);
    await _tap(tester, find.text('完成'));
    expect(recovery, findsOneWidget);
    await _tap(tester, recovery);
    await _tap(tester, find.text('添加卡片'));
    await _tap(
      tester,
      find.byKey(const ValueKey('dashboard-add-home.favorites')),
    );
    await _tap(tester, find.text('关闭'));
    expect(
      find.byKey(const ValueKey('customize-home-favorites')),
      findsOneWidget,
    );
    await _tap(tester, find.text('完成'));
    expect(recovery, findsNothing);
    expect(find.byTooltip('自定义内容'), findsNothing);
    final saved = jsonDecode(prefs.getString('dashboard.layout.home')!) as Map;
    expect(saved['hidden'], isNot(contains('home.favorites')));
    expect(saved['hidden'], contains('home.followings'));
    expect((saved['order'] as List).last, 'home.favorites');
    await tester.pumpWidget(const SizedBox());
    await _mount(tester);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('我的关注'), findsNothing);
    expect(find.byTooltip('自定义内容'), findsNothing);
  });
  testWidgets('编辑底部关闭保留卡片，关闭落盘前禁止恢复避免旧写反向迟到', (tester) async {
    final service = _DelayedClose();
    await _mount(tester, service: service);
    final prefs = await SharedPreferences.getInstance();
    final layout = prefs.getString('dashboard.layout.home');
    expect(find.text('关闭抽屉'), findsNothing);
    await _tap(tester, find.text('自定义'));
    await _tap(tester, find.text('关闭抽屉'));
    final recovery = find.byKey(const Key('home-restore-drawer'));
    expect(tester.widget<IconButton>(recovery).onPressed, isNull);
    expect(service.writes, [false]);
    expect(prefs.getString('dashboard.layout.home'), layout);
    service.closing.complete();
    await _settle(tester);
    expect(prefs.getBool('dashboard.home_drawer_enabled'), isFalse);
    await _tap(tester, recovery);
    expect(service.writes, [false, true]);
    expect(prefs.getBool('dashboard.home_drawer_enabled'), isTrue);
    expect(prefs.getString('dashboard.layout.home'), layout);
    expect(
      find.byKey(const ValueKey('customize-home-favorites')),
      findsOneWidget,
    );
    await _tap(tester, find.text('完成'));
    expect(find.text('关闭抽屉'), findsNothing);
    expect(find.text('课程资料'), findsOneWidget);
  });
  testWidgets('关闭存储失败恢复非空编辑，明确隐藏全部仍保留小入口', (tester) async {
    final service = _RejectedClose();
    await _mount(tester, service: service);
    final prefs = await SharedPreferences.getInstance();
    final layout = prefs.getString('dashboard.layout.home');
    await _tap(tester, find.text('自定义'));
    await _tap(tester, find.text('关闭抽屉'));
    expect(find.byKey(const Key('home-restore-drawer')), findsNothing);
    expect(find.text('课程资料'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('customize-home-favorites')),
      findsOneWidget,
    );
    expect(prefs.getString('dashboard.layout.home'), layout);
    expect(prefs.getBool('dashboard.home_drawer_enabled'), isTrue);
    for (final id in ['home.favorites', 'home.followings']) {
      await _tap(tester, find.byKey(ValueKey('dashboard-hide-$id')));
    }
    expect(find.byKey(const Key('home-restore-drawer')), findsOneWidget);
    expect(find.byType(EditableCardBoard), findsNothing);
    final hidden = jsonDecode(prefs.getString('dashboard.layout.home')!) as Map;
    expect(
      hidden['hidden'],
      containsAll(['home.favorites', 'home.followings']),
    );
  });
  testWidgets('加载未完成和不可用卡片不冒充全部隐藏', (tester) async {
    final service = _DelayedLayout();
    SharedPreferences.setMockInitialValues(_prefs(allHidden: true));
    await _mount(tester, service: service);
    expect(find.byKey(const Key('home-restore-drawer')), findsNothing);
    service.gate.complete(true);
    await _settle(tester);
    expect(find.byKey(const Key('home-restore-drawer')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.setMockInitialValues({
      ..._prefs(),
      'dashboard.layout.home': jsonEncode({
        'version': 1,
        'order': _ids,
        'hidden': ['home.favorites', 'home.followings'],
      }),
    });
    await _mount(tester);
    expect(find.byType(EditableCardBoard), findsOneWidget);
    expect(find.byKey(const Key('home-restore-drawer')), findsNothing);
  });
  testWidgets('卡片个性化保留键盘焦点与语义，其他内容不误操作', (tester) async {
    await _mount(tester);
    await _tap(tester, find.text('自定义'));
    final button = find.byKey(const ValueKey('customize-home-favorites'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();

    await tester.pump();
    final semanticButton = find.bySemanticsLabel('自定义我的收藏');
    expect(semanticButton, findsOneWidget);
    expect(
      tester
          .getSemantics(semanticButton)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    semantics.dispose();
    bool focused = false;
    for (var i = 0; i < 40 && !focused; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        if (element.widget.key == const ValueKey('customize-home-favorites')) {
          focused = true;
          return false;
        }
        return true;
      });
    }
    expect(focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(find.text('保存'), findsOneWidget);
  });
  testWidgets('全隐藏小抽屉具备语义且键盘 Enter 进入真实编辑', (tester) async {
    SharedPreferences.setMockInitialValues(_prefs(allHidden: true));
    await _mount(tester);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    final recovery = find.byKey(const Key('home-restore-drawer'));
    final data = tester.getSemantics(recovery).getSemanticsData();
    expect(data.tooltip, '启用抽屉并编辑');
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
    var focused = false;
    for (var i = 0; i < 15 && !focused; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        if (element.widget.key == const Key('home-restore-drawer')) {
          focused = true;
          return false;
        }
        return true;
      });
    }
    expect(focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(find.text('添加卡片'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('自定义'), findsNothing);
  });
  for (final c in [(const Size(320, 740), 2.0), (const Size(1200, 800), 1.0)]) {
    testWidgets('宽窄首页移除顶部编辑且恢复按钮适配 ${c.$1}', (tester) async {
      SharedPreferences.setMockInitialValues(_prefs(allHidden: true));
      await _mount(tester, size: c.$1, scale: c.$2);
      expect(find.byTooltip('自定义首页'), findsNothing);
      await _tap(tester, find.byKey(const Key('home-restore-drawer')));
      expect(find.text('添加卡片'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('添加卡片'));
      await _tap(
        tester,
        find.byKey(const ValueKey('dashboard-add-home.followings')),
      );
      await _tap(tester, find.text('关闭'));
      await _tap(
        tester,
        find.byKey(const ValueKey('customize-home-followings')),
      );
      expect(find.text('保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(1440, 900), const Size(900, 600)]) {
    testWidgets('桌面打开与收起保持左右分栏、卡片状态和搜索交互 $size', (tester) async {
      SharedPreferences.setMockInitialValues({
        SubscriptionOnboardingService.choiceKey: 'declined',
      });
      await _mount(
        tester,
        size: size,
        platform: TargetPlatform.windows,
        useMainShell: true,
      );
      final open = find.byKey(const Key('desktop-dock-open'));
      final collapse = find.byKey(const Key('desktop-dock-collapse'));
      final dock = find.byKey(const Key('desktop-learning-dock'));
      final search = find.byKey(const Key('home-start-search'));
      final title = find.text('今天要学点什么？');
      final rail = find.byKey(const Key('workspace-navigation-rail'));
      final goal = find.byKey(const Key('focus-goal-field'));
      final customize = find.widgetWithText(TextButton, '自定义');
      final width = size.width;
      final height = size.height;
      void checkCenter(double right) {
        final centerX = (tester.getTopRight(rail).dx + 1 + right) / 2;
        expect(tester.getCenter(title).dx, closeTo(centerX, 1));
        expect(tester.getCenter(search).dx, closeTo(centerX, 1));
        expect(
          (tester.getTopLeft(title).dy + tester.getBottomLeft(search).dy) / 2,
          closeTo(height / 2, 1),
        );
      }

      checkCenter(width);
      expect(tester.getTopRight(open).dx, closeTo(width - 16, 1));
      expect(tester.getTopRight(open).dy, closeTo(12, 1));
      expect(dock, findsNothing);
      await _tap(tester, open);
      expect(open, findsNothing);
      final seam = tester.getTopLeft(dock).dx;
      expect(find.text('学习抽屉'), findsNothing);
      expect(
        (tester.widget<Container>(dock).decoration as BoxDecoration).color,
        isNull,
      );
      final firstCard = find.byKey(const Key('continue-learning-empty'));
      expect(
        tester.getTopLeft(firstCard).dy - tester.getTopLeft(dock).dy,
        lessThan(24),
      );
      checkCenter(seam);
      expect(tester.getCenter(collapse).dy, closeTo(height / 2, 1));
      expect(tester.getTopRight(collapse).dx, closeTo(seam, 1));
      expect(customize, findsOneWidget);
      final cards = find.descendant(of: dock, matching: find.byType(Card));
      for (final card in cards.evaluate()) {
        expect(
          tester.getBottomLeft(find.byWidget(card.widget)).dy,
          lessThan(tester.getTopLeft(customize).dy),
        );
      }
      await tester.ensureVisible(goal);
      await tester.enterText(goal, '连续性测试');
      await _tap(tester, collapse);
      expect(dock, findsNothing);
      checkCenter(width);
      await _tap(tester, open);
      expect(tester.widget<TextField>(goal).controller!.text, '连续性测试');
      await _tap(tester, search);
      expect(find.byKey(const Key('search-workspace-layout')), findsOneWidget);
      await _tap(tester, find.descendant(of: rail, matching: find.text('首页')));
      expect(dock, findsOneWidget);
      await _tap(tester, customize);
      expect(find.text('完成'), findsOneWidget);
      await _tap(tester, collapse);
      await _tap(tester, open);
      expect(find.text('完成'), findsOneWidget);
      await _tap(tester, find.text('完成'));
      expect(tester.takeException(), isNull);
    });
  }

  for (final desktop in [true, false]) {
    testWidgets('今日汇总整卡进入专注统计，编辑时不打开 desktop=$desktop', (tester) async {
      SharedPreferences.setMockInitialValues({
        ..._prefs(),
        'dashboard.layout.home': jsonEncode({
          'version': 1,
          'order': _ids,
          'hidden': _ids.where((id) => id != 'home.today_summary').toList(),
        }),
      });
      await _mount(
        tester,
        size: desktop ? const Size(1440, 900) : const Size(390, 844),
        platform: desktop ? TargetPlatform.windows : TargetPlatform.android,
        useMainShell: true,
      );
      if (desktop) {
        await _tap(tester, find.byKey(const Key('desktop-dock-open')));
      }
      final card = find.byKey(const Key('focus-today-summary'));
      final action = find.byKey(
        const Key('focus-today-summary-open-statistics'),
      );
      final page = find.byType(FocusStatisticsPage);
      final semantics = tester.ensureSemantics();

      for (final label in ['今日专注', '按时完成']) {
        expect(
          tester
              .getSemantics(action)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        await _tap(
          tester,
          find.descendant(of: card, matching: find.text(label)),
        );
        expect(page, findsOneWidget);
        expect(
          ModalRoute.of(tester.element(page))?.settings.name,
          AppRoutes.focusStatistics,
        );
        expect(await tester.binding.handlePopRoute(), isTrue);
        await _settle(tester);
        expect(page, findsNothing);
        expect(card, findsOneWidget);
      }

      await _tap(tester, find.widgetWithText(TextButton, '自定义'));
      expect(action, findsNothing);
      expect(
        find.byKey(const ValueKey('dashboard-hide-home.today_summary')),
        findsOneWidget,
      );
      await _tap(
        tester,
        find.descendant(of: card, matching: find.text('按时完成')),
      );
      expect(page, findsNothing);
      await _tap(tester, find.text('完成'));
      expect(action, findsOneWidget);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('桌面订阅按钮在右栏开合时只由订阅开关控制', (tester) async {
    final snapshot = jsonDecode(feedFixture(count: 3, sourceCount: 1)) as Map
      ..['enabled'] = false;
    SharedPreferences.setMockInitialValues({
      ..._prefs(),
      SubscriptionService.storageKey: jsonEncode(snapshot),
    });
    final subscriptions = SubscriptionService(clock: () => feedFixtureClock);
    addTearDown(subscriptions.dispose);
    await _mount(
      tester,
      size: const Size(1280, 800),
      platform: TargetPlatform.windows,
      useMainShell: true,
      subscriptions: subscriptions,
    );
    final shortcut = find.byKey(
      const Key('workspace-navigation-open-subscription'),
    );
    final rail = find.byKey(const Key('workspace-navigation-rail'));
    final open = find.byKey(const Key('desktop-dock-open'));
    final close = find.byKey(const Key('desktop-dock-collapse'));
    void check(bool enabled) {
      expect(shortcut, enabled ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('home-subscription-button')), findsNothing);
      if (enabled) {
        expect(find.descendant(of: rail, matching: shortcut), findsOneWidget);
        expect(
          find.descendant(of: shortcut, matching: find.byIcon(Icons.rss_feed)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: shortcut, matching: find.text('3')),
          findsOneWidget,
        );
        expect(
          tester.getCenter(shortcut).dy,
          greaterThan(
            tester
                .getCenter(find.descendant(of: rail, matching: find.text('我的')))
                .dy,
          ),
        );
      }
    }

    check(false);
    await subscriptions.setEnabled(true);
    await _settle(tester);
    check(true);
    await _tap(tester, open);
    check(true);
    await subscriptions.setEnabled(false);
    await _settle(tester);
    check(false);
    await _tap(tester, close);
    check(false);
    await _tap(tester, open);
    check(false);
    await subscriptions.setEnabled(true);
    await _settle(tester);
    check(true);
    await _tap(tester, close);
    check(true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面隐藏最后一张卡后关闭右栏，恢复只进入编辑不重置顺序', (tester) async {
    await _mount(
      tester,
      size: const Size(1366, 768),
      platform: TargetPlatform.windows,
    );
    final open = find.byKey(const Key('desktop-dock-open'));
    final dock = find.byKey(const Key('desktop-learning-dock'));
    final restore = find.byKey(const Key('home-restore-drawer'));
    await _tap(tester, open);
    await _tap(tester, find.widgetWithText(TextButton, '自定义'));
    for (final id in ['home.favorites', 'home.followings']) {
      await _tap(tester, find.byKey(ValueKey('dashboard-hide-$id')));
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dashboard.home_drawer_enabled'), isFalse);
    expect(dock, findsNothing);
    expect(open, findsNothing);
    final snapshot = prefs.getString('dashboard.layout.home');
    await _tap(tester, restore);
    expect(dock, findsOneWidget);
    expect(find.text('添加卡片'), findsOneWidget);
    expect(prefs.getString('dashboard.layout.home'), snapshot);
    await _tap(tester, find.text('完成'));
    expect(restore, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面首次读取抽屉配置时不闪现旧工作台', (tester) async {
    final service = _DelayedLayout();
    await _mount(
      tester,
      size: const Size(1280, 800),
      platform: TargetPlatform.linux,
      service: service,
    );
    final welcome = find.byKey(const Key('focus-minimal-workspace-home'));
    expect(welcome, findsNothing);
    expect(find.byKey(const Key('focus-workspace-intro')), findsNothing);
    expect(find.byType(EditableCardBoard), findsNothing);
    service.gate.complete(false);
    await _settle(tester);
    expect(welcome, findsOneWidget);
    expect(find.byKey(const Key('focus-workspace-intro')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final c in [
    (size: const Size(1280, 800), scale: 1.0, allHidden: false),
    (size: const Size(900, 600), scale: 2.0, allHidden: true),
  ]) {
    testWidgets('桌面精简首页与侧栏订阅及关于入口适配 ${c.size}', (tester) async {
      final snapshot = jsonDecode(feedFixture(count: 2, sourceCount: 1)) as Map
        ..['enabled'] = !c.allHidden;
      SharedPreferences.setMockInitialValues({
        ..._prefs(allHidden: c.allHidden, enabled: c.allHidden),
        SubscriptionService.storageKey: jsonEncode(snapshot),
      });
      final subscriptions = SubscriptionService(clock: () => feedFixtureClock);
      addTearDown(subscriptions.dispose);
      await _mount(
        tester,
        size: c.size,
        scale: c.scale,
        platform: TargetPlatform.windows,
        useMainShell: true,
        subscriptions: subscriptions,
      );
      final welcome = find.byKey(const Key('focus-minimal-workspace-home'));
      final rail = find.byKey(const Key('workspace-navigation-rail'));
      final search = find.byKey(const Key('home-start-search'));
      final restore = find.byKey(const Key('home-restore-drawer'));
      final about = find.byKey(const Key('workspace-navigation-open-about'));
      final subscription = find.byKey(
        const Key('workspace-navigation-open-subscription'),
      );
      final unread = find.descendant(
        of: subscription,
        matching: find.byType(Badge),
      );
      final title = find.text('今天要学点什么？');
      final profile = find.descendant(of: rail, matching: find.text('我的'));
      final profileIcon = find.descendant(
        of: rail,
        matching: find.byIcon(Icons.person_outline_rounded),
      );
      final subscriptionLabel = find.descendant(
        of: subscription,
        matching: find.text('焦点订阅'),
      );
      final subscriptionIcon = find.descendant(
        of: subscription,
        matching: find.byIcon(Icons.rss_feed),
      );

      expect(welcome, findsOneWidget);
      expect(find.byKey(const Key('focus-workspace-intro')), findsNothing);
      expect(find.text('焦点哔哩'), findsNothing);
      expect(find.descendant(of: rail, matching: about), findsOneWidget);
      expect(
        tester.getBottomLeft(about).dy,
        lessThan(tester.getTopLeft(profile).dy),
      );
      if (c.allHidden) {
        expect(subscription, findsNothing);
        await subscriptions.setEnabled(true);
        await _settle(tester);
      }
      expect(find.descendant(of: rail, matching: subscription), findsOneWidget);
      expect(subscriptionLabel, findsOneWidget);
      expect(subscriptionIcon, findsOneWidget);
      expect(
        tester.getCenter(subscriptionIcon).dx,
        closeTo(tester.getCenter(profileIcon).dx, 1),
      );
      if (c.size.width > 900) {
        expect(
          tester.getTopLeft(subscriptionLabel).dx,
          closeTo(tester.getTopLeft(profile).dx, 1),
        );
        expect(
          tester.getCenter(subscriptionLabel).dy,
          closeTo(tester.getCenter(subscriptionIcon).dy, 1),
        );
      } else {
        expect(
          tester.getCenter(subscriptionLabel).dx,
          closeTo(tester.getCenter(subscriptionIcon).dx, 1),
        );
        expect(
          tester.getTopLeft(subscriptionLabel).dy,
          greaterThan(tester.getBottomLeft(subscriptionIcon).dy),
        );
      }
      expect(
        tester.widget<Badge>(unread).label,
        isA<Text>().having((text) => text.data, 'data', '2'),
      );
      expect(find.textContaining('从一个明确的视频开始'), findsNothing);
      expect(
        find.descendant(of: welcome, matching: find.byType(Card)),
        findsNothing,
      );
      expect(
        find.descendant(of: welcome, matching: find.byType(Icon)),
        findsNothing,
      );
      expect(tester.widget<FilledButton>(search).child, isA<Text>());
      expect(tester.widget<TextButton>(restore).child, isA<Text>());
      expect(find.text('启用抽屉'), findsOneWidget);
      expect(
        tester.getTopLeft(subscription).dy,
        greaterThan(tester.getBottomLeft(profile).dy),
      );
      final center = tester.getCenter(welcome);
      expect(tester.getCenter(title).dx, closeTo(center.dx, 1));
      expect(tester.getCenter(search).dx, closeTo(center.dx, 1));
      expect(tester.getCenter(restore).dx, closeTo(center.dx, 1));
      expect(
        (tester.getTopLeft(title).dy + tester.getBottomLeft(restore).dy) / 2,
        closeTo(center.dy, 1),
      );
      final semantics = tester.ensureSemantics();
      await tester.pump();
      for (final action in [search, restore, about, subscription]) {
        expect(
          tester
              .getSemantics(action)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
      }
      final subscriptionSemantics = tester.getSemantics(subscription).label;
      expect(subscriptionSemantics, contains('焦点订阅'));
      expect(subscriptionSemantics, contains('2 条未读'));
      semantics.dispose();
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _settle(tester);
      expect(welcome, findsOneWidget);

      await _tap(tester, subscription);
      expect(find.byType(SubscriptionUpdatesPage), findsOneWidget);
      expect(find.byType(AboutPage), findsNothing);
      expect(
        tester
            .widget<SubscriptionUpdatesPage>(
              find.byType(SubscriptionUpdatesPage),
            )
            .service,
        same(subscriptions),
      );
      await subscriptions.markReadBatch({'fixture0', 'fixture1'});
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _settle(tester);
      expect(subscription, findsOneWidget);
      expect(unread, findsNothing);
      expect(subscriptionIcon, findsOneWidget);

      await _tap(tester, search);
      expect(find.byKey(const Key('search-workspace-layout')), findsOneWidget);
      expect(subscription.hitTestable(), findsOneWidget);
      expect(about, findsOneWidget);

      await _tap(tester, profile);
      final profilePage = find.byKey(const Key('profile-workspace-layout'));
      expect(profilePage, findsOneWidget);
      expect(subscription.hitTestable(), findsOneWidget);
      await _tap(tester, subscription);
      expect(find.byType(SubscriptionUpdatesPage), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _settle(tester);
      expect(profilePage, findsOneWidget);
      expect(subscription.hitTestable(), findsOneWidget);

      await subscriptions.setEnabled(false);
      await _settle(tester);
      expect(subscription, findsNothing);
      await subscriptions.setEnabled(true);
      await _settle(tester);
      expect(subscription.hitTestable(), findsOneWidget);
      await _tap(tester, find.descendant(of: rail, matching: find.text('首页')));
      expect(subscription, findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      await _tap(tester, restore);
      expect(prefs.getBool('dashboard.home_drawer_enabled'), isTrue);
      expect(welcome, findsNothing);
      expect(subscription, findsOneWidget);
      expect(about, findsOneWidget);
      expect(find.byKey(const Key('desktop-learning-dock')), findsOneWidget);
      expect(find.byKey(const Key('workspace-open-about')), findsNothing);
      expect(find.text('添加卡片'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      await _tap(tester, about);
      expect(find.byType(AboutPage), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await _settle(tester);
      if (c.allHidden) {
        await _tap(tester, find.text('完成'));
        expect(prefs.getBool('dashboard.home_drawer_enabled'), isFalse);
        expect(welcome, findsOneWidget);
        expect(subscription, findsOneWidget);
        expect(find.byKey(const Key('workspace-open-about')), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
