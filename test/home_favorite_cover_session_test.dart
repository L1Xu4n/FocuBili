import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/home_favorite_cover.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/image_resource_cache.dart';

import 'home_favorite_covers_test.dart' show choice, cover, host, seed;

class _NoCoverBytes extends ImageResourceCache {
  @override
  Future<CachedImageBytes> load(
    String url, {
    Map<String, String> headers = const {},
  }) async => throw const ImageCacheFailure();
}

class _RouteAuth extends Fake implements BilibiliAuthApi {
  bool offline = false;
  bool expired = false;
  int mid = 101;

  @override
  Future<BilibiliNavResponse> requestNavigation(String cookieHeader) async {
    if (offline) throw const SocketException('offline');
    return BilibiliNavResponse(
      statusCode: HttpStatus.ok,
      body: jsonEncode(
        expired
            ? {'code': -101}
            : {
                'code': 0,
                'data': {'isLogin': true, 'mid': mid},
              },
      ),
    );
  }
}

class _RouteCookieStore extends Fake implements BilibiliCookieStore {
  String cookie = 'SESSDATA=fixture-session';
  @override
  Future<String> readCookies() async => cookie;
}

class _RouteFolders extends Fake implements BilibiliAccountDataApi {
  int calls = 0;
  String coverUrl = 'https://i0.hdslb.com/focubili-test-original.jpg';
  void Function()? afterNextRequest;
  bool rejectNext = false;

  @override
  Future<BilibiliAccountDataResponse> get(Uri uri, String cookieHeader) async {
    expect(uri.path, '/x/v3/fav/folder/created/list-all');
    calls++;
    final after = afterNextRequest;
    afterNextRequest = null;
    after?.call();
    if (rejectNext) {
      rejectNext = false;
      return const BilibiliAccountDataResponse(
        statusCode: HttpStatus.unauthorized,
        body: '',
      );
    }
    return BilibiliAccountDataResponse(
      statusCode: HttpStatus.ok,
      body: jsonEncode({
        'code': 0,
        'data': {
          'count': 1,
          'list': [
            {'id': 7, 'title': '远端课程', 'cover': coverUrl, 'media_count': 2},
          ],
        },
      }),
    );
  }
}

void main() {
  testWidgets('真实会话适配器：断网暖返回与身份隔离', (tester) async {
    for (final boundary in ['过期', '切号', '凭据变化但网络不可用', '收藏访问被拒']) {
      SharedPreferences.setMockInitialValues({});
      await CacheLifecycle.setAccount(null);
      final nav = _RouteAuth();
      final cookies = _RouteCookieStore();
      final folders = _RouteFolders();
      final auth = BilibiliAuthService(cookieStore: cookies, api: nav);
      expect((await auth.loadCurrentSession()).isActive, isTrue);
      final account = BilibiliAccountDataService(
        sessionProvider: AuthBackedAccountSessionProvider(authService: auth),
        api: folders,
      );
      expect(
        (await account.loadFavoriteFolders()).items.single.coverUrl,
        folders.coverUrl,
      );
      final local = AppFavoriteFolder(
        id: 'route-local',
        name: '本机课程',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      await (await SharedPreferences.getInstance()).setString(
        'app_favorites.folders_v1',
        jsonEncode([local.toJson()]),
      );
      await seed(101, [
        choice('remote', '7', '旧账号远端课程'),
        choice('local', local.id, '本机课程'),
      ]);
      await seed(202, [choice('remote', '7', '新账号远端课程')]);
      final imageCache = _NoCoverBytes();
      addTearDown(imageCache.dispose);
      await tester.pumpWidget(host(account, imageCache: imageCache));
      await tester.pumpAndSettle();
      expect(
        cover(tester, 'remote', '7'),
        folders.coverUrl,
        reason: 'initial folder calls: ${folders.calls}',
      );

      Future<void> openLocal() async {
        await tester.tap(find.text('本机课程'));
        await tester.pumpAndSettle();
      }

      Future<void> closeLocal() async {
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.pump();
      }

      await openLocal();
      expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
      nav.offline = true;
      final priorCalls = folders.calls;
      final revision = CacheLifecycle.account.value;
      await closeLocal();
      expect(CacheLifecycle.account.value, revision);
      expect(
        cover(tester, 'remote', '7'),
        folders.coverUrl,
        reason:
            'after recovery network calls: ${folders.calls}, before: $priorCalls',
      );
      expect(folders.calls, priorCalls);
      expect(find.text('重试'), findsNothing);
      await openLocal();
      expect(find.byType(AppFavoriteDetailPage), findsNothing);
      expect(cover(tester, 'remote', '7'), folders.coverUrl);

      nav.offline = false;
      folders.coverUrl = 'https://i0.hdslb.com/focubili-test-refreshed.jpg';
      folders.afterNextRequest = () => nav.offline = true;
      await openLocal();
      expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
      await closeLocal();
      expect(folders.calls, priorCalls + 1);
      expect(
        cover(tester, 'remote', '7'),
        'https://i0.hdslb.com/focubili-test-original.jpg',
      );

      nav.offline = false;
      await openLocal();
      expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
      await closeLocal();
      expect(cover(tester, 'remote', '7'), folders.coverUrl);

      await openLocal();
      expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
      if (boundary == '过期') {
        nav.expired = true;
      } else if (boundary == '收藏访问被拒') {
        folders.rejectNext = true;
        folders.afterNextRequest = () => nav.offline = true;
      } else {
        cookies.cookie = 'SESSDATA=different-fixture-session';
        nav.mid = 202;
        nav.offline = boundary != '切号';
        folders.coverUrl = 'https://i0.hdslb.com/focubili-test-new-account.jpg';
      }
      await closeLocal();
      expect(find.text('旧账号远端课程'), findsNothing);
      if (boundary == '切号') {
        expect(find.text('新账号远端课程'), findsOneWidget);
        expect(cover(tester, 'remote', '7'), folders.coverUrl);
      } else {
        expect(find.byType(HomeFavoriteCover), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await CacheLifecycle.setAccount(null);
    }
  });
}
