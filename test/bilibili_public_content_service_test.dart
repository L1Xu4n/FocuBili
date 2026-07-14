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
                    "pic": "//i0.hdslb.com/video.jpg",
                    "duration": 120,
                    "created": 1704067200,
                    "play": 100,
                    "video_review": 10
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
                      "cover": "https://archive.biliimg.com/cover.jpg",
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
                  "pic": "//i0.hdslb.com/second.jpg",
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
    expect(collections.items.single.previewVideos.single.bvid, 'BV1GJ411x7h7');
    expect(entries.items.single.bvid, 'BV1Q541167Qg');
    expect(
      request.endpoints.last.queryParameters['season_id'],
      '900',
    );
  });
}
