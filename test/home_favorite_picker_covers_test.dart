import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/focus/home_favorite_cover.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_favorite_covers_test.dart' show CoverAccount, host;

const _fallback = 'https://fixture.invalid/first-available-video.png';
const _metadata = 'https://fixture.invalid/folder-cover.png';
const _back = ValueKey('home-mode-back');
const _custom = ValueKey('home-mode-custom');

class _FixtureImages extends ImageResourceCache {
  final requested = <String>[];

  @override
  Future<CachedImageBytes> load(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    expect(headers['Referer'], 'https://www.bilibili.com/');
    requested.add(url);
    return CachedImageBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGOYuus/'
        'EDFAKAA+7gk5I6/UbAAAAABJRU5ErkJggg==',
      ),
      url,
    );
  }
}

FavoriteFolder _folder(
  int id, {
  String cover = '',
  int count = 2,
  bool available = true,
  bool? isPrivate,
}) => FavoriteFolder(
  mediaId: id,
  title: '远端收藏夹$id',
  coverUrl: cover,
  mediaCount: count,
  isAvailable: available,
  isPrivate: isPrivate,
);

FavoriteVideo _video(String cover, {bool available = true}) => FavoriteVideo(
  bvid: 'BV1GJ411x7h7',
  title: '视频',
  coverUrl: cover,
  ownerName: 'UP',
  duration: Duration.zero,
  partCount: 1,
  favoritedAt: null,
  playCount: 0,
  danmakuCount: 0,
  isAvailable: available,
);

AccountDataPage<T> _page<T>(List<T> items) =>
    AccountDataPage.success(items: items, page: 1, hasMore: false);

Finder _row(int id) => find.byKey(ValueKey('candidate-remote:$id'));

Finder _inside(int id, Type type) =>
    find.descendant(of: _row(id), matching: find.byType(type));

String _cover(WidgetTester tester, int id) =>
    tester.widget<HomeFavoriteCover>(_inside(id, HomeFavoriteCover)).coverUrl;

Future<void> _open(
  WidgetTester tester,
  CoverAccount api, {
  ImageResourceCache? images,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(host(api, dark: true, imageCache: images));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('customize-home-favorites')));
  await tester.pumpAndSettle();
  expect(api.videoCalls, isEmpty);
  await tester.tap(find.byKey(_custom));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('桌面选择器补齐远端缺图；空夹、失效和读取失败保留占位', (tester) async {
    final images = _FixtureImages();
    addTearDown(images.dispose);
    final api = CoverAccount();
    api.next = () async => _page([
      _folder(7, isPrivate: true),
      _folder(8, cover: _metadata, isPrivate: false),
      _folder(9, count: 0, isPrivate: true),
      _folder(10, available: false),
      _folder(11),
    ]);
    api.videos = (id) async => id == 11
        ? AccountDataPage.permissionDenied()
        : _page([
            _video('https://fixture.invalid/invalid.png', available: false),
            _video(''),
            _video(_fallback),
          ]);
    await _open(tester, api, images: images);

    expect(api.videoCalls, [7, 11]);
    expect(_cover(tester, 7), _fallback);
    expect(_cover(tester, 8), _metadata);
    expect(_inside(7, Image), findsOneWidget);
    expect(_inside(8, Image), findsOneWidget);
    Finder privacy(int id) =>
        find.descendant(of: _row(id), matching: find.byTooltip('私密收藏夹'));
    expect(privacy(7), findsOneWidget);
    expect(privacy(8), findsNothing);
    expect(privacy(9), findsOneWidget);
    expect(privacy(10), findsNothing);
    expect(privacy(11), findsNothing);
    expect(images.requested, unorderedEquals([_metadata, _fallback]));
    for (final id in [9, 10, 11]) {
      expect(_cover(tester, id), '');
      expect(
        find.descendant(
          of: _row(id),
          matching: find.byIcon(Icons.folder_outlined),
        ),
        findsOneWidget,
      );
    }

    await tester.tap(find.byKey(const ValueKey('add-remote:7')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<HomeFavoriteCover>(
            find.descendant(
              of: find.byKey(const ValueKey('remote:7')),
              matching: find.byType(HomeFavoriteCover),
            ),
          )
          .coverUrl,
      _fallback,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.videoCalls, [7, 11]);
    final config = (await SharedPreferences.getInstance()).getString(
      'home_collection.v1.favorites.101',
    );
    expect(jsonDecode(config!), {
      'custom': true,
      'items': [
        {'kind': 'remote', 'id': '7', 'label': '远端收藏夹7'},
      ],
    });
  });

  testWidgets('只为已挂载的候选限并发补图；可搜索列表深处的收藏夹', (tester) async {
    final release = Completer<void>();
    final api = CoverAccount();
    api.next = () async =>
        _page([for (var id = 100; id < 200; id++) _folder(id)]);
    api.videos = (id) async {
      await release.future;
      return _page([_video(_fallback)]);
    };
    final images = _FixtureImages();
    addTearDown(images.dispose);
    await _open(tester, api, images: images);
    expect(api.videoCalls, [100, 101, 102]);
    expect(_cover(tester, 100), '');

    final search = find.byType(TextField);
    await tester.enterText(search, '收藏夹199');
    await tester.pumpAndSettle();
    expect(api.videoCalls, [100, 101, 102]);
    release.complete();
    await tester.pumpAndSettle();
    expect(api.videoCalls, [100, 101, 102, 199]);
    expect(_cover(tester, 199), _fallback);

    await tester.enterText(search, '未匹配');
    await tester.pumpAndSettle();
    await tester.enterText(search, '收藏夹199');
    await tester.pumpAndSettle();
    expect(_cover(tester, 199), _fallback);
    expect(api.videoCalls, [100, 101, 102, 199]);
  });

  for (final action in ['返回显示方式', '切换账号', '无通知切换账号']) {
    testWidgets('$action 后丢弃迟到封面，不发排队中的补图请求', (tester) async {
      final pending = Completer<AccountDataPage<FavoriteVideo>>();
      final api = CoverAccount();
      api.next = () async =>
          _page([for (var id = 100; id < 112; id++) _folder(id)]);
      api.videos = (_) => pending.future;
      final images = _FixtureImages();
      addTearDown(images.dispose);
      await _open(tester, api, images: images);
      expect(api.videoCalls, [100, 101, 102]);

      if (action == '返回显示方式') {
        await tester.tap(find.byKey(_back));
      } else {
        api.mid = 202;
        if (action == '切换账号') CacheLifecycle.accountChanged();
      }
      await tester.pumpAndSettle();
      pending.complete(_page([_video(_fallback)]));
      await tester.pumpAndSettle();

      expect(api.videoCalls, [100, 101, 102]);
      expect(images.requested, isEmpty);
      expect(find.byType(HomeFavoriteCover), findsNothing);
      if (action == '返回显示方式') {
        expect(find.byKey(_custom), findsOneWidget);
      } else {
        expect(find.text('账号已变化，请返回后重新打开'), findsOneWidget);
        expect(find.text('保存'), findsNothing);
      }
    });
  }
}
