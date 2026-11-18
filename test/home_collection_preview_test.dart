import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/focus/home_collection_card.dart';
import 'package:focubili/features/focus/home_favorite_cover.dart';
import 'package:focubili/features/common/app_network_image.dart';
import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/features/profile/favorite_videos_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/following_group.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/following_group_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';

const avatar = 'https://fixture.invalid/creator.png';

class Api extends BilibiliAccountDataService {
  int mid = 101;
  int calls = 0;
  int identityReads = 0;
  Completer<int?>? identity;
  String url = avatar;
  Completer<AccountDataPage<FollowedCreator>>? pending;
  @override
  Future<int?> currentAccountMid() async {
    identityReads++;
    return identity?.future ?? (mid == 0 ? null : mid);
  }

  @override
  Future<int?> currentHomeCollectionMid() async => mid;
  @override
  Future<AccountDataPage<FollowedCreator>> loadFollowedCreators({
    int page = 1,
  }) async {
    calls++;
    return pending?.future ??
        AccountDataPage.success(
          items: [creator(22, '候选 UP', url)],
          page: 1,
          hasMore: false,
        );
  }

  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() async =>
      AccountDataPage.success(
        items: const [
          FavoriteFolder(
            mediaId: 7,
            title: '远端夹',
            coverUrl: '',
            mediaCount: 0,
            isAvailable: true,
          ),
        ],
        page: 1,
        hasMore: false,
      );
}

FollowedCreator creator(int mid, String name, String image) => FollowedCreator(
  mid: mid,
  name: name,
  avatarUrl: image,
  sign: '',
  officialDescription: '',
  followedAt: null,
);
String key(Api api, bool favorites) =>
    'home_collection.v1.${favorites ? 'favorites' : 'followings'}.${api.mid}';
Map<String, String> choice(
  String kind,
  String id,
  String label, [
  String? image,
]) => {'kind': kind, 'id': id, 'label': label, 'avatar': ?image};
Future<void> seed(
  Api api,
  List<Map<String, String>> items, {
  bool favorites = false,
}) async => (await SharedPreferences.getInstance()).setString(
  key(api, favorites),
  jsonEncode({'custom': true, 'items': items}),
);
Future<void> settle(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await t.pump(const Duration(milliseconds: 500));
  await t.pump(const Duration(milliseconds: 500));
}

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump(const Duration(milliseconds: 500));
  await t.tap(f);
  await settle(t);
}

