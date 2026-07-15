import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/public_profile.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';

/// 根据请求路径返回固定公开 JSON，并记录请求参数。
class _FakePublicContentRequest {
  final List<Uri> endpoints = <Uri>[];

  /// 记录请求并返回覆盖用户主页四类公开数据的测试响应。
  Future<String> call(Uri endpoint) async {
    endpoints.add(endpoint);
    switch (endpoint.path) {
      case '/x/web-interface/nav':
        return '''
          {
            "code": -101,
            "data": {
              "wbi_img": {
                "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
              }
            }
          }
        ''';
      case '/x/web-interface/card':
        return '''
          {
            "code": 0,
            "data": {
              "card": {
                "mid": "7",
                "name": "星球测试所",
                "face": "//i0.hdslb.com/avatar.jpg",
                "sign": "热爱地球",
                "attention": 12,
                "Official": {"desc": "官方认证"}
              },
              "follower": 34567,
              "like_num": 89000,
              "archive_count": 8,
              "article_count": 3
            }
          }
        ''';
      case '/x/space/wbi/arc/search':
        return '''
          {
            "code": 0,
            "data": {
              "page": {"count": 21},
              "list": {
                "vlist": [
                  {
                    "bvid": "BV1GJ411x7h7",
                    "title": "【全748集】公开投稿",
                    "pic": "http://i0.hdslb.com/video.jpg",
                    "duration": "2:05",
                    "created": 1704067200,
                    "play": 100,
                    "video_review": 10,
                    "favorites": 22
                  }
                ]
              }
            }
          }
        ''';
      case '/x/space/article':
        return '''
          {
            "code": 0,
            "data": {
              "count": 1,
              "articles": [
                {
                  "id": 88,
                  "title": "公开专栏",
                  "summary": "专栏摘要",
                  "image_urls": ["//i0.hdslb.com/article.jpg"],
                  "publish_time": 1704067200,
                  "view": 66
                }
              ]
            }
          }
        ''';
      case '/x/polymer/web-space/seasons_series_list':
        return '''
          {
            "code": 0,
            "data": {
              "items_lists": {
                "seasons_list": [
                  {
                    "meta": {
                      "season_id": 900,
                      "mid": 7,
                      "title": "山河合集",
                      "cover": "http://archive.biliimg.com/cover.jpg",
                      "description": "多支独立视频",
                      "total": 9
                    },
                    "archives": [
                      {
                        "bvid": "BV1GJ411x7h7",
                        "title": "合集预览",
                        "pic": "//i0.hdslb.com/preview.jpg",
                        "duration": 120,
                        "stat": {"view": 123, "danmaku": 4}
                      }
                    ]
                  }
                ],
                "series_list": [
                  {"meta": {"series_id": 901, "name": "普通系列"}}
                ]
              }
            }
          }
        ''';
      case '/x/polymer/web-space/seasons_archives_list':
        return '''
          {
            "code": 0,
            "data": {
              "meta": {"total": 9},
              "archives": [
                {
                  "bvid": "BV1Q541167Qg",
                  "title": "合集第二支视频",
                  "pic": "http://i0.hdslb.com/second.jpg",
                  "duration": 300,
                  "pubdate": 1704067200,
                  "stat": {"view": 200, "danmaku": 20}
                }
              ]
            }
          }
        ''';
      default:
        throw StateError('未处理的测试路径：${endpoint.path}');
    }
  }
}

/// 模拟投稿直接读取 WBI 密钥和签名投稿数据，不先触发旧接口风控。
class _WbiFallbackRequest {
  final List<Uri> endpoints = <Uri>[];

  /// 按请求路径返回公开密钥或成功投稿响应，并记录签名参数供断言。
  Future<String> call(Uri endpoint) async {
    endpoints.add(endpoint);
    switch (endpoint.path) {
      case '/x/web-interface/nav':
        return '''
          {
            "code": -101,
            "data": {
              "wbi_img": {
                "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
              }
            }
          }
        ''';
      case '/x/space/wbi/arc/search':
        return '''
          {
            "code": 0,
            "data": {
              "page": {"count": 1},
              "list": {
                "vlist": [
                  {
                    "bvid": "BV1GJ411x7h7",
                    "title": "WBI 投稿",
                    "pic": "http://i0.hdslb.com/wbi-video.jpg",
                    "duration": 60
                  }
                ]
              }
            }
          }
        ''';
      default:
        throw StateError('未处理的 WBI 测试路径：${endpoint.path}');
    }
  }
}

