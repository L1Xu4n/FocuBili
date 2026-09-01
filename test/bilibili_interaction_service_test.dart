import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_interaction_service.dart';

/// 提供内存 Cookie 容器，让互动服务测试可以模拟已登录和未登录状态。
class _InteractionCookieStore implements BilibiliCookieStore {
  /// 创建带指定 Cookie 的测试容器。
  _InteractionCookieStore({this.cookies = ''});

  String cookies;

  /// 返回当前测试 Cookie 请求头。
  @override
  Future<String> readCookies() async => cookies;

  /// 保存登录服务验证过的 Cookie 请求头。
  @override
  Future<void> replaceCookies(String cookieHeader) async {
    cookies = cookieHeader;
  }

  /// 清空测试容器中的 B 站 Cookie。
  @override
  Future<void> clearBilibiliCookies() async {
    cookies = '';
  }
}

/// 返回固定的官方账号状态，让互动服务只测试自己的会话门禁逻辑。
class _InteractionAuthApi implements BilibiliAuthApi {
  /// 创建一个记录调用次数的账号状态测试客户端。
  _InteractionAuthApi();

  int navigationCalls = 0;

  /// 返回一份最小的已登录 `/nav` 响应。
  @override
  Future<BilibiliNavResponse> requestNavigation(String cookieHeader) async {
    navigationCalls += 1;
    return const BilibiliNavResponse(
      statusCode: 200,
      body: '{"code":0,"data":{"isLogin":true,"mid":42,"uname":"测试账号"}}',
    );
  }
}

/// 记录互动请求并按接口路径返回可控的业务响应。
class _RecordedInteractionRequest {
  /// 创建一个使用指定接口响应映射的请求记录器。
  _RecordedInteractionRequest({Map<String, String>? responses})
    : _responses = responses ?? <String, String>{};

  final Map<String, String> _responses;
  final List<Uri> endpoints = <Uri>[];
  final List<String> cookieHeaders = <String>[];
  final List<String?> bodies = <String?>[];

  /// 记录请求参数，并返回路径对应的 JSON；未配置路径默认返回成功。
  Future<BilibiliInteractionResponse> call(
    Uri endpoint, {
    required String cookieHeader,
    String? body,
  }) async {
    endpoints.add(endpoint);
    cookieHeaders.add(cookieHeader);
    bodies.add(body);
    return BilibiliInteractionResponse(
      statusCode: 200,
      body: _responses[endpoint.path] ?? '{"code":0,"data":{}}',
    );
  }
}

/// 把表单正文解析成易于断言的键值对象。
Map<String, String> _formFields(String? body) {
  if (body == null) {
    return <String, String>{};
  }
  return Uri.splitQueryString(body);
}

/// 创建一份使用内存 Cookie 和固定账号状态的互动服务。
BilibiliInteractionService _createInteractionService({
  required _RecordedInteractionRequest request,
  String cookies = 'SESSDATA=session; bili_jct=csrf-token',
}) {
  return BilibiliInteractionService(
    authService: BilibiliAuthService(
      cookieStore: _InteractionCookieStore(cookies: cookies),
      api: _InteractionAuthApi(),
    ),
    request: request.call,
  );
}

