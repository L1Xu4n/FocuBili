import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/home_collection_card.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/following_group.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/following_group_service.dart';

const _firstMid = 101;
const _secondMid = 202;
const _remoteMessage = '暂时无法读取 B 站内容，已选项目会保留。你仍可编辑本机内容。';
const _switchMessage = '账号已变化，请返回后重新打开';
const _firstRemote = 'First saved remote';
const _secondRemote = 'Second saved remote';

class _AccountData extends BilibiliAccountDataService {
  _AccountData({this.mid = _firstMid});

  int? mid;
  int favoriteLoads = 0;
  final followingPages = <int>[];
  final favoriteResult = Completer<AccountDataPage<FavoriteFolder>>();

  @override
  Future<int?> currentAccountMid() async => mid;

  @override
  Future<int?> currentHomeCollectionMid() async => mid ?? 0;

  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() {
    favoriteLoads++;
    return favoriteResult.future;
  }

  @override
  Future<AccountDataPage<FollowedCreator>> loadFollowedCreators({
    int page = 1,
  }) async {
    followingPages.add(page);
    if (page == 1) {
      return AccountDataPage.success(
        items: const [
          FollowedCreator(
            mid: 1000,
            name: 'Incomplete remote page',
            avatarUrl: '',
            sign: '',
            officialDescription: '',
            followedAt: null,
          ),
        ],
        page: page,
        hasMore: true,
        totalCount: 51,
      );
    }
    return AccountDataPage.networkError(page: page);
  }
}

class _Session implements BilibiliAccountSessionProvider {
  _Session(this.state);

  BilibiliSessionState state;
  int cookieReads = 0;

  @override
  Future<BilibiliSessionState> loadCurrentSession() async => state;

  @override
  Future<String> readCookieHeader() async {
    cookieReads++;
    return 'SESSDATA=synthetic-fixture';
  }
}

class _FailedEndpoint implements BilibiliAccountDataApi {
  @override
  Future<BilibiliAccountDataResponse> get(
    Uri endpoint,
    String cookieHeader,
  ) async => const BilibiliAccountDataResponse(statusCode: 503, body: '');
}

Widget _host(BilibiliAccountDataService api, {bool favorites = true}) =>
    MaterialApp(
      home: Scaffold(
        body: HomeCollectionCard(
          showCustomization: true,
          favorites: favorites,
          accountDataService: api,
        ),
      ),
    );

String _key(int? mid, {bool favorites = true}) =>
    'home_collection.v1.${favorites ? "favorites" : "followings"}.${mid ?? 0}';

Map<String, String> _choice(String kind, String id, String label) => {
  'kind': kind,
  'id': id,
  'label': label,
};

String _config(List<Map<String, String>> items) =>
    jsonEncode({'custom': true, 'items': items});