/// 模拟 WBI 投稿命中 -352 后，旧接口单次降级成功。
class _WbiRetryRequest {
  int wbiAttempts = 0;
  int legacyAttempts = 0;

  /// 按请求阶段返回 WBI 风控、公开密钥和旧接口成功投稿。
  Future<String> call(Uri endpoint) async {
    switch (endpoint.path) {
      case '/x/space/arc/search':
        legacyAttempts += 1;
        return '''
          {
            "code": 0,
            "data": {
              "page": {"count": 1},
              "list": {
                "vlist": [
                  {
                    "bvid": "BV1GJ411x7h7",
                    "title": "旧接口降级成功",
                    "duration": "1:30"
                  }
                ]
              }
            }
          }
        ''';
      case '/x/web-interface/nav':
        return '''
          {
            "code": -101,
            "data": {
              "wbi_img": {
                "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
              }
            }
          }
        ''';
      case '/x/space/wbi/arc/search':
        wbiAttempts += 1;
        return '{"code":-352,"message":"风控校验失败"}';
      default:
        throw StateError('未处理的重试测试路径：${endpoint.path}');
    }
  }
}

/// 保存固定 Cookie 的测试容器，用于验证投稿请求会复用现有登录会话。
class _FakeCookieStore implements BilibiliCookieStore {
  /// 创建返回指定 Cookie 的测试容器。
  _FakeCookieStore(this.cookieHeader);

  final String cookieHeader;

  /// 返回测试 Cookie，不访问 Android 方法通道。
  @override
  Future<String> readCookies() async => cookieHeader;

  /// 会话复用测试不替换 Cookie，因此该函数只满足接口约定。
  @override
  Future<void> replaceCookies(String cookieHeader) async {}

  /// 会话复用测试不清理 Cookie，因此该函数只满足接口约定。
  @override
  Future<void> clearBilibiliCookies() async {}
}

/// 记录投稿与资料会话请求的 Cookie、来源页和签名参数。
class _SessionAwareRequest {
  final List<Uri> endpoints = <Uri>[];
  final List<String> cookieHeaders = <String>[];
  final List<String> referers = <String>[];

  /// 返回 WBI 密钥、投稿或资料数据，并保存请求上下文供测试断言。
  Future<String> call(
    Uri endpoint, {
    required String cookieHeader,
    required String referer,
  }) async {
    endpoints.add(endpoint);
    cookieHeaders.add(cookieHeader);
    referers.add(referer);
    switch (endpoint.path) {
      case '/x/web-interface/card':
        return '{"code":-404,"message":"啥都木有"}';
      case '/x/web-interface/nav':
        return '''
          {
            "code": -101,
            "data": {
              "wbi_img": {
                "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
              }
            }
          }
        ''';
      case '/x/space/wbi/arc/search':
        return '''
          {
            "code": 0,
            "data": {
              "page": {"count": 1},
              "list": {
                "vlist": [
                  {
                    "bvid": "BV1GJ411x7h7",
                    "title": "携带会话的投稿",
                    "duration": 60
                  }
                ]
              }
            }
          }
        ''';
      case '/x/space/wbi/acc/info':
        return '''
          {
            "code": 0,
            "data": {
              "mid": 3546574294616231,
              "name": "杰哥观察者模式启动中",
              "face": "//i0.hdslb.com/large-avatar.jpg",
              "sign": "真实大 UID 资料",
              "official": {"desc": ""}
            }
          }
        ''';
      case '/x/relation/stat':
        return '{"code":0,"data":{"following":8,"follower":99}}';
      default:
        throw StateError('未处理的会话测试路径：${endpoint.path}');
    }
  }
}

/// 模拟旧名片被风控后由 WBI 基本资料和关系统计接口补齐主页。
class _ProfileFallbackRequest {
  final List<Uri> endpoints = <Uri>[];

