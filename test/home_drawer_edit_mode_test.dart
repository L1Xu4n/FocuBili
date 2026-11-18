import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/widgets/editable_card_board.dart';
import 'package:focubili/features/home/home_page.dart';
import 'package:focubili/features/focus/focus_timer_scope.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/services/dashboard_layout_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/following_group_service.dart';
import 'package:focubili/services/subscription_onboarding_service.dart';

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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final focus = FocusTimerController(tickInterval: const Duration(days: 1));
  await focus.initialize();
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: size.width > 900 ? ThemeData.dark() : ThemeData.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(scale),
        ),
        child: FocusTimerScope(controller: focus, child: child!),
      ),
      home: Scaffold(
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
    expect(find.text('自选内容'), findsOneWidget);
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
    await tester.tap(find.text('入口'));
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
    await tester.tap(find.text('自选内容'));
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
}