void main() {
  /// 验证未登录时不会调用任何互动写接口。
  test('未登录时不发起互动请求', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest();
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
      cookies: '',
    );

    await expectLater(
      service.setLiked(aid: 123, liked: true),
      throwsA(isA<BilibiliInteractionException>()),
    );
    expect(request.endpoints, isEmpty);
  });

  /// 验证关注、点赞、投币和收藏请求携带正确的接口路径及表单参数。
  test('互动写操作使用正确的接口和 CSRF 参数', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest();
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
      cookies: 'SESSDATA=session; bili_jct=csrf%2Btoken',
    );

    await service.setFollowing(mid: 42, following: false);
    await service.setLiked(aid: 123, liked: true);
    await service.addCoin(aid: 123, multiply: 2);
    await service.setFavorited(aid: 123, favorited: true, mediaId: 987);

    expect(request.endpoints.map((Uri endpoint) => endpoint.path), <String>[
      '/x/relation/modify',
      '/x/web-interface/archive/like',
      '/x/web-interface/coin/add',
      '/x/v3/fav/resource/deal',
    ]);
    final List<Map<String, String>> forms = request.bodies
        .map(_formFields)
        .toList(growable: false);
    expect(forms[0], <String, String>{
      'fid': '42',
      'act': '2',
      're_src': '11',
      'csrf': 'csrf+token',
      'csrf_token': 'csrf+token',
    });
    expect(forms[1], <String, String>{
      'aid': '123',
      'like': '1',
      'csrf': 'csrf+token',
      'csrf_token': 'csrf+token',
    });
    expect(forms[2], <String, String>{
      'aid': '123',
      'multiply': '2',
      'select_like': '0',
      'csrf': 'csrf+token',
      'csrf_token': 'csrf+token',
    });
    expect(forms[3], <String, String>{
      'rid': '123',
      'type': '2',
      'add_media_ids': '987',
      'del_media_ids': '',
      'platform': 'web',
      'csrf': 'csrf+token',
      'csrf_token': 'csrf+token',
    });
    expect(request.cookieHeaders, everyElement(contains('SESSDATA=session')));
  });

  /// 验证收藏时没有传入收藏夹编号会先读取第一个可用收藏夹。
  test('收藏缺少收藏夹编号时读取默认收藏夹', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest(
      responses: <String, String>{
        '/x/v3/fav/folder/created/list-all':
            '{"code":0,"data":{"list":[{"id":456}]}}',
      },
    );
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    await service.setFavorited(aid: 123, favorited: true);

    expect(request.endpoints.map((Uri endpoint) => endpoint.path), <String>[
      '/x/v3/fav/folder/created/list-all',
      '/x/v3/fav/resource/deal',
    ]);
    expect(request.endpoints.first.queryParameters, <String, String>{
      'up_mid': '42',
      'type': '2',
      'rid': '123',
    });
    expect(_formFields(request.bodies.last)['add_media_ids'], '456');
  });

  /// 验证关系 attribute、布尔型点赞和 count 收藏状态都能正确解析。
  test('视频状态兼容关系属性、布尔点赞和收藏数量', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest(
      responses: <String, String>{
        '/x/relation': '{"code":0,"data":{"attribute":6}}',
        '/x/web-interface/archive/has/like': '{"code":0,"data":true}',
        '/x/web-interface/archive/coins': '{"code":0,"data":{"multiply":1}}',
        '/x/v3/fav/resource/has': '{"code":0,"data":{"count":1}}',
        '/x/v3/fav/folder/created/list-all':
            '{"code":0,"data":{"list":[{"id":987,"fav_state":1}]}}',
      },
    );
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    final BilibiliInteractionState state = await service.loadVideoState(
      bvid: 'BV1GJ411x7h7',
      aid: 123,
      ownerMid: 42,
    );

    expect(state.isFollowing, isTrue);
    expect(state.isLiked, isTrue);
    expect(state.isCoined, isTrue);
    expect(state.coinCount, 1);
    expect(state.isFavorited, isTrue);
    expect(state.favoriteMediaId, 987);
    expect(state.favoriteMediaIds, <int>{987});
    expect(request.endpoints.first.path, '/x/relation');
    expect(request.endpoints.first.queryParameters['fid'], '42');
  });

  /// 验证一个可选状态接口失败不会丢掉已经成功返回的其他互动状态。
  test('单个状态接口失败时保留其他成功状态', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest(
      responses: <String, String>{
        '/x/relation': '{"code":-400,"message":"关系状态暂不可用"}',
        '/x/web-interface/archive/has/like': '{"code":0,"data":1}',
        '/x/web-interface/archive/coins': '{"code":0,"data":{"multiply":1}}',
        '/x/v3/fav/resource/has': '{"code":0,"data":{"count":1}}',
        '/x/v3/fav/folder/created/list-all':
            '{"code":0,"data":{"list":[{"id":987,"fav_state":1}]}}',
      },
    );
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    final BilibiliInteractionState state = await service.loadVideoState(
      bvid: 'BV1GJ411x7h7',
      aid: 123,
      ownerMid: 42,
    );

    expect(state.isFollowing, isFalse);
    expect(state.isLiked, isTrue);
    expect(state.isCoined, isTrue);
    expect(state.coinCount, 1);
    expect(state.isFavorited, isTrue);
    expect(state.favoriteMediaId, 987);
    expect(state.favoriteMediaIds, <int>{987});
  });

  /// 验证取消收藏会选择实际包含视频的收藏夹，而不是盲目使用第一个目录。
  test('取消收藏选择包含视频的收藏夹', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest(
      responses: <String, String>{
        '/x/v3/fav/folder/created/list-all':
            '{"code":0,"data":{"list":['
            '{"id":111,"fav_state":0},{"id":222,"fav_state":1}]}}',
      },
    );
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    await service.setFavorited(aid: 123, favorited: false);

    expect(_formFields(request.bodies.last)['del_media_ids'], '222');
  });

  /// 验证互关 attribute 仍属于当前账号已关注该 UP 主。
  test('互关关系被识别为已关注', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest(
      responses: <String, String>{
        '/x/relation': '{"code":0,"data":{"attribute":6}}',
      },
    );
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    expect(await service.loadFollowingState(42), isTrue);
  });

  /// 验证收藏夹选择面板能读取名称、数量和当前视频所在状态。
  test('收藏夹列表包含展示信息和当前收藏状态', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest(
      responses: <String, String>{
        '/x/v3/fav/folder/created/list-all':
            '{"code":0,"data":{"list":['
            '{"id":111,"title":"稍后学习","media_count":12,"fav_state":1},'
            '{"id":222,"title":"编程","media_count":3,"fav_state":0},'
            '{"id":0,"title":"无效"}]}}',
      },
    );
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    final List<BilibiliFavoriteFolder> folders = await service
        .loadFavoriteFolders(aid: 123);

    expect(folders, hasLength(2));
    expect(folders.first.mediaId, 111);
    expect(folders.first.title, '稍后学习');
    expect(folders.first.mediaCount, 12);
    expect(folders.first.containsVideo, isTrue);
    expect(folders.last.containsVideo, isFalse);
  });

  /// 验证新建收藏夹后可把当前视频加入返回的目录编号。
  test('创建收藏夹并收藏到新目录', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest(
      responses: <String, String>{
        '/x/v3/fav/folder/add': '{"code":0,"data":{"id":333}}',
      },
    );
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    final BilibiliFavoriteFolder folder = await service.createFavoriteFolder(
      title: ' 新收藏夹 ',
    );
    await service.setFavoriteFolder(
      aid: 123,
      mediaId: folder.mediaId,
      favorited: true,
    );

    expect(folder.mediaId, 333);
    expect(folder.title, '新收藏夹');
    expect(request.endpoints.map((Uri endpoint) => endpoint.path), <String>[
      '/x/v3/fav/folder/add',
      '/x/v3/fav/resource/deal',
    ]);
    expect(_formFields(request.bodies.first), containsPair('privacy', '0'));
    expect(
      _formFields(request.bodies.last),
      containsPair('add_media_ids', '333'),
    );
  });

  /// 验证多个新增和移除目录会被编码到同一次收藏请求中。
  test('收藏夹批量更新同时提交新增和移除编号', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest();
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    await service.setFavoriteFolders(
      aid: 123,
      addMediaIds: const <int>[333, 222, 333],
      deleteMediaIds: const <int>[111, 444],
    );

    expect(request.endpoints, hasLength(1));
    expect(request.endpoints.single.path, '/x/v3/fav/resource/deal');
    final Map<String, String> form = _formFields(request.bodies.single);
    expect(form['add_media_ids']!.split(',').toSet(), <String>{'222', '333'});
    expect(form['del_media_ids']!.split(',').toSet(), <String>{'111', '444'});
  });

  /// 验证网页互动请求头包含 Cookie、来源页、Origin 和正确表单类型。
  test('互动写请求使用完整网页来源请求头', () {
    final Map<String, String> headers = buildBilibiliInteractionRequestHeaders(
      cookieHeader: 'SESSDATA=session; bili_jct=csrf',
      hasBody: true,
    );

    expect(headers['cookie'], contains('SESSDATA=session'));
    expect(headers['referer'], 'https://www.bilibili.com/');
    expect(headers['Origin'], 'https://www.bilibili.com');
    expect(
      headers['content-type'],
      'application/x-www-form-urlencoded; charset=utf-8',
    );
  });

  /// 验证投币数量只能是界面允许的一枚或两枚。
  test('投币拒绝一枚和两枚以外的数量', () async {
    final _RecordedInteractionRequest request = _RecordedInteractionRequest();
    final BilibiliInteractionService service = _createInteractionService(
      request: request,
    );

    await expectLater(
      service.addCoin(aid: 123, multiply: 3),
      throwsA(isA<BilibiliInteractionException>()),
    );
    expect(request.endpoints, isEmpty);
  });
}