Future<String> _seedRemotes(
  SharedPreferences prefs,
  int mid, {
  bool favorites = true,
}) async {
  final kind = favorites ? 'remote' : 'creator';
  final raw = _config([
    _choice(kind, '11', _firstRemote),
    _choice(kind, '22', _secondRemote),
  ]);
  await prefs.setString(_key(mid, favorites: favorites), raw);
  return raw;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(Duration.zero);
  });
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  // A bounded pump also lets tests inspect an editor with a pending remote GET.
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'remote network failure still allows local save, cancel and remount',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final raw = await _seedRemotes(prefs, _firstMid);
      final other = await _seedRemotes(prefs, _secondMid);
      final guest = _config([_choice('local', 'guest-only', 'Guest only')]);
      await prefs.setString(_key(null), guest);
      final folder = (await tester.runAsync(
        () => AppFavoritesService().createFolder('Device folder'),
      ))!;
      final api = _AccountData();
      api.favoriteResult.complete(AccountDataPage.networkError());

      await tester.pumpWidget(_host(api));
      await _settle(tester);
      await _tap(tester, find.byTooltip('自定义内容'));
      expect(find.text(_remoteMessage), findsOneWidget);
      expect(find.text(_firstRemote), findsOneWidget);
      expect(find.text(_secondRemote), findsOneWidget);

      await _tap(tester, find.text(folder.name));
      await tester.pageBack();
      await _settle(tester);
      expect(prefs.getString(_key(_firstMid)), raw);
      expect(find.text(folder.name), findsNothing);

      await _tap(tester, find.byTooltip('自定义内容'));
      await _tap(tester, find.text(folder.name));
      await _tap(tester, find.text('保存'));
      final saved = _config([
        _choice('remote', '11', _firstRemote),
        _choice('remote', '22', _secondRemote),
        _choice('local', folder.id, folder.name),
      ]);
      expect(prefs.getString(_key(_firstMid)), saved);
      expect(prefs.getString(_key(_secondMid)), other);
      expect(prefs.getString(_key(null)), guest);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(api));
      await _settle(tester);
      expect(find.text(folder.name), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_firstRemote)).dy,
        lessThan(tester.getTopLeft(find.text(_secondRemote)).dy),
      );
      expect(
        tester.getTopLeft(find.text(_secondRemote)).dy,
        lessThan(tester.getTopLeft(find.text(folder.name)).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('confirmed guest edits without a remote lookup', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final private = await _seedRemotes(prefs, _firstMid);
    final folder = (await tester.runAsync(
      () => AppFavoritesService().createFolder('Guest folder'),
    ))!;
    final api = _AccountData(mid: null);
    await tester.pumpWidget(_host(api));
    await _settle(tester);
    await _tap(tester, find.byTooltip('自定义内容'));
    await _tap(tester, find.text('自选内容'));
    expect(find.text(_firstRemote), findsNothing);
    await _tap(tester, find.text(folder.name));
    await _tap(tester, find.text('保存'));

    expect(api.favoriteLoads, 0);
    expect(find.text(folder.name), findsOneWidget);
    expect(
      prefs.getString(_key(null)),
      _config([_choice('local', folder.id, folder.name)]),
    );
    expect(prefs.getString(_key(_firstMid)), private);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'later following page failure shows only local choice candidates',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await _seedRemotes(prefs, _firstMid, favorites: false);
      await tester.runAsync(
        () => FollowingGroupService.instance.save(_firstMid, [
          FollowingGroup(id: 'local-01', name: 'Local following group'),
        ]),
      );
      final api = _AccountData();
      await tester.pumpWidget(_host(api, favorites: false));
      await _settle(tester);
      await _tap(tester, find.byTooltip('自定义内容'));

      expect(api.followingPages, [1, 2]);
      expect(find.text(_remoteMessage), findsOneWidget);
      expect(find.text('Incomplete remote page'), findsNothing);
      expect(find.text(_firstRemote), findsOneWidget);
      expect(find.text(_secondRemote), findsOneWidget);
      await _tap(tester, find.text('Local following group'));
      await _tap(tester, find.text('保存'));
      expect(
        prefs.getString(_key(_firstMid, favorites: false)),
        _config([
          _choice('creator', '11', _firstRemote),
          _choice('creator', '22', _secondRemote),
          _choice('group', 'local-01', 'Local following group'),
        ]),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switch invalidates a visible editor and ignores late choices', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final old = await _seedRemotes(prefs, _firstMid);
    final next = _config([_choice('remote', '33', 'Second account only')]);
    await prefs.setString(_key(_secondMid), next);
    final folder = (await tester.runAsync(
      () => AppFavoritesService().createFolder('Device folder'),
    ))!;
    final api = _AccountData();
    await tester.pumpWidget(_host(api));
    await _settle(tester);
    await _tap(tester, find.byTooltip('自定义内容'));
    // We can already edit even though the network has not responded.
    expect(api.favoriteLoads, 1);
    await _tap(tester, find.text(folder.name));
    expect(find.text('保存'), findsOneWidget);

    api.mid = _secondMid;
    CacheLifecycle.accountChanged();
    await _settle(tester);
    api.favoriteResult.complete(
      AccountDataPage.success(
        items: const [
          FavoriteFolder(
            mediaId: 44,
            title: 'Late previous account choice',
            coverUrl: '',
            mediaCount: 0,
            isAvailable: true,
          ),
        ],
        page: 1,
        hasMore: false,
      ),
    );
    await _settle(tester);

    expect(find.text(_switchMessage), findsOneWidget);
    expect(find.text('保存'), findsNothing);
    expect(find.text(_firstRemote), findsNothing);
    expect(find.text('Late previous account choice'), findsNothing);
    await tester.pageBack();
    await _settle(tester);
    expect(find.text('Second account only'), findsOneWidget);
    expect(find.text(folder.name), findsNothing);
    expect(prefs.getString(_key(_firstMid)), old);
    expect(prefs.getString(_key(_secondMid)), next);
    expect(tester.takeException(), isNull);
  });
  testWidgets('loaded card reflects a renamed local following group', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    const groupId = 'local-stable-01';
    final raw = _config([_choice('group', groupId, 'Former group')]);
    await prefs.setString(_key(_firstMid, favorites: false), raw);
    await tester.runAsync(
      () => FollowingGroupService.instance.save(_firstMid, [
        FollowingGroup(id: groupId, name: 'Former group'),
      ]),
    );
    await tester.pumpWidget(_host(_AccountData(), favorites: false));
    await _settle(tester);
    expect(find.text('Former group'), findsOneWidget);
    await tester.runAsync(
      () => FollowingGroupService.instance.save(_firstMid, [
        FollowingGroup(id: groupId, name: 'Current group'),
      ]),
    );
    await _settle(tester);
    expect(find.text('Current group'), findsOneWidget);
    expect(find.text('Former group'), findsNothing);
    expect(prefs.getString(_key(_firstMid, favorites: false)), raw);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same group ID does not expose names from another account', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    const groupId = 'remote_3';
    final keyA = _key(_firstMid, favorites: false);
    final keyB = _key(_secondMid, favorites: false);
    final rawA = _config([
      _choice('group', groupId, 'Saved first label'),
      _choice('creator', groupId, 'Saved creator label'),
    ]);
    final rawB = _config([_choice('group', groupId, 'Saved second label')]);
    await prefs.setString(keyA, rawA);
    await prefs.setString(keyB, rawB);
    Future<void> save(int mid, String name) => FollowingGroupService.instance
        .save(mid, [FollowingGroup(id: groupId, name: name)]);
    await tester.runAsync(() async {
      await save(_firstMid, 'First group name');
      await save(_secondMid, 'Second group name');
    });
    final api = _AccountData();
    await tester.pumpWidget(_host(api, favorites: false));
    await _settle(tester);
    expect(find.text('First group name'), findsOneWidget);
    expect(find.text('Saved creator label'), findsOneWidget);
    expect(find.text('Second group name'), findsNothing);

    await tester.runAsync(() async {
      final oldRename = save(_firstMid, 'Renamed first group');
      api.mid = _secondMid;
      CacheLifecycle.accountChanged();
      await oldRename;
    });
    await _settle(tester);
    expect(find.text('Second group name'), findsOneWidget);
    expect(find.text('First group name'), findsNothing);
    expect(find.text('Renamed first group'), findsNothing);
    expect(find.text('Saved creator label'), findsNothing);
    expect(prefs.getString(keyA), rawA);
    expect(prefs.getString(keyB), rawB);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown or expired identity never uses the guest key', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final first = await _seedRemotes(prefs, _firstMid);
    final guest = _config([_choice('local', 'saved', 'Guest sentinel')]);
    await prefs.setString(_key(null), guest);

    final configure = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '自定义内容',
    );
    for (final state in const [
      BilibiliSessionState.networkError(),
      BilibiliSessionState.expired(),
    ]) {
      final session = _Session(state);
      final api = BilibiliAccountDataService(
        sessionProvider: session,
        api: _FailedEndpoint(),
      );
      await tester.pumpWidget(_host(api));
      await _settle(tester);
      expect(find.text('Guest sentinel'), findsNothing);
      expect(find.text(_firstRemote), findsNothing);
      expect(tester.widget<IconButton>(configure).onPressed, isNull);
      expect(find.text('重试'), findsOneWidget);
      expect(session.cookieReads, 0);
      expect(prefs.getString(_key(null)), guest);
      expect(prefs.getString(_key(_firstMid)), first);

      session.state = const BilibiliSessionState.signedOut();
      await _tap(tester, find.text('重试'));
      expect(find.text('Guest sentinel'), findsOneWidget);
      expect(find.text(_firstRemote), findsNothing);
      expect(tester.widget<IconButton>(configure).onPressed, isNotNull);
      expect(session.cookieReads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('loss of identity before Save does not write to any account', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final first = await _seedRemotes(prefs, _firstMid);
    final second = await _seedRemotes(prefs, _secondMid);
    final guest = _config([_choice('local', 'saved', 'Guest sentinel')]);
    await prefs.setString(_key(null), guest);
    final folder = (await tester.runAsync(
      () => AppFavoritesService().createFolder('Pending device edit'),
    ))!;
    final session = _Session(
      const BilibiliSessionState.active(
        BilibiliAccount(mid: _firstMid, name: 'Synthetic', avatarUrl: ''),
      ),
    );
    final api = BilibiliAccountDataService(
      sessionProvider: session,
      api: _FailedEndpoint(),
    );
    await tester.pumpWidget(_host(api));
    await _settle(tester);
    await _tap(tester, find.byTooltip('自定义内容'));
    await _tap(tester, find.text(folder.name));
    session.state = const BilibiliSessionState.networkError();
    await _tap(tester, find.text('保存'));
    expect(find.textContaining('无法确认当前账号，配置未保存'), findsOneWidget);
    expect(find.text('Guest sentinel'), findsNothing);
    expect(find.text(folder.name), findsNothing);
    expect(prefs.getString(_key(null)), guest);
    expect(prefs.getString(_key(_firstMid)), first);
    expect(prefs.getString(_key(_secondMid)), second);
    expect(tester.takeException(), isNull);
  });
}
