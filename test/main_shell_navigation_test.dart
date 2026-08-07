import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/focus_timer_scope.dart';
import 'package:focubili/features/shell/main_shell.dart';

/// 在固定手机尺寸中创建主框架，并注入已经初始化的专注控制器。
Future<void> _pumpMainShell(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final FocusTimerController focusController = FocusTimerController(
    tickInterval: const Duration(days: 1),
  );
  addTearDown(focusController.dispose);
  await focusController.initialize();
  await tester.pumpWidget(
    MaterialApp(
      onGenerateRoute: AppRouter.onGenerateRoute,
      home: FocusTimerScope(
        controller: focusController,
        child: const MainShell(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 注册主框架的系统返回和隐藏输入焦点回归测试。
void main() {
  /// 每项测试清空本机偏好，避免学习清单或搜索历史影响页面状态。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证搜索页和“我的”页先返回首页，只有首页把返回继续交给系统。
  testWidgets('一级子页系统返回首页且首页允许退出', (WidgetTester tester) async {
    await _pumpMainShell(tester);

    await tester.tap(find.byKey(const Key('home-start-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-back-button')), findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-start-search')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-profile-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-back-button')), findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-start-search')), findsOneWidget);

    expect(await tester.binding.handlePopRoute(), isFalse);
  });

  /// 验证离开搜索页会断开输入焦点，设置页返回后隐藏搜索框不会接收文字。
  testWidgets('设置页返回不会恢复隐藏搜索框焦点', (WidgetTester tester) async {
    await _pumpMainShell(tester);

    await tester.tap(find.byKey(const Key('home-start-search')));
    await tester.pumpAndSettle();
    final Finder visibleSearchInput = find.byKey(
      const Key('search-input-field'),
    );
    await tester.tap(visibleSearchInput);
    await tester.enterText(visibleSearchInput, '原有搜索');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.byKey(const Key('search-back-button')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.tap(find.byKey(const Key('home-profile-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('个性化设置'), findsOneWidget);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    final TextField hiddenSearchInput = tester.widget<TextField>(
      find.byKey(const Key('search-input-field'), skipOffstage: false),
    );
    expect(hiddenSearchInput.focusNode?.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.tap(find.byKey(const Key('profile-back-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-start-search')));
    await tester.pumpAndSettle();
    final TextField restoredSearchInput = tester.widget<TextField>(
      find.byKey(const Key('search-input-field')),
    );
    expect(restoredSearchInput.controller?.text, '原有搜索');
  });
}
