import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/features/profile/favorite_folders_page.dart';
import 'package:focubili/features/profile/favorite_videos_page.dart';
import 'package:focubili/features/profile/followed_creators_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_service.dart';

/// 提供固定已登录状态和测试 Cookie 的会话替身，不访问 Android WebView。
class _TestSessionProvider implements BilibiliAccountSessionProvider {
  /// 创建当前测试页面可用的已登录会话提供者。
  _TestSessionProvider({this.state});

  BilibiliSessionState? state;
  final String cookieHeader = 'SESSDATA=widget-test-session';

  /// 返回预设会话；未传入时返回一个固定的已登录测试账号。
  @override
  Future<BilibiliSessionState> loadCurrentSession() async {
    return state ??
        const BilibiliSessionState.active(
          BilibiliAccount(
            mid: 42,
            name: '测试账号',
            avatarUrl: '',
          ),
        );
  }

  /// 返回测试专用会话字段，不代表真实 Cookie 或真实账号资料。
  @override
  Future<String> readCookieHeader() async => cookieHeader;
}

/// 用回调返回固定 JSON 的账号数据网络替身，记录页面请求的接口地址。
class _CallbackAccountDataApi implements BilibiliAccountDataApi {
  /// 创建按请求 URL 返回预设响应的测试客户端。
  _CallbackAccountDataApi(this._handler);

  final Future<BilibiliAccountDataResponse> Function(Uri endpoint) _handler;
  final List<Uri> endpoints = <Uri>[];

  /// 记录页面服务的请求地址后返回回调结果，不发起真实网络请求。
  @override
  Future<BilibiliAccountDataResponse> get(
    Uri endpoint,
    String cookieHeader,
  ) {
    endpoints.add(endpoint);
    return _handler(endpoint);
  }
}

/// 提供可统计详情查询次数的公开视频服务替身，避免 Widget 测试访问网络。
class _RecordingVideoService implements BilibiliService {
  int lookupCalls = 0;

  /// 返回一个最小可播放预览，并记录收藏视频卡片是否请求了公开详情。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookupCalls += 1;
    return VideoPreview(
      bvid: input,
      cid: 1,
      title: '播放器测试视频',
      ownerName: '测试UP',
      parts: const <VideoPart>[
        VideoPart(
          pageNumber: 1,
          cid: 1,
          title: 'P1',
          duration: Duration(seconds: 1),
        ),
      ],
    );
  }

  /// 返回空搜索页；收藏页测试不会调用此方法。
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    return VideoSearchPage(
      results: const <VideoSearchResult>[],
      page: page,
      totalPages: page,
    );
  }

  /// 返回空候选词；收藏页测试不会调用此方法。
  @override
  Future<List<String>> suggestKeywords(String input) async => const <String>[];
}

/// 创建 HTTP 成功且含给定 JSON 正文的账号数据响应。
BilibiliAccountDataResponse _ok(String body) {
  return BilibiliAccountDataResponse(statusCode: 200, body: body);
}

/// 创建带测试会话和测试网络客户端的真实账号数据服务。
BilibiliAccountDataService _accountService(
  Future<BilibiliAccountDataResponse> Function(Uri endpoint) handler, {
  BilibiliSessionState? session,
}) {
  return BilibiliAccountDataService(
    sessionProvider: _TestSessionProvider(state: session),
    api: _CallbackAccountDataApi(handler),
  );
}

/// 为页面测试创建能处理播放器命名路由的最小 MaterialApp 宿主。
Widget _host(Widget child) {
  return MaterialApp(
    home: child,
    onGenerateRoute: (RouteSettings settings) {
      if (settings.name == AppRoutes.player) {
        return MaterialPageRoute<void>(
          // 测试播放器路由构建函数只确认导航参数已被页面正确发送。
          builder: (BuildContext context) => const Scaffold(
            body: Center(child: Text('播放器路由已打开')),
          ),
        );
      }
      return null;
    },
  );
}