  /// 按请求路径返回 404 名片、WBI 密钥、大 UID 基本资料和粉丝统计。
  Future<String> call(Uri endpoint) async {
    endpoints.add(endpoint);
    switch (endpoint.path) {
      case '/x/web-interface/card':
        return '{"code":-404,"message":"啥都木有"}';
      case '/x/web-interface/nav':
        return '''
          {
            "code": -101,
            "data": {
              "wbi_img": {
                "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"
              }
            }
          }
        ''';
      case '/x/space/wbi/acc/info':
        return '''
          {
            "code": 0,
            "data": {
              "mid": 3546574294616231,
              "name": "杰哥观察者模式启动中",
              "face": "//i0.hdslb.com/wbi-avatar.jpg",
              "sign": "WBI 简介",
              "official": {"desc": "WBI 认证"}
            }
          }
        ''';
      case '/x/relation/stat':
        return '{"code":0,"data":{"following":12,"follower":3456}}';
      default:
        throw StateError('未处理的资料降级路径：${endpoint.path}');
    }
  }
}

/// 验证公开用户主页与 UGC 合集服务的解析和分页参数。
void main() {
  /// 验证用户公开名片不会依赖登录 Cookie，并能解析主页统计。
  test('公开用户资料解析头像认证和统计', () async {
    final _FakePublicContentRequest request = _FakePublicContentRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorProfile profile = await service.loadProfile(7);

    expect(profile.name, '星球测试所');
    expect(profile.avatarUrl, 'https://i0.hdslb.com/avatar.jpg');
    expect(profile.officialDescription, '官方认证');
    expect(profile.followerCount, 34567);
    expect(request.endpoints.single.queryParameters['mid'], '7');
  });

  /// 验证投稿和专栏各自读取独立接口与分页字段。
  test('公开主页解析投稿和专栏', () async {
    final _FakePublicContentRequest request = _FakePublicContentRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorContentPage<CreatorVideo> videos = await service.loadVideos(7);
    final CreatorContentPage<CreatorArticle> articles =
        await service.loadArticles(7);

    expect(videos.items.single.bvid, 'BV1GJ411x7h7');
    expect(videos.items.single.stats.viewCount, 100);
    expect(videos.items.single.stats.favoriteCount, 22);
    expect(videos.items.single.partCount, 748);
    expect(
        videos.items.single.duration, const Duration(minutes: 2, seconds: 5));
    expect(
      videos.items.single.coverUrl,
      'https://i0.hdslb.com/video.jpg@480w_270h_1c.webp',
    );
    expect(videos.hasMore, isTrue);
    expect(articles.items.single.title, '公开专栏');
    expect(articles.items.single.viewCount, 66);
  });

  /// 验证合集接口只保留 seasons_list，且详情条目是独立视频而非分P。
  test('公开主页区分UGC合集和普通系列', () async {
    final _FakePublicContentRequest request = _FakePublicContentRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorContentPage<CreatorCollection> collections =
        await service.loadCollections(7);
    final CreatorContentPage<CreatorVideo> entries =
        await service.loadCollectionVideos(7, 900);

    expect(collections.items, hasLength(1));
    expect(collections.items.single.title, '山河合集');
    expect(
      collections.items.single.coverUrl,
      'https://archive.biliimg.com/cover.jpg@480w_270h_1c.webp',
    );
    expect(collections.items.single.previewVideos.single.bvid, 'BV1GJ411x7h7');
    expect(entries.items.single.bvid, 'BV1Q541167Qg');
    expect(
      entries.items.single.coverUrl,
      'https://i0.hdslb.com/second.jpg@480w_270h_1c.webp',
    );
    expect(
      request.endpoints.last.queryParameters['season_id'],
      '900',
    );
  });

  /// 验证投稿优先使用 WBI 签名接口，不先访问容易触发 -799 的旧接口。
  test('投稿优先使用WBI签名接口', () async {
    final _WbiFallbackRequest request = _WbiFallbackRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorContentPage<CreatorVideo> videos = await service.loadVideos(7);

    expect(videos.items.single.title, 'WBI 投稿');
    expect(
      request.endpoints.map((Uri endpoint) => endpoint.path),
      <String>[
        '/x/web-interface/nav',
        '/x/space/wbi/arc/search',
      ],
    );
    final Uri signedEndpoint = request.endpoints.last;
    expect(signedEndpoint.queryParameters['wts'], isNotEmpty);
    expect(signedEndpoint.queryParameters['w_rid'], hasLength(32));
    expect(signedEndpoint.queryParameters['tid'], '0');
    expect(signedEndpoint.queryParameters['special_type'], '');
    expect(signedEndpoint.queryParameters['order_avoided'], 'true');
    expect(signedEndpoint.queryParameters['platform'], 'web');
    expect(signedEndpoint.queryParameters['web_location'], '333.1387');
  });

  /// 验证投稿关键词和最多收藏排序参数会同时发送给服务端。
  test('投稿支持关键词搜索和最多收藏排序', () async {
    final _FakePublicContentRequest request = _FakePublicContentRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    await service.loadVideos(
      7,
      keyword: '地理 科普',
      order: CreatorVideoOrder.mostFavorited,
    );

    final Uri signedEndpoint = request.endpoints.last;
    expect(signedEndpoint.queryParameters['keyword'], '地理 科普');
    expect(signedEndpoint.queryParameters['order'], 'stow');
  });

  /// 验证 WBI 风控后只访问一次旧接口，不在一秒内连续轰炸投稿接口。
  test('投稿遇到-352只进行一次旧接口降级', () async {
    final _WbiRetryRequest request = _WbiRetryRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorContentPage<CreatorVideo> videos = await service.loadVideos(7);

    expect(request.wbiAttempts, 1);
    expect(request.legacyAttempts, 1);
    expect(videos.items.single.title, '旧接口降级成功');
    expect(
        videos.items.single.duration, const Duration(minutes: 1, seconds: 30));
  });

  /// 验证投稿 WBI 密钥和列表请求都复用现有会话，且列表来源页包含真实 UP 主编号。
  test('投稿请求携带现有Cookie和准确空间来源页', () async {
    const String cookie = 'SESSDATA=test-session; buvid3=test-device';
    final _SessionAwareRequest request = _SessionAwareRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(
      requestSessionJson: request.call,
      cookieStore: _FakeCookieStore(cookie),
    );

    final CreatorContentPage<CreatorVideo> videos = await service.loadVideos(7);

    expect(videos.items.single.title, '携带会话的投稿');
    expect(request.cookieHeaders, everyElement(cookie));
    expect(request.referers.first, 'https://www.bilibili.com/');
    expect(request.referers.last, 'https://space.bilibili.com/7/video');
    expect(
      request.endpoints.last.queryParameters['web_location'],
      '333.1387',
    );
  });

  /// 验证资料 WBI 降级全过程复用现有会话，并使用 PiliPlus 同款动态页来源。
  test('用户资料降级携带现有Cookie和动态页来源', () async {
    const int largeMid = 3546574294616231;
    const String cookie = 'SESSDATA=test-session; buvid3=test-device';
    final _SessionAwareRequest request = _SessionAwareRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(
      requestSessionJson: request.call,
      cookieStore: _FakeCookieStore(cookie),
    );

    final CreatorProfile profile = await service.loadProfile(largeMid);

    expect(profile.mid, largeMid);
    expect(profile.name, '杰哥观察者模式启动中');
    expect(request.cookieHeaders, everyElement(cookie));
    expect(request.referers.first, 'https://space.bilibili.com/$largeMid');
    expect(request.referers[1], 'https://www.bilibili.com/');
    expect(
      request.referers.sublist(2),
      everyElement('https://space.bilibili.com/$largeMid/dynamic'),
    );
  });

  /// 验证大 UID 的旧名片返回 404 时，仍会使用完整 WBI 参数读取真实资料。
  test('大UID用户资料404后使用完整WBI资料降级', () async {
    const int largeMid = 3546574294616231;
    final _ProfileFallbackRequest request = _ProfileFallbackRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorProfile profile = await service.loadProfile(largeMid);

    expect(profile.mid, largeMid);
    expect(profile.name, '杰哥观察者模式启动中');
    expect(profile.sign, 'WBI 简介');
    expect(profile.followerCount, 3456);
    final Uri profileEndpoint = request.endpoints.firstWhere(
      (Uri endpoint) => endpoint.path == '/x/space/wbi/acc/info',
    );
    expect(profileEndpoint.queryParameters['mid'], largeMid.toString());
    expect(profileEndpoint.queryParameters['platform'], 'web');
    expect(profileEndpoint.queryParameters['web_location'], '1550101');
    expect(profileEndpoint.queryParameters['dm_img_list'], '[]');
    expect(profileEndpoint.queryParameters['dm_img_str'], isNotEmpty);
    expect(profileEndpoint.queryParameters['dm_cover_img_str'], isNotEmpty);
    expect(profileEndpoint.queryParameters['w_rid'], hasLength(32));
  });
}
