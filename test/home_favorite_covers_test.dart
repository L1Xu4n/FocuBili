import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/common/app_network_image.dart';
import 'package:focubili/features/focus/home_collection_card.dart';
import 'package:focubili/features/focus/home_favorite_cover.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/features/profile/favorite_videos_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/image_resource_cache.dart';

class CoverAccount extends BilibiliAccountDataService {
  int? mid = 101;
  int calls = 0;
  final videoCalls = <int>[];
  Future<AccountDataPage<FavoriteVideo>> Function(int)? videos;
  @override
  Future<AccountDataPage<FavoriteVideo>> loadFavoriteVideos(
    int mediaId, {
    int page = 1,
  }) {
    expect(page, 1);
    videoCalls.add(mediaId);
    return videos?.call(mediaId) ??
        Future.value(AccountDataPage<FavoriteVideo>.networkError());
  }

  Future<AccountDataPage<FavoriteFolder>> Function()? next;
  @override
  Future<int?> currentHomeCollectionMid() async => mid;
  @override
  Future<({int? mid, bool transientNetworkError})>
  checkHomeCollectionIdentity() async =>
      (mid: await currentHomeCollectionMid(), transientNetworkError: false);

  @override
  Future<int?> currentAccountMid() async => mid;
  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() {
    calls++;
    return next?.call() ??
        Future.value(
          AccountDataPage.success(
            items: [folder('https://fixture.invalid/remote')],
            page: 1,
            hasMore: false,
          ),
        );
  }
}

FavoriteFolder folder(String cover, {int id = 7, bool available = true}) =>
    FavoriteFolder(
      mediaId: id,
      title: '远端课程',
      coverUrl: cover,
      mediaCount: 2,
      isAvailable: available,
    );
Map<String, String> choice(String kind, String id, String label) => {
  'kind': kind,
  'id': id,
  'label': label,
};
Future<String> seed(int mid, List<Map<String, String>> choices) async {
  final raw = jsonEncode({'custom': true, 'items': choices});
  await (await SharedPreferences.getInstance()).setString(
    'home_collection.v1.favorites.$mid',
    raw,
  );
  return raw;
}

Widget host(
  BilibiliAccountDataService api, {
  double scale = 1,
  bool dark = false,
  ImageResourceCache? imageCache,
}) => MaterialApp(
  theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: HomeCollectionCard(
        showCustomization: true,
        favorites: true,
        accountDataService: api,
        imageCache: imageCache,
      ),
    ),
  ),
);

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 40)),
  );
  await tester.pumpAndSettle();
}

String cover(WidgetTester tester, String kind, String id) => tester
    .widget<HomeFavoriteCover>(find.byKey(ValueKey('home-cover-$kind:$id')))
    .coverUrl;
