import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/account_collection.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';

/// 提供固定会话状态和临时 Cookie 的测试替身，不会访问 Android WebView。
class _FakeSessionProvider implements BilibiliAccountSessionProvider {
  /// 创建可记录 Cookie 读取次数的测试会话提供者。
  _FakeSessionProvider({
    required this.state,
    this.cookieHeader = 'SESSDATA=test-session',
  });

  BilibiliSessionState state;
  String cookieHeader;
  int loadCalls = 0;
  int cookieReadCalls = 0;

  /// 返回测试预设的登录状态，并记录账号数据服务是否先验证会话。
  @override
  Future<BilibiliSessionState> loadCurrentSession() async {
    loadCalls += 1;
    return state;
  }

  /// 返回测试用临时 Cookie，不代表真实账号会话。
  @override
  Future<String> readCookieHeader() async {
    cookieReadCalls += 1;
    return cookieHeader;
  }
}

/// 记录固定 URL 与临时 Cookie 的测试网络客户端，避免任何真实账号请求。
class _RecordingAccountDataApi implements BilibiliAccountDataApi {
  /// 创建以回调返回预设响应或抛出预设错误的测试客户端。
  _RecordingAccountDataApi(this._handler);

  final Future<BilibiliAccountDataResponse> Function(Uri endpoint) _handler;
  final List<Uri> endpoints = <Uri>[];
  final List<String> receivedCookies = <String>[];

  /// 记录服务构造的请求后交给测试回调，不会把 Cookie 写入磁盘或日志。
  @override
  Future<BilibiliAccountDataResponse> get(
    Uri endpoint,
    String cookieHeader,
  ) {
    endpoints.add(endpoint);
    receivedCookies.add(cookieHeader);
    return _handler(endpoint);
  }
}

/// 创建一份已验证的测试账号，供所有只读账号数据请求复用。
BilibiliSessionState _activeSession({int mid = 42}) {
  return BilibiliSessionState.active(
    BilibiliAccount(
      mid: mid,
      name: '测试账号',
      avatarUrl: 'https://i0.hdslb.com/avatar.jpg',
    ),
  );
}

/// 将 JSON 文字包装成 HTTP 成功的测试账号数据响应。
BilibiliAccountDataResponse _ok(String body) {
  return BilibiliAccountDataResponse(statusCode: HttpStatus.ok, body: body);
}

/// 创建注入同一测试会话和网络客户端的待测服务。
BilibiliAccountDataService _service(
  _FakeSessionProvider session,
  _RecordingAccountDataApi api,
) {
  return BilibiliAccountDataService(sessionProvider: session, api: api);
}