/// 验证收藏夹、内容和关注页在真实只读服务协议下正确呈现状态与分页。
void main() {
  /// 验证收藏夹列表可进入内容页，且两个页面都从同一只读服务读取数据。
  testWidgets('收藏夹列表打开内容页', (WidgetTester tester) async {
    final BilibiliAccountDataService service = _accountService(
      (Uri endpoint) async {
        if (endpoint.path.contains('folder/created/list-all')) {
          return _ok('''
            {
              "code": 0,
              "data": {
                "list": [
                  {"id": 1001, "title": "学习收藏", "cover": "", "media_count": 1, "attr": 0}
                ]
              }
            }
          ''');
        }
        return _ok('''
          {
            "code": 0,
            "data": {
              "has_more": false,
              "medias": [
                {
                  "bvid": "BV1GJ411x7h7",
                  "title": "收藏视频",
                  "cover": "",
                  "duration": 90,
                  "page": 1,
                  "upper": {"name": "测试UP"},
                  "attr": 0
                }
              ]
            }
          }
        ''');
      },
    );

    await tester.pumpWidget(
      _host(
        FavoriteFoldersPage(
          accountDataService: service,
          bilibiliService: _RecordingVideoService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('favorite-folders-list')), findsOneWidget);
    expect(find.text('学习收藏'), findsOneWidget);
    await tester.tap(find.byKey(const Key('favorite-folder-1001')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('favorite-videos-list')), findsOneWidget);
    expect(find.text('收藏视频'), findsOneWidget);
  });

  /// 验证可播放收藏视频会补查公开详情并跳转，失效视频不会触发详情查询。
  testWidgets('收藏视频加载更多并仅打开可播放项', (WidgetTester tester) async {
    final BilibiliAccountDataService service = _accountService(
      (Uri endpoint) async {
        final String page = endpoint.queryParameters['pn'] ?? '1';
        if (page == '1') {
          return _ok('''
            {
              "code": 0,
              "data": {
                "has_more": true,
                "medias": [
                  {"bvid": "BV1GJ411x7h7", "title": "可播放视频", "cover": "", "duration": 1, "attr": 0},
                  {"bvid": "BV1Q541167Qg", "title": "失效视频", "cover": "", "duration": 1, "attr": 9}
                ]
              }
            }
          ''');
        }
        return _ok('''
          {
            "code": 0,
            "data": {
              "has_more": false,
              "medias": [
                {"bvid": "BV1xx411c7mD", "title": "第二页视频", "cover": "", "duration": 2, "attr": 0}
              ]
            }
          }
        ''');
      },
    );
    final _RecordingVideoService videoService = _RecordingVideoService();
    const FavoriteFolder folder = FavoriteFolder(
      mediaId: 1001,
      title: '测试收藏夹',
      coverUrl: '',
      mediaCount: 3,
      isAvailable: true,
    );

    await tester.pumpWidget(
      _host(
        FavoriteVideosPage(
          folder: folder,
          accountDataService: service,
          bilibiliService: videoService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('favorite-videos-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('第二页视频'), findsOneWidget);

    await tester.tap(find.byKey(const Key('favorite-video-BV1Q541167Qg')));
    await tester.pumpAndSettle();
    expect(videoService.lookupCalls, 0);

    await tester.tap(find.byKey(const Key('favorite-video-BV1GJ411x7h7')));
    await tester.pumpAndSettle();
    expect(videoService.lookupCalls, 1);
    expect(find.text('播放器路由已打开'), findsOneWidget);
  });

  /// 验证订阅页明确说明已关注 UP 主，并可通过加载更多追加下一页内容。
  testWidgets('关注页加载更多已关注UP主', (WidgetTester tester) async {
    final BilibiliAccountDataService service = _accountService(
      (Uri endpoint) async {
        final String page = endpoint.queryParameters['pn'] ?? '1';
        if (page == '1') {
          return _ok('''
            {
              "code": 0,
              "data": {
                "total": 51,
                "list": [
                  {"mid": 1, "uname": "第一页UP", "face": "", "sign": "第一条"}
                ]
              }
            }
          ''');
        }
        return _ok('''
          {
            "code": 0,
            "data": {
              "total": 51,
              "list": [
                {"mid": 2, "uname": "第二页UP", "face": "", "sign": "第二条"}
              ]
            }
          }
        ''');
      },
    );

    await tester.pumpWidget(
      _host(FollowedCreatorsPage(accountDataService: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的关注'), findsOneWidget);
    expect(find.text('第一页UP'), findsOneWidget);
    await tester.tap(find.byKey(const Key('followed-creators-load-more')));
    await tester.pumpAndSettle();
    expect(find.text('第二页UP'), findsOneWidget);
  });

  /// 验证三个页面把登录、权限和缺失数据状态显示为明确说明而非空列表。
  testWidgets('账号数据失败状态显示可重试说明', (WidgetTester tester) async {
    final BilibiliAccountDataService signedOutService = _accountService(
      (Uri endpoint) async => _ok('{"code": 0, "data": {"list": []}}'),
      session: const BilibiliSessionState.signedOut(),
    );
    final BilibiliAccountDataService permissionService = _accountService(
      (Uri endpoint) async => _ok('{"code": -403, "message": "权限不足"}'),
    );
    final BilibiliAccountDataService missingDataService = _accountService(
      (Uri endpoint) async => _ok('{"code": 0, "data": null}'),
    );
    const FavoriteFolder folder = FavoriteFolder(
      mediaId: 1001,
      title: '测试收藏夹',
      coverUrl: '',
      mediaCount: 0,
      isAvailable: true,
    );

    await tester.pumpWidget(
      _host(FavoriteFoldersPage(accountDataService: signedOutService)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('favorite-folders-status-signedOut')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _host(
        FavoriteVideosPage(
          folder: folder,
          accountDataService: permissionService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('favorite-videos-status-permissionDenied')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _host(FollowedCreatorsPage(accountDataService: missingDataService)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('followed-creators-status-missingData')),
      findsOneWidget,
    );
  });
}
