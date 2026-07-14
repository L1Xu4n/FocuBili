import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/public_profile.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';

/// 根据请求路径返回固定公开 JSON，并记录请求参数。
class _FakePublicContentRequest {
  final List<Uri> endpoints = <Uri>[];

  /// 记录请求并返回覆盖用户主页四类公开数据的测试响应。
  Future<String> call(Uri endpoint) async {
    endpoints.add(endpoint);
    switch (endpoint.path) {
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
      case '/x/space/arc/search':
        return '''
          {
            "code": 0,
            "data": {
              "page": {"count": 21},
              "list": {
                "vlist": [
                  {
                    "bvid": "BV1GJ411x7h7",
                    "title": "公开投稿",
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

/// 模拟旧投稿接口被限流后，依次返回 WBI 密钥和签名投稿数据。
class _WbiFallbackRequest {
  final List<Uri> endpoints = <Uri>[];

  /// 按请求路径返回限流、公开密钥或成功投稿响应，并记录签名参数供断言。
  Future<String> call(Uri endpoint) async {
    endpoints.add(endpoint);
    switch (endpoint.path) {
      case '/x/space/arc/search':
        return '{"code":-779,"message":"请求过于频繁"}';
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

/// 模拟 WBI 投稿第一次仍命中 -352、第二次自动恢复的短暂风控。
class _WbiRetryRequest {
  int wbiAttempts = 0;

  /// 按请求阶段返回风控、WBI 密钥和最终成功投稿。
  Future<String> call(Uri endpoint) async {
    switch (endpoint.path) {
      case '/x/space/arc/search':
        return '{"code":-352,"message":"风控校验失败"}';
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
        if (wbiAttempts == 1) {
          return '{"code":-352,"message":"风控校验失败"}';
        }
        return '''
          {
            "code": 0,
            "data": {
              "page": {"count": 1},
              "list": {
                "vlist": [
                  {
                    "bvid": "BV1GJ411x7h7",
                    "title": "重试成功投稿",
                    "duration": "1:30"
                  }
                ]
              }
            }
          }
        ''';
      default:
        throw StateError('未处理的重试测试路径：${endpoint.path}');
    }
  }
}

/// 模拟旧名片被风控后由 WBI 基本资料和关系统计接口补齐主页。
class _ProfileFallbackRequest {
  /// 按请求路径返回受限名片、WBI 密钥、基本资料和粉丝统计。
  Future<String> call(Uri endpoint) async {
    switch (endpoint.path) {
      case '/x/web-interface/card':
        return '{"code":-352,"message":"风控校验失败"}';
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
              "mid": 7,
              "name": "WBI UP主",
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

  /// 验证旧投稿接口命中 -779 后会自动获取 WBI 密钥并带签名重试。
  test('投稿限流后使用WBI签名接口降级', () async {
    final _WbiFallbackRequest request = _WbiFallbackRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorContentPage<CreatorVideo> videos = await service.loadVideos(7);

    expect(videos.items.single.title, 'WBI 投稿');
    expect(
      request.endpoints.map((Uri endpoint) => endpoint.path),
      <String>[
        '/x/space/arc/search',
        '/x/web-interface/nav',
        '/x/space/wbi/arc/search',
      ],
    );
    final Uri signedEndpoint = request.endpoints.last;
    expect(signedEndpoint.queryParameters['wts'], isNotEmpty);
    expect(signedEndpoint.queryParameters['w_rid'], hasLength(32));
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

    expect(request.endpoints.single.queryParameters['keyword'], '地理 科普');
    expect(request.endpoints.single.queryParameters['order'], 'stow');
  });

  /// 验证 -352 在 WBI 接口短暂出现时会自动重试而不要求用户手动刷新。
  test('投稿遇到-352会自动重试', () async {
    final _WbiRetryRequest request = _WbiRetryRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorContentPage<CreatorVideo> videos = await service.loadVideos(7);

    expect(request.wbiAttempts, 2);
    expect(videos.items.single.title, '重试成功投稿');
    expect(
        videos.items.single.duration, const Duration(minutes: 1, seconds: 30));
  });

  /// 验证旧名片风控时仍能通过公开 WBI 资料接口显示简介和粉丝数。
  test('用户资料风控后使用WBI资料降级', () async {
    final _ProfileFallbackRequest request = _ProfileFallbackRequest();
    final BilibiliHttpPublicContentService service =
        BilibiliHttpPublicContentService(requestJson: request.call);

    final CreatorProfile profile = await service.loadProfile(7);

    expect(profile.name, 'WBI UP主');
    expect(profile.sign, 'WBI 简介');
    expect(profile.followerCount, 3456);
  });
}
