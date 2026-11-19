import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/focus/home_collection_card.dart';
import 'package:focubili/features/focus/home_favorite_source_dialog.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/features/profile/favorite_folders_page.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Guest extends BilibiliAccountDataService {
  @override
  Future<int?> currentHomeCollectionMid() async => 0;
  @override
  Future<({int? mid, bool transientNetworkError})>
  checkHomeCollectionIdentity() async =>
      (mid: await currentHomeCollectionMid(), transientNetworkError: false);
}

final _local = find.byKey(const Key('home-favorite-source-local'));
final _remote = find.byKey(const Key('home-favorite-source-bilibili'));
final _dialog = find.byType(HomeFavoriteSourceDialog);

Future<void> _open(
  WidgetTester t, {
  required Size size,
  double scale = 1,
  bool dark = false,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: HomeCollectionCard(favorites: true, accountDataService: _Guest()),
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.text('我的收藏'));
  await t.pumpAndSettle();
}

/// 目的页会启动真实的应用内读取；推进路由动画即可验证导航，不依赖平台加载结束。
Future<void> _finishNavigation(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.runAsync(() => Future<void>.delayed(Duration.zero));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.focubili.app/auth'),
      (call) async => call.method == 'readCookies' ? '' : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    await BilibiliAuthService().loadCurrentSession();
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.focubili.app/auth'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  for (final config in [
    (const Size(390, 844), 1.0, false),
    (const Size(320, 480), 2.4, true),
    (const Size(568, 280), 2.0, false),
    (const Size(1440, 900), 1.0, true),
  ]) {
    testWidgets('两个独立的大按钮可达，字号和窗口 ${config.$1}/${config.$2}', (t) async {
      await _open(t, size: config.$1, scale: config.$2, dark: config.$3);
      for (final option in [
        (_local, '本机收藏夹', Icons.folder_outlined),
        (_remote, 'B 站收藏夹', Icons.live_tv_rounded),
      ]) {
        await t.ensureVisible(option.$1);
        await t.pumpAndSettle();
        expect(option.$1.hitTestable(), findsOneWidget);
        final rect = t.getRect(option.$1);
        expect(rect.height, greaterThanOrEqualTo(80));
        expect(
          rect.width,
          greaterThanOrEqualTo(
            config.$1.width <= 400 ? config.$1.width - 68 : 408,
          ),
        );
        expect(rect.width, lessThanOrEqualTo(480));
        expect(
          find.descendant(of: option.$1, matching: find.byIcon(option.$3)),
          findsOneWidget,
        );
        final semantics = t.getSemantics(option.$1);
        expect(semantics, isSemantics(isButton: true, hasTapAction: true));
        expect(semantics.getSemanticsData().label, contains(option.$2));
        expect(t.takeException(), isNull);
      }
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(find.byType(HomeCollectionCard), findsOneWidget);
    });
  }

  testWidgets('点按钮边缘分别进入原本机与 B 站页，返回可重新选择', (t) async {
    await _open(t, size: const Size(390, 844));
    for (final local in [true, false]) {
      if (!local) {
        await t.tap(find.text('我的收藏'));
        await t.pumpAndSettle();
      }
      final button = local ? _local : _remote;
      final rect = t.getRect(button);
      await t.tapAt(Offset(rect.right - 6, rect.center.dy));
      await _finishNavigation(t);
      expect(_dialog, findsNothing);
      expect(
        local
            ? find.byType(AppFavoriteFoldersPage)
            : find.byType(FavoriteFoldersPage),
        findsOneWidget,
      );
      await t.binding.handlePopRoute();
      await _finishNavigation(t);
      expect(find.byType(HomeCollectionCard), findsOneWidget);
    }
  });

  testWidgets('关闭、点遮罩与 Esc 不选择来源；键盘可选中目标', (t) async {
    await _open(t, size: const Size(1100, 720));
    for (final dismiss in [0, 1, 2]) {
      if (dismiss != 0) {
        await t.tap(find.text('我的收藏'));
        await t.pumpAndSettle();
      }
      switch (dismiss) {
        case 0:
          await t.tap(find.byKey(const Key('home-favorite-source-close')));
        case 1:
          await t.tapAt(const Offset(4, 4));
        case 2:
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await t.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(find.byType(HomeCollectionCard), findsOneWidget);
    }
    await t.tap(find.text('我的收藏'));
    await t.pumpAndSettle();
    // 真实 Tab 遍历到 B 站按钮，随后用 Enter 进入；不直接调用回调。
    bool focused = false;
    for (var i = 0; i < 5 && !focused; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      final button = find.descendant(
        of: _remote,
        matching: find.byType(OutlinedButton),
      );
      focused =
          t.getSemantics(button).getSemanticsData().flagsCollection.isFocused ==
          Tristate.isTrue;
    }
    expect(focused, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await _finishNavigation(t);
    expect(find.byType(FavoriteFoldersPage), findsOneWidget);
  });

  testWidgets('连续点首页入口或来源只进一个目的地，返回直接看到首页', (t) async {
    await _open(t, size: const Size(390, 844));
    await t.tap(find.byKey(const Key('home-favorite-source-close')));
    await t.pumpAndSettle();
    final entry = t.getCenter(find.text('我的收藏'));
    await t.tapAt(entry);
    await t.tapAt(entry);
    await t.pumpAndSettle();
    final button = t.getCenter(_local);
    await t.tapAt(button);
    await t.tapAt(button);
    await _finishNavigation(t);
    expect(find.byType(AppFavoriteFoldersPage), findsOneWidget);
    await t.binding.handlePopRoute();
    await _finishNavigation(t);
    expect(_dialog, findsNothing);
    expect(find.byType(HomeCollectionCard), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