Future<void> mount(WidgetTester t, Api api, {bool favorites = false}) async {
  await t.pumpWidget(
    MaterialApp(
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
  await settle(t);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FollowingGroupService.instance.load(1);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  testWidgets('候选名称和头像预览真实 UP，只有加号添加，返回保留草稿取消不写', (t) async {
    final api = Api();
    await seed(api, [choice('creator', '11', '已选 UP', avatar)]);
    await mount(t, api);
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(key(api, false));
    expect(find.byType(AppNetworkImage), findsOneWidget);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    await tap(t, find.byKey(const ValueKey('preview-creator:22')));
    expect(t.widget<UserProfilePage>(find.byType(UserProfilePage)).mid, 22);
    await t.pageBack();
    await settle(t);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await t.pageBack();
      await settle(t);
    }
    expect(find.byKey(const ValueKey('add-creator:22')), findsOneWidget);
    await tap(t, find.byKey(const ValueKey('add-creator:22')));
    expect(find.byKey(const ValueKey('candidate-creator:22')), findsNothing);
    await tap(t, find.byKey(const ValueKey('preview-creator:11')));
    expect(t.widget<UserProfilePage>(find.byType(UserProfilePage)).mid, 11);
    await t.pageBack();
    await settle(t);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await t.pageBack();
      await settle(t);
    }
    expect(find.byTooltip('移除'), findsNWidgets(2));
    await t.pageBack();
    await settle(t);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await t.pageBack();
      await settle(t);
    }
    expect(prefs.getString(key(api, false)), before);
    expect(api.calls, 1);
  });
  testWidgets('保存公开头像、重建显示；旧快照从同账号分组补图且不扫远端', (t) async {
    final api = Api();
    await seed(api, []);
    await mount(t, api);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    await tap(t, find.byKey(const ValueKey('add-creator:22')));
    await tap(t, find.text('保存'));
    expect(
      (await SharedPreferences.getInstance()).getString(key(api, false)),
      contains(avatar),
    );
    await t.pumpWidget(const SizedBox());
    await mount(t, api);
    expect(
      t.widget<AppNetworkImage>(find.byType(AppNetworkImage)).imageUrl,
      avatar,
    );
    expect(api.calls, 1);
    await t.pumpWidget(const SizedBox());
    await seed(api, [choice('creator', '11', '旧快照')]);
    await t.runAsync(
      () => FollowingGroupService.instance.save(101, [
        FollowingGroup(
          id: 'g',
          name: '分组',
          members: [creator(11, '旧快照', avatar)],
        ),
      ]),
    );
    await mount(t, api);
    expect(
      t.widget<AppNetworkImage>(find.byType(AppNetworkImage)).imageUrl,
      avatar,
    );
    expect(api.calls, 1);
    api.mid = 202;
    CacheLifecycle.accountChanged();
    await settle(t);
    expect(find.byType(AppNetworkImage), findsNothing);
    expect(find.text('旧快照'), findsNothing);
  });
  testWidgets('远端迟到与身份改变不能展示旧候选或导航', (t) async {
    final api = Api()..pending = Completer();
    await seed(api, []);
    await mount(t, api);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    api.mid = 202;
    CacheLifecycle.accountChanged();
    api.pending!.complete(
      AccountDataPage.success(
        items: [creator(22, '旧账号 UP', avatar)],
        page: 1,
        hasMore: false,
      ),
    );
    await settle(t);
    expect(find.text('账号已变化，请返回后重新打开'), findsOneWidget);
    expect(find.text('旧账号 UP'), findsNothing);
    expect(find.text('保存'), findsNothing);
  });
  testWidgets('收藏候选和已选预览真实本机/远端目的页，加号独立且来源无图也可见', (t) async {
    final api = Api()..mid = 0;
    final folder = (await t.runAsync(
      () => AppFavoritesService().createFolder('本机夹'),
    ))!;
    await seed(api, [], favorites: true);
    await mount(t, api, favorites: true);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    await tap(t, find.byKey(ValueKey('preview-local:${folder.id}')));
    expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
    await t.pageBack();
    await settle(t);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await t.pageBack();
      await settle(t);
    }
    expect(find.byKey(ValueKey('add-local:${folder.id}')), findsOneWidget);
    await tap(t, find.byKey(ValueKey('add-local:${folder.id}')));
    await tap(t, find.text('保存'));
    expect(find.byIcon(Icons.bookmark_outline), findsOneWidget);

    await t.pumpWidget(const SizedBox());
    api.mid = 101;
    await seed(api, [], favorites: true);
    await mount(t, api, favorites: true);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    await tap(t, find.byKey(const ValueKey('preview-remote:7')));
    expect(
      t
          .widget<FavoriteVideosPage>(find.byType(FavoriteVideosPage))
          .folder
          .mediaId,
      7,
    );
    await t.pageBack();
    await settle(t);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await t.pageBack();
      await settle(t);
    }
    await tap(t, find.byKey(const ValueKey('add-remote:7')));
    await tap(t, find.text('保存'));
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(
      t.widget<HomeFavoriteCover>(find.byType(HomeFavoriteCover)).remote,
      isTrue,
    );
  });
  testWidgets('同账号候选缺图不擦除已选头像快照', (t) async {
    final api = Api()..url = '';
    await seed(api, [choice('creator', '22', '已选 UP', avatar)]);
    await mount(t, api);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    expect(
      t.widget<AppNetworkImage>(find.byType(AppNetworkImage)).imageUrl,
      avatar,
    );
    await tap(t, find.text('保存'));
    expect(
      (await SharedPreferences.getInstance()).getString(key(api, false)),
      contains(avatar),
    );
  });
  testWidgets('关闭编辑器后身份迟到不跳转，双击预览只核验一次', (t) async {
    final api = Api();
    await seed(api, [choice('creator', '11', '已选 UP', avatar)]);
    await mount(t, api);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    api.identity = Completer();
    final preview = find.byKey(const ValueKey('preview-creator:11'));
    await t.tap(preview);
    await t.tap(preview);
    await settle(t);
    expect(api.identityReads, 1);
    await t.pageBack();
    await settle(t);
    if (find.byKey(const ValueKey('home-mode-custom')).evaluate().isNotEmpty) {
      await t.pageBack();
      await settle(t);
    }
    api.identity!.complete(101);
    await settle(t);
    expect(find.byType(UserProfilePage), findsNothing);
    expect(find.text('保存'), findsNothing);
  });
  testWidgets('点击时的账号核验迟到不得拿新MID放行旧UP', (t) async {
    final api = Api();
    await seed(api, [choice('creator', '11', '旧 UP', avatar)]);
    await mount(t, api);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    api.identity = Completer();
    await tap(t, find.byKey(const ValueKey('preview-creator:11')));
    api.mid = 202;
    CacheLifecycle.accountChanged();
    await settle(t);
    api.identity!.complete(202);
    await settle(t);
    expect(find.byType(UserProfilePage), findsNothing);
    expect(find.text('账号已变化，请返回后重新打开'), findsOneWidget);
  });
  testWidgets('旧首页在线仅补第一页、重建不重查，编辑保存迁移头像', (t) async {
    final api = Api();
    await seed(api, [choice('creator', '22', '旧 UP')]);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key(api, false));
    await mount(t, api);
    await settle(t);
    expect(
      t.widget<AppNetworkImage>(find.byType(AppNetworkImage)).imageUrl,
      avatar,
    );
    expect(prefs.getString(key(api, false)), raw);
    await t.pump();
    await t.pump();
    expect(api.calls, 1);
    await tap(t, find.byTooltip('自定义内容'));
    await tap(t, find.byKey(const ValueKey('home-mode-custom')));
    expect(api.calls, 1);
    await tap(t, find.text('保存'));
    expect(prefs.getString(key(api, false)), contains(avatar));
  });
  testWidgets('旧头像补查迟到在切号后不显示', (t) async {
    final api = Api()..pending = Completer();
    await seed(api, [choice('creator', '22', '旧 UP')]);
    await mount(t, api);
    api.mid = 202;
    CacheLifecycle.accountChanged();
    api.pending!.complete(
      AccountDataPage.success(
        items: [creator(22, '旧 UP', avatar)],
        page: 1,
        hasMore: false,
      ),
    );
    await settle(t);
    expect(find.text('旧 UP'), findsNothing);
    expect(find.byType(AppNetworkImage), findsNothing);
  });
  for (final url in [
    'file:///private/avatar',
    'data:image/png;test',
    'https://fixture.invalid/a?token=secret',
  ]) {
    testWidgets('头像快照不序列化非公开地址 $url', (t) async {
      final api = Api()..url = url;
      await seed(api, []);
      await mount(t, api);
      await tap(t, find.byTooltip('自定义内容'));
      await tap(t, find.byKey(const ValueKey('home-mode-custom')));
      await tap(t, find.byKey(const ValueKey('add-creator:22')));
      await tap(t, find.text('保存'));
      final saved = (await SharedPreferences.getInstance()).getString(
        key(api, false),
      )!;
      expect(saved, isNot(contains(url)));
      expect(saved, isNot(contains('avatar')));
    });
  }
}