/// 集中验证账号数据服务只请求已验证会话对应的固定只读接口。
void main() {
  /// 验证未登录时服务不会读取 Cookie 或执行收藏夹网络请求。
  test('未登录状态阻止收藏夹请求', () async {
    final _FakeSessionProvider session = _FakeSessionProvider(
      state: const BilibiliSessionState.signedOut(),
    );
    final _RecordingAccountDataApi api = _RecordingAccountDataApi(
      (Uri _) async => throw StateError('不应请求网络'),
    );

    final AccountDataPage<FavoriteFolder> result =
        await _service(session, api).loadFavoriteFolders();

    expect(result.status, AccountDataLoadStatus.signedOut);
    expect(api.endpoints, isEmpty);
    expect(session.cookieReadCalls, 0);
  });

  /// 验证会话已过期和会话检查断网会保持不同状态，且都不会发请求。
  test('会话过期与网络错误不会被误判为同一种状态', () async {
    final _RecordingAccountDataApi api = _RecordingAccountDataApi(
      (Uri _) async => throw StateError('不应请求网络'),
    );
    final _FakeSessionProvider expiredSession = _FakeSessionProvider(
      state: const BilibiliSessionState.expired(),
    );
    final _FakeSessionProvider offlineSession = _FakeSessionProvider(
      state: const BilibiliSessionState.networkError(),
    );

    final AccountDataPage<FavoriteFolder> expired =
        await _service(expiredSession, api).loadFavoriteFolders();
    final AccountDataPage<FavoriteFolder> offline =
        await _service(offlineSession, api).loadFavoriteFolders();

    expect(expired.status, AccountDataLoadStatus.expired);
    expect(offline.status, AccountDataLoadStatus.networkError);
    expect(api.endpoints, isEmpty);
    expect(expiredSession.cookieReadCalls, 0);
    expect(offlineSession.cookieReadCalls, 0);
  });

  /// 验证收藏夹请求使用当前账号 mid，并过滤缺少收藏夹编号的非法项。
  test('收藏夹列表携带当前账号参数并过滤非法项', () async {
    final _FakeSessionProvider session = _FakeSessionProvider(
      state: _activeSession(),
    );
    final _RecordingAccountDataApi api = _RecordingAccountDataApi(
      (Uri _) async => _ok('''
        {
          "code": 0,
          "data": {
            "count": 2,
            "list": [
              {
                "id": 1001,
                "title": "学习收藏",
                "cover": "//i0.hdslb.com/folder.jpg",
                "media_count": 3,
                "attr": 0
              },
              {"id": 0, "title": "非法收藏夹"}
            ]
          }
        }
      '''),
    );

    final AccountDataPage<FavoriteFolder> result =
        await _service(session, api).loadFavoriteFolders();

    expect(result.status, AccountDataLoadStatus.success);
    expect(result.isEmpty, isFalse);
    expect(result.totalCount, 2);
    expect(result.items, hasLength(1));
    expect(result.items.single.mediaId, 1001);
    expect(result.items.single.coverUrl, 'https://i0.hdslb.com/folder.jpg');
    expect(api.endpoints.single.path, '/x/v3/fav/folder/created/list-all');
    expect(api.endpoints.single.queryParameters['up_mid'], '42');
    expect(api.receivedCookies, <String>['SESSDATA=test-session']);
  });

  /// 验证收藏内容请求按页传递参数、保留失效项并过滤没有 BV 号的非法项。
  test('收藏内容分页参数与视频项解析正确', () async {
    final _FakeSessionProvider session = _FakeSessionProvider(
      state: _activeSession(),
    );
    final _RecordingAccountDataApi api = _RecordingAccountDataApi(
      (Uri _) async => _ok('''
        {
          "code": 0,
          "data": {
            "info": {"media_count": 45},
            "has_more": true,
            "medias": [
              {
                "bvid": "BV1GJ411x7h7",
                "title": "正常视频",
                "cover": "https://i0.hdslb.com/video.jpg",
                "duration": 90,
                "page": 2,
                "upper": {"name": "测试UP"},
                "cnt_info": {"play": 12, "danmaku": 3},
                "fav_time": 1700000000,
                "attr": 0
              },
              {"title": "没有 BV 号"},
              {
                "bv_id": "BV1Q541167Qg",
                "title": "失效视频",
                "duration": 1,
                "attr": 9
              }
            ]
          }
        }
      '''),
    );

    final AccountDataPage<FavoriteVideo> result =
        await _service(session, api).loadFavoriteVideos(1001, page: 2);

    expect(result.status, AccountDataLoadStatus.success);
    expect(result.page, 2);
    expect(result.hasMore, isTrue);
    expect(result.totalCount, 45);
    expect(result.items, hasLength(2));
    expect(result.items.first.duration, const Duration(seconds: 90));
    expect(result.items.first.partCount, 2);
    expect(result.items.first.isAvailable, isTrue);
    expect(result.items.last.bvid, 'BV1Q541167Qg');
    expect(result.items.last.isAvailable, isFalse);
    expect(api.endpoints.single.path, '/x/v3/fav/resource/list');
    expect(api.endpoints.single.queryParameters['media_id'], '1001');
    expect(api.endpoints.single.queryParameters['pn'], '2');
    expect(api.endpoints.single.queryParameters['ps'], '20');
    expect(api.endpoints.single.queryParameters['order'], 'mtime');
  });

  /// 验证真正空列表与成功码却没有 data 的情况保持不同的页面状态。
  test('空收藏夹不等于缺失 data', () async {
    final _FakeSessionProvider session = _FakeSessionProvider(
      state: _activeSession(),
    );
    final _RecordingAccountDataApi emptyApi = _RecordingAccountDataApi(
      (Uri _) async => _ok('''
        {"code": 0, "data": {"has_more": false, "medias": []}}
      '''),
    );
    final _RecordingAccountDataApi missingDataApi = _RecordingAccountDataApi(
      (Uri _) async => _ok('{"code": 0, "data": null}'),
    );

    final AccountDataPage<FavoriteVideo> empty = await _service(
      session,
      emptyApi,
    ).loadFavoriteVideos(1001);
    final AccountDataPage<FavoriteVideo> missing = await _service(
      session,
      missingDataApi,
    ).loadFavoriteVideos(1001);

    expect(empty.status, AccountDataLoadStatus.success);
    expect(empty.isEmpty, isTrue);
    expect(missing.status, AccountDataLoadStatus.missingData);
    expect(missing.isEmpty, isFalse);
  });

  /// 验证账号接口的授权、权限和网络错误会映射到不同状态而不是统一空白页。
  test('账号接口错误映射登录过期、权限不足与网络错误', () async {
    final _FakeSessionProvider session = _FakeSessionProvider(
      state: _activeSession(),
    );
    final _RecordingAccountDataApi expiredApi = _RecordingAccountDataApi(
      (Uri _) async => _ok('{"code": -101, "message": "账号未登录"}'),
    );
    final _RecordingAccountDataApi forbiddenApi = _RecordingAccountDataApi(
      (Uri _) async => _ok('{"code": -403, "message": "权限不足"}'),
    );
    final _RecordingAccountDataApi offlineApi = _RecordingAccountDataApi(
      (Uri _) async => throw const SocketException('offline'),
    );

    final AccountDataPage<FavoriteFolder> expired = await _service(
      session,
      expiredApi,
    ).loadFavoriteFolders();
    final AccountDataPage<FavoriteFolder> forbidden = await _service(
      session,
      forbiddenApi,
    ).loadFavoriteFolders();
    final AccountDataPage<FavoriteFolder> offline = await _service(
      session,
      offlineApi,
    ).loadFavoriteFolders();

    expect(expired.status, AccountDataLoadStatus.expired);
    expect(forbidden.status, AccountDataLoadStatus.permissionDenied);
    expect(offline.status, AccountDataLoadStatus.networkError);
  });

  /// 验证已关注 UP 主分页参数、总数判断和非法 UP 条目过滤逻辑。
  test('已关注UP主列表按总数分页并过滤非法项', () async {
    final _FakeSessionProvider session = _FakeSessionProvider(
      state: _activeSession(),
    );
    final _RecordingAccountDataApi api = _RecordingAccountDataApi(
      (Uri _) async => _ok('''
        {
          "code": 0,
          "data": {
            "total": 51,
            "list": [
              {
                "mid": 7,
                "uname": "测试UP",
                "face": "//i0.hdslb.com/face.jpg",
                "sign": "专注创作",
                "mtime": 1700000000,
                "official_verify": {"desc": "官方认证"}
              },
              {"mid": 0, "uname": "非法UP"}
            ]
          }
        }
      '''),
    );

    final AccountDataPage<FollowedCreator> result =
        await _service(session, api).loadFollowedCreators();

    expect(result.status, AccountDataLoadStatus.success);
    expect(result.totalCount, 51);
    expect(result.hasMore, isTrue);
    expect(result.items, hasLength(1));
    expect(result.items.single.name, '测试UP');
    expect(result.items.single.avatarUrl, 'https://i0.hdslb.com/face.jpg');
    expect(result.items.single.officialDescription, '官方认证');
    expect(api.endpoints.single.path, '/x/relation/followings');
    expect(api.endpoints.single.queryParameters['vmid'], '42');
    expect(api.endpoints.single.queryParameters['pn'], '1');
    expect(api.endpoints.single.queryParameters['ps'], '50');
  });

  /// 验证无效收藏夹编号和会话突然缺少有效 SESSDATA 都会阻止网络请求。
  test('无效参数或缺失有效会话Cookie时阻止请求', () async {
    final _FakeSessionProvider invalidIdSession = _FakeSessionProvider(
      state: _activeSession(),
    );
    final _FakeSessionProvider emptyCookieSession = _FakeSessionProvider(
      state: _activeSession(),
      cookieHeader: 'buvid3=unrelated-cookie',
    );
    final _RecordingAccountDataApi api = _RecordingAccountDataApi(
      (Uri _) async => throw StateError('不应请求网络'),
    );

    final AccountDataPage<FavoriteVideo> invalidId = await _service(
      invalidIdSession,
      api,
    ).loadFavoriteVideos(0);
    final AccountDataPage<FollowedCreator> emptyCookie = await _service(
      emptyCookieSession,
      api,
    ).loadFollowedCreators();

    expect(invalidId.status, AccountDataLoadStatus.unavailable);
    expect(emptyCookie.status, AccountDataLoadStatus.expired);
    expect(api.endpoints, isEmpty);
    expect(invalidIdSession.cookieReadCalls, 0);
    expect(emptyCookieSession.cookieReadCalls, 1);
  });
}
