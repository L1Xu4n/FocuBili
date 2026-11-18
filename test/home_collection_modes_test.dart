import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/focus/home_collection_card.dart';
import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/services/following_group_service.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'home_collection_preview_test.dart' as fixture;

const overview = ValueKey('home-mode-overview');
const custom = ValueKey('home-mode-custom');
const back = ValueKey('home-mode-back');

class Pages extends fixture.Api {
  final pages = <int>[];
  final first = Completer<AccountDataPage<FollowedCreator>>();
  @override
  Future<AccountDataPage<FollowedCreator>> loadFollowedCreators({
    int page = 1,
  }) async {
    pages.add(page);
    if (page == 1) return first.future;
    return AccountDataPage.success(
      items: [fixture.creator(33, '第二页 UP', '')],
      page: page,
      hasMore: false,
    );
  }
}

Future<void> open(
  WidgetTester t,
  fixture.Api api, {
  bool favorites = false,
}) async {
  await fixture.mount(t, api, favorites: favorites);
  await fixture.tap(t, find.byTooltip('自定义内容'));
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FollowingGroupService.instance.load(1);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('初次仅两张方式卡，旧自选不自动读取候选，入口保存保留选择', (t) async {
    final api = fixture.Api();
    await fixture.seed(api, [
      fixture.choice('creator', '11', '旧自选', fixture.avatar),
    ]);
    await open(t, api);
    expect(api.calls, 0);
    expect(find.byKey(overview), findsOneWidget);
    expect(find.byKey(custom), findsOneWidget);
    expect(find.text('旧自选'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await fixture.tap(t, find.byKey(overview));
    expect(api.calls, 0);
    await fixture.tap(t, find.text('保存'));
    final saved =
        jsonDecode(
              (await SharedPreferences.getInstance()).getString(
                fixture.key(api, false),
              )!,
            )
            as Map;
    expect(saved['custom'], false);
    expect((saved['items'] as List).single['id'], '11');
  });
  for (final favorites in [false, true]) {
    testWidgets('普通快捷入口不读取本机候选，直到点击下方方式 favorites=$favorites', (t) async {
      final api = fixture.Api();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        fixture.key(api, favorites),
        jsonEncode({
          'custom': false,
          'items': [
            fixture.choice(favorites ? 'local' : 'creator', '11', '以前添加过'),
          ],
        }),
      );
      var localReads = 0;
      Future<SharedPreferences> read() async {
        localReads++;
        return prefs;
      }

      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeCollectionCard(
              favorites: favorites,
              accountDataService: api,
              showCustomization: true,
              localFavorites: AppFavoritesService(preferencesLoader: read),
              localGroups: FollowingGroupService(preferencesLoader: read),
            ),
          ),
        ),
      );
      await fixture.settle(t);
      AppFavoritesService.contentsRevision.value++;
      await fixture.settle(t);
      expect(localReads, 0);
      await fixture.tap(t, find.byTooltip('自定义内容'));
      await fixture.tap(t, find.byKey(overview));
      expect(localReads, 0);
      await fixture.tap(t, find.byKey(custom));
      expect(localReads, greaterThan(0));
    });
  }
  testWidgets('方式与选中状态在同一个可操作的读屏节点', (t) async {
    final semantics = t.ensureSemantics();
    try {
      final api = fixture.Api();
      await fixture.seed(api, []);
      await open(t, api);
      void check(bool customized) {
        for (final entry in [(overview, !customized), (custom, customized)]) {
          expect(
            t.getSemantics(find.byKey(entry.$1)),
            isSemantics(
              isButton: true,
              hasSelectedState: true,
              isSelected: entry.$2,
              hasTapAction: true,
            ),
          );
        }
      }

      check(true);
      await fixture.tap(t, find.byKey(overview));
      check(false);
    } finally {
      semantics.dispose();
    }
  });
  testWidgets('只有下方取候选，返回方式及切换不丢选择或搜索草稿，取消不写', (t) async {
    final api = fixture.Api();
    await fixture.seed(api, [
      fixture.choice('creator', '11', '旧自选', fixture.avatar),
    ]);
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(fixture.key(api, false));
    await open(t, api);
    await fixture.tap(t, find.byKey(custom));
    expect(api.calls, 1);
    await fixture.tap(t, find.byKey(const ValueKey('add-creator:22')));
    await t.enterText(find.byType(TextField), '课程');
    await fixture.settle(t);
    await fixture.tap(t, find.byKey(back));
    expect(find.byType(TextField), findsNothing);
    expect(api.calls, 1);
    await fixture.tap(t, find.byKey(overview));
    expect(api.calls, 1);
    await fixture.tap(t, find.byKey(custom));
    expect(api.calls, 1);
    expect(find.byTooltip('移除'), findsNWidgets(2));
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '课程');
    await fixture.tap(t, find.byKey(back));
    await t.pageBack();
    await fixture.settle(t);
    expect(prefs.getString(fixture.key(api, false)), before);
  });
  testWidgets('慢第一页离开后不翻下一页、不显示迟到候选，重新进入才继续', (t) async {
    final api = Pages();
    await fixture.seed(api, []);
    await open(t, api);
    expect(api.pages, isEmpty);
    await fixture.tap(t, find.byKey(custom));
    expect(api.pages, [1]);
    await fixture.tap(t, find.byKey(back));
    api.first.complete(
      AccountDataPage.success(
        items: [fixture.creator(22, '第一页 UP', '')],
        page: 1,
        hasMore: true,
      ),
    );
    await fixture.settle(t);
    expect(api.pages, [1]);
    expect(find.text('第一页 UP'), findsNothing);
    await fixture.tap(t, find.byKey(custom));
    expect(api.pages, [1, 2]);
    expect(find.text('第二页 UP'), findsOneWidget);
  });
  testWidgets('无通知切号的迟到候选不显示、旧编辑不允许保存', (t) async {
    final api = Pages();
    await fixture.seed(api, []);
    await open(t, api);
    await fixture.tap(t, find.byKey(custom));
    api.mid = 202;
    api.first.complete(
      AccountDataPage.success(
        items: [fixture.creator(22, '旧账号候选', '')],
        page: 1,
        hasMore: true,
      ),
    );
    await fixture.settle(t);
    expect(api.pages, [1]);
    expect(find.text('旧账号候选'), findsNothing);
    expect(find.text('账号已变化，请返回后重新打开'), findsOneWidget);
    expect(find.text('保存'), findsNothing);
  });
  testWidgets('失败可返回方式不发请求，主动重试才重新加载', (t) async {
    final api = Pages();
    await fixture.seed(api, []);
    await open(t, api);
    await fixture.tap(t, find.byKey(custom));
    api.first.complete(AccountDataPage.networkError());
    await fixture.settle(t);
    expect(find.byKey(const ValueKey('home-remote-retry')), findsOneWidget);
    await fixture.tap(t, find.byKey(back));
    await fixture.tap(t, find.byKey(overview));
    expect(api.pages, [1]);
    await fixture.tap(t, find.byKey(custom));
    expect(api.pages, [1, 1]);
  });
  testWidgets('返回显示方式后预览身份迟到不会突然跳进主页', (t) async {
    final api = fixture.Api();
    await fixture.seed(api, [
      fixture.choice('creator', '11', '旧 UP', fixture.avatar),
    ]);
    await open(t, api);
    await fixture.tap(t, find.byKey(custom));
    api.identity = Completer();
    await fixture.tap(t, find.byKey(const ValueKey('preview-creator:11')));
    await fixture.tap(t, find.byKey(back));
    api.identity!.complete(101);
    await fixture.settle(t);
    expect(find.byType(UserProfilePage), findsNothing);
    expect(find.byKey(custom), findsOneWidget);
  });
  testWidgets('桌面方式区域限宽居中', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final api = fixture.Api();
    await fixture.seed(api, []);
    await open(t, api);
    expect(t.getSize(find.byKey(custom)).width, lessThanOrEqualTo(680));
    expect(t.getCenter(find.byKey(custom)).dx, closeTo(640, 1));
    await fixture.tap(t, find.byKey(custom));
    final search = find.byType(TextField);
    expect(t.getRect(search).width, lessThanOrEqualTo(680));
    expect(t.getCenter(search).dx, closeTo(640, 1));
  });
  for (final hold in [false, true]) {
    testWidgets('明确把手第三项拖到第一项并保存 hold=$hold', (t) async {
      final api = fixture.Api();
      await fixture.seed(api, [
        for (final id in ['11', '22', '33'])
          fixture.choice('creator', id, 'UP $id', fixture.avatar),
      ]);
      await open(t, api);
      await fixture.tap(t, find.byKey(custom));
      final handle = find.byKey(const ValueKey('reorder-creator:33'));
      final start = hold
          ? t.getTopLeft(handle) + const Offset(4, 4)
          : t.getCenter(handle);
      expect(t.getSize(handle), const Size(48, 48));
      final target =
          t.getTopLeft(find.byKey(const ValueKey('creator:11'))).dy + 2;
      final gesture = await t.startGesture(start);
      if (hold) await t.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(0, -20));
      await t.pump();
      for (var step = 1; step <= 8; step++) {
        await gesture.moveTo(
          Offset(start.dx, start.dy + (target - start.dy) * step / 8),
        );
        await t.pump(const Duration(milliseconds: 80));
      }
      await t.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await fixture.settle(t);
      expect(
        t.getTopLeft(find.byKey(const ValueKey('creator:33'))).dy,
        lessThan(t.getTopLeft(find.byKey(const ValueKey('creator:11'))).dy),
      );
      await fixture.tap(t, find.text('保存'));
      final saved =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  fixture.key(api, false),
                )!,
              )
              as Map;
      expect((saved['items'] as List).first['id'], '33');
    });
  }
  for (final favorites in [false, true]) {
    testWidgets('大字深色两步方式可键盘进入且不溢出 favorites=$favorites', (t) async {
      t.view.physicalSize = const Size(320, 740);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = fixture.Api();
      await fixture.seed(api, [], favorites: favorites);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: HomeCollectionCard(
                favorites: favorites,
                showCustomization: true,
                accountDataService: api,
              ),
            ),
          ),
        ),
      );
      await fixture.settle(t);
      await fixture.tap(t, find.byTooltip('自定义内容'));
      expect(find.byKey(custom), findsOneWidget);
      expect(t.takeException(), isNull);
      final button = find.byKey(custom);
      await t.ensureVisible(button);
      await t.pump();
      var focused = false;
      for (var i = 0; i < 20 && !focused; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
          if (e.widget.key == custom) {
            focused = true;
            return false;
          }
          return true;
        });
      }
      expect(focused, true);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await fixture.settle(t);
      expect(find.byKey(back), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