AppFavoriteItem item(String id, String bv, String cover, int minute) =>
    AppFavoriteItem(
      folderId: id,
      bvid: bv,
      title: '视频',
      coverUrl: cover,
      ownerName: '课程',
      durationText: '12:00',
      addedAt: DateTime(2026, 1, 1, 0, minute),
    );
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('旧配置不含URL也显示分来源封面，重建不重复请求', (tester) async {
    final api = CoverAccount();
    final service = AppFavoritesService();
    final local = (await tester.runAsync(() => service.createFolder('本机课程')))!;
    await tester.runAsync(
      () => service.addItem(
        item(local.id, 'BV1', 'https://fixture.invalid/local', 1),
      ),
    );
    final raw = await seed(101, [
      choice('local', local.id, '旧名称'),
      choice('remote', '7', '远端课程'),
    ]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    expect(cover(tester, 'local', local.id), 'https://fixture.invalid/local');
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/remote');
    expect(find.text('本机课程'), findsOneWidget);
    expect(api.calls, 1);
    await tester.pumpWidget(host(api, scale: 2, dark: true));
    await settle(tester);
    expect(api.calls, 1);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'home_collection.v1.favorites.101',
      ),
      raw,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('保留首页随本机新增、移除、清空和改名刷新封面', (tester) async {
    final api = CoverAccount()..mid = 0;
    final service = AppFavoritesService();
    final local = (await tester.runAsync(() => service.createFolder('课程')))!;
    await tester.runAsync(
      () => service.addItem(
        item(local.id, 'BV1', 'https://fixture.invalid/old', 1),
      ),
    );
    await seed(0, [choice('local', local.id, '课程')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    expect(cover(tester, 'local', local.id), 'https://fixture.invalid/old');
    await tester.runAsync(
      () => AppFavoritesService().addItem(
        item(local.id, 'BV2', 'https://fixture.invalid/new', 2),
      ),
    );
    await settle(tester);
    expect(cover(tester, 'local', local.id), 'https://fixture.invalid/new');
    await tester.runAsync(() => service.addItem(item(local.id, 'BV3', '', 3)));
    await settle(tester);
    expect(cover(tester, 'local', local.id), 'https://fixture.invalid/new');
    await tester.runAsync(() => service.removeItem(local.id, 'BV2'));
    await settle(tester);
    expect(cover(tester, 'local', local.id), 'https://fixture.invalid/old');
    await tester.runAsync(() => service.removeItem(local.id, 'BV1'));
    await settle(tester);
    expect(cover(tester, 'local', local.id), '');
    await tester.runAsync(() => service.renameFolder(local.id, '新名称'));
    await settle(tester);
    expect(find.text('新名称'), findsOneWidget);
    expect(api.calls, 0);
  });
  testWidgets('切号立即隐藏旧封面并拒绝旧账号迟到结果', (tester) async {
    final api = CoverAccount();
    final first = Completer<AccountDataPage<FavoriteFolder>>();
    final second = Completer<AccountDataPage<FavoriteFolder>>();
    api.next = () => first.future;
    await seed(101, [choice('remote', '7', '旧账号课程')]);
    await seed(202, [choice('remote', '7', '新账号课程')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    api.mid = 202;
    api.next = () => second.future;
    CacheLifecycle.accountChanged();
    await settle(tester);
    expect(find.text('旧账号课程'), findsNothing);
    expect(cover(tester, 'remote', '7'), '');
    second.complete(
      AccountDataPage.success(
        items: [folder('https://fixture.invalid/new-account')],
        page: 1,
        hasMore: false,
      ),
    );
    await settle(tester);
    first.complete(
      AccountDataPage.success(
        items: [folder('https://fixture.invalid/old-account')],
        page: 1,
        hasMore: false,
      ),
    );
    await settle(tester);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/new-account');
    api.mid = null;
    CacheLifecycle.accountChanged();
    await settle(tester);
    expect(find.byType(HomeFavoriteCover), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });
  testWidgets('空封面、失效夹与失败列表使用占位，不覆盖已有配置', (tester) async {
    for (final page in [
      AccountDataPage<FavoriteFolder>.networkError(),
      AccountDataPage<FavoriteFolder>.success(
        items: [folder('https://fixture.invalid/stale', available: false)],
        page: 1,
        hasMore: false,
      ),
      AccountDataPage<FavoriteFolder>.success(
        items: [folder('')],
        page: 1,
        hasMore: false,
      ),
    ]) {
      final api = CoverAccount()..next = () => Future.value(page);
      final raw = await seed(101, [choice('remote', '7', '已选课程')]);
      await tester.pumpWidget(host(api));
      await settle(tester);
      expect(cover(tester, 'remote', '7'), '');
      expect(find.text('已选课程'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'home_collection.v1.favorites.101',
        ),
        raw,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets('损坏本机内容不显示旧封面且不写回源数据', (tester) async {
    final api = CoverAccount()..mid = 0;
    final service = AppFavoritesService();
    final local = (await tester.runAsync(() => service.createFolder('课程')))!;
    await tester.runAsync(
      () => service.addItem(
        item(local.id, 'BV1', 'https://fixture.invalid/old', 1),
      ),
    );
    await seed(0, [choice('local', local.id, '课程')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_favorites.items_v1.${local.id}', 'broken');
    AppFavoritesService.contentsRevision.value++;
    await settle(tester);
    expect(cover(tester, 'local', local.id), '');
    expect(prefs.getString('app_favorites.items_v1.${local.id}'), 'broken');
  });
  testWidgets('仅已选有内容缺图夹补查第一页，单夹失败隔离且重建不重查', (tester) async {
    final api = CoverAccount();
    api.next = () async => AccountDataPage.success(
      items: [folder('', id: 7), folder('', id: 8), folder('', id: 9)],
      page: 1,
      hasMore: false,
    );
    api.videos = (id) async => id == 8
        ? AccountDataPage.networkError()
        : AccountDataPage.success(
            items: [
              FavoriteVideo(
                bvid: 'BV1',
                title: '课程',
                coverUrl: 'https://fixture.invalid/fallback',
                ownerName: 'UP',
                duration: Duration.zero,
                partCount: 1,
                favoritedAt: null,
                playCount: 0,
                danmakuCount: 0,
                isAvailable: true,
              ),
            ],
            page: 1,
            hasMore: true,
          );
    await seed(101, [
      choice('remote', '7', '默认收藏夹'),
      choice('remote', '8', '失败夹'),
    ]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    expect(api.videoCalls, [7, 8]);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/fallback');
    expect(cover(tester, 'remote', '8'), '');
    await tester.pumpWidget(host(api, scale: 2));
    await settle(tester);
    expect(api.videoCalls, [7, 8]);
    expect(api.calls, 1);
  });
  testWidgets('首视频兜底迟到后不会泄露旧账号封面', (tester) async {
    final api = CoverAccount();
    final pending = Completer<AccountDataPage<FavoriteVideo>>();
    api.next = () async =>
        AccountDataPage.success(items: [folder('')], page: 1, hasMore: false);
    api.videos = (_) => pending.future;
    await seed(101, [choice('remote', '7', '旧账号')]);
    await seed(202, [choice('remote', '7', '新账号')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    api.mid = 202;
    api.next = () async => AccountDataPage.success(
      items: [folder('https://fixture.invalid/new')],
      page: 1,
      hasMore: false,
    );
    CacheLifecycle.accountChanged();
    await settle(tester);
    pending.complete(
      AccountDataPage.success(
        items: [
          FavoriteVideo(
            bvid: 'BV1',
            title: '旧课程',
            coverUrl: 'https://fixture.invalid/old',
            ownerName: 'UP',
            duration: Duration.zero,
            partCount: 1,
            favoritedAt: null,
            playCount: 0,
            danmakuCount: 0,
            isAvailable: true,
          ),
        ],
        page: 1,
        hasMore: false,
      ),
    );
    await settle(tester);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/new');
    expect(find.text('旧账号'), findsNothing);
  });
  testWidgets('返回时主动识别不同MID，不借用旧账号在途列表', (tester) async {
    final api = CoverAccount();
    final first = Completer<AccountDataPage<FavoriteFolder>>();
    final second = Completer<AccountDataPage<FavoriteFolder>>();
    final service = AppFavoritesService();
    final local = (await tester.runAsync(() => service.createFolder('本机课程')))!;
    api.next = () => first.future;
    await seed(101, [
      choice('local', local.id, '本机课程'),
      choice('remote', '7', '旧账号'),
    ]);
    await seed(202, [choice('remote', '7', '新账号')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('本机课程'));
      await Future<void>.delayed(Duration.zero);
    });
    await settle(tester);
    api.mid = 202;
    api.next = () => second.future;
    await tester.pageBack();
    await settle(tester);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await tester.pageBack();
    }
    await settle(tester);
    expect(find.text('新账号'), findsOneWidget);
    expect(api.calls, 2);
    first.complete(
      AccountDataPage.success(
        items: [folder('https://fixture.invalid/old')],
        page: 1,
        hasMore: false,
      ),
    );
    await settle(tester);
    expect(cover(tester, 'remote', '7'), '');
    second.complete(
      AccountDataPage.success(
        items: [folder('https://fixture.invalid/new')],
        page: 1,
        hasMore: false,
      ),
    );
    await settle(tester);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/new');
  });
  testWidgets('返回同账号主页后刷新新的远端封面而非永久缓存', (tester) async {
    final api = CoverAccount();
    final service = AppFavoritesService();
    final local = (await tester.runAsync(() => service.createFolder('本机课程')))!;
    await seed(101, [
      choice('local', local.id, '本机课程'),
      choice('remote', '7', '远端课程'),
    ]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    expect(api.calls, 1);
    await tester.runAsync(() async {
      await tester.tap(find.text('本机课程'));
      await Future<void>.delayed(Duration.zero);
    });
    await settle(tester);
    api.next = () async => AccountDataPage.success(
      items: [folder('https://fixture.invalid/updated')],
      page: 1,
      hasMore: false,
    );
    await tester.pageBack();
    await settle(tester);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await tester.pageBack();
    }
    await settle(tester);
    expect(api.calls, 2);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/updated');
  });
  testWidgets('返回远端收藏夹时保留已显示的封面，实际变化才替换', (tester) async {
    final api = CoverAccount();
    api.next = () async =>
        AccountDataPage.success(items: [folder('')], page: 1, hasMore: false);
    AccountDataPage<FavoriteVideo> videos(String image) =>
        AccountDataPage.success(
          items: [
            FavoriteVideo(
              bvid: 'BV1',
              title: '课程',
              coverUrl: image,
              ownerName: 'UP',
              duration: Duration.zero,
              partCount: 1,
              favoritedAt: null,
              playCount: 0,
              danmakuCount: 0,
              isAvailable: true,
            ),
          ],
          page: 1,
          hasMore: false,
        );
    const old = 'https://fixture.invalid/before';
    const updated = 'https://fixture.invalid/after';
    api.videos = (_) async => videos(old);
    await seed(101, [choice('remote', '7', '远端课程')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    final image = find.descendant(
      of: find.byKey(const ValueKey('home-cover-remote:7')),
      matching: find.byType(AppNetworkImage),
    );
    final imageState = tester.state(image);
    expect(cover(tester, 'remote', '7'), old);

    for (final next in [old, null, updated]) {
      await tester.tap(find.text('远端课程'));
      await settle(tester);
      expect(find.byType(FavoriteVideosPage), findsOneWidget);
      final pending = Completer<AccountDataPage<FavoriteVideo>>();
      api.videos = (_) => pending.future;
      await tester.pageBack();
      await settle(tester);

      // The folder list (with empty cover metadata) has completed, but the
      // new first video has not. Never unmount and recreate the old image.
      expect(cover(tester, 'remote', '7'), old);
      expect(tester.state(image), same(imageState));
      pending.complete(
        next == null ? AccountDataPage.networkError() : videos(next),
      );
      await settle(tester);
      expect(cover(tester, 'remote', '7'), next ?? old);
      expect(tester.state(image), same(imageState));
    }

    await tester.tap(find.text('远端课程'));
    await settle(tester);
    api.next = () async => AccountDataPage.networkError();
    await tester.pageBack();
    await settle(tester);
    expect(cover(tester, 'remote', '7'), updated);
    expect(tester.state(image), same(imageState));

    await tester.tap(find.text('远端课程'));
    await settle(tester);
    api.next = () async =>
        AccountDataPage.success(items: [], page: 1, hasMore: false);
    await tester.pageBack();
    await settle(tester);
    expect(cover(tester, 'remote', '7'), '');
    expect(image, findsNothing);
    expect(api.calls, 6);
    expect(api.videoCalls, [7, 7, 7, 7]);
  });
  testWidgets('浏览本机收藏夹再返回保留封面，之后的收藏变更仍更新', (tester) async {
    final api = CoverAccount()..mid = 0;
    final service = AppFavoritesService();
    final local = (await tester.runAsync(() => service.createFolder('本机课程')))!;
    const old = 'https://fixture.invalid/before-local';
    const updated = 'https://fixture.invalid/after-local';
    await tester.runAsync(() => service.addItem(item(local.id, 'BV1', old, 1)));
    await seed(0, [choice('local', local.id, '本机课程')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    final image = find.descendant(
      of: find.byKey(ValueKey('home-cover-local:${local.id}')),
      matching: find.byType(AppNetworkImage),
    );
    final imageState = tester.state(image);
    await tester.runAsync(() async {
      await tester.tap(find.text('本机课程'));
      await Future<void>.delayed(Duration.zero);
    });
    await settle(tester);
    expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    expect(cover(tester, 'local', local.id), old);
    expect(tester.state(image), same(imageState));

    await tester.runAsync(
      () => service.addItem(item(local.id, 'BV2', updated, 2)),
    );
    await settle(tester);
    expect(cover(tester, 'local', local.id), updated);
    expect(api.calls, 0);
  });
  testWidgets('缺图批次最多三个请求，未选择的夹不探测', (tester) async {
    final api = CoverAccount();
    final waits = <int, Completer<AccountDataPage<FavoriteVideo>>>{};
    api.next = () async => AccountDataPage.success(
      items: [for (var id = 1; id <= 8; id++) folder('', id: id)],
      page: 1,
      hasMore: false,
    );
    api.videos = (id) => (waits[id] = Completer()).future;
    await seed(101, [
      for (var id = 1; id <= 5; id++) choice('remote', '$id', '课程$id'),
    ]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    expect(api.videoCalls, [1, 2, 3]);
    for (final id in [1, 2, 3]) {
      waits[id]!.complete(AccountDataPage.networkError());
    }
    await settle(tester);
    expect(api.videoCalls, [1, 2, 3, 4, 5]);
    for (final id in [4, 5]) {
      waits[id]!.complete(AccountDataPage.networkError());
    }
    await settle(tester);
    expect(api.videoCalls, [1, 2, 3, 4, 5]);
  });
  test('只读导出不触发首页封面重读', () async {
    final service = AppFavoritesService();
    await service.createFolder('课程');
    final before = AppFavoritesService.contentsRevision.value;
    await service.exportBackup();
    expect(AppFavoritesService.contentsRevision.value, before);
  });
  testWidgets('打开自定义后取消不清掉已显示的默认收藏夹补图', (tester) async {
    final api = CoverAccount();
    api.next = () async =>
        AccountDataPage.success(items: [folder('')], page: 1, hasMore: false);
    api.videos = (_) async => AccountDataPage.success(
      items: [
        FavoriteVideo(
          bvid: 'BV1',
          title: '课程',
          coverUrl: 'https://fixture.invalid/fallback',
          ownerName: 'UP',
          duration: Duration.zero,
          partCount: 1,
          favoritedAt: null,
          playCount: 0,
          danmakuCount: 0,
          isAvailable: true,
        ),
      ],
      page: 1,
      hasMore: false,
    );
    await seed(101, [choice('remote', '7', '默认收藏夹')]);
    await tester.pumpWidget(host(api));
    await settle(tester);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/fallback');
    await tester.tap(find.byTooltip('自定义内容'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('home-mode-custom')));
    await settle(tester);
    await tester.pageBack();
    await settle(tester);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await tester.pageBack();
    }
    await settle(tester);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/fallback');
    expect(api.videoCalls, [7]);
  });
  testWidgets('通过实际编辑器新选并保存远端夹，首页直接出现封面', (tester) async {
    final api = CoverAccount();
    await seed(101, []);
    await tester.pumpWidget(host(api));
    await settle(tester);
    expect(api.calls, 0);
    await tester.tap(find.byTooltip('自定义内容'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('home-mode-custom')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('add-remote:7')));
    await settle(tester);
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(cover(tester, 'remote', '7'), 'https://fixture.invalid/remote');
    expect(api.calls, 1);
    final saved = (await SharedPreferences.getInstance()).getString(
      'home_collection.v1.favorites.101',
    )!;
    expect(saved, contains('远端课程'));
    expect(saved, isNot(contains('https://')));
  });
}
