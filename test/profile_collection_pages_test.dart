import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/profile/subscribed_collections_page.dart';
import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/bilibili_service.dart';

/// 为主页和合集组件测试提供固定公开内容，不访问网络。
class _FakePublicContentService implements BilibiliPublicContentService {
  /// 返回固定 UP 主资料。
  @override
  Future<CreatorProfile> loadProfile(int mid) async {
    return CreatorProfile(
      mid: mid,
      name: '测试UP主',
      avatarUrl: '',
      sign: '主页签名',
      officialDescription: '官方认证',
      followingCount: 12,
      followerCount: 34567,
      likeCount: 89000,
    );
  }

  /// 返回一篇固定专栏。
  @override
  Future<CreatorContentPage<CreatorArticle>> loadArticles(
    int mid, {
    int page = 1,
  }) async {
    return CreatorContentPage<CreatorArticle>(
      items: const <CreatorArticle>[
        CreatorArticle(
          id: 88,
          title: '测试专栏',
          summary: '专栏摘要',
          coverUrl: '',
        ),
      ],
      page: page,
      hasMore: false,
    );
  }

  /// 返回一个固定 UGC 合集。
  @override
  Future<CreatorContentPage<CreatorCollection>> loadCollections(
    int mid, {
    int page = 1,
  }) async {
    return CreatorContentPage<CreatorCollection>(
      items: <CreatorCollection>[
        CreatorCollection(
          id: 900,
          ownerMid: mid,
          title: '测试合集',
          coverUrl: '',
          description: '多支独立视频',
          totalCount: 2,
          previewVideos: const <CreatorVideo>[],
        ),
      ],
      page: page,
      hasMore: false,
    );
  }

  /// 返回合集中的一支固定独立视频。
  @override
  Future<CreatorContentPage<CreatorVideo>> loadCollectionVideos(
    int ownerMid,
    int collectionId, {
    int page = 1,
  }) async {
    return CreatorContentPage<CreatorVideo>(
      items: const <CreatorVideo>[
        CreatorVideo(
          bvid: 'BV1GJ411x7h7',
          title: '合集中的独立视频',
          coverUrl: '',
          duration: Duration(minutes: 2),
        ),
      ],
      page: page,
      hasMore: false,
      totalCount: 1,
    );
  }

  /// 返回一支固定公开投稿。
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
  }) async {
    return CreatorContentPage<CreatorVideo>(
      items: const <CreatorVideo>[
        CreatorVideo(
          bvid: 'BV1GJ411x7h7',
          title: '测试投稿',
          coverUrl: '',
          duration: Duration(minutes: 2),
        ),
      ],
      page: page,
      hasMore: false,
    );
  }
}

/// 为订阅页面返回固定 UGC 合集，不读取真实 Cookie。
class _FakeSubscribedAccountService extends BilibiliAccountDataService {
  /// 返回一页只包含 UGC 合集的订阅资料。
  @override
  Future<AccountDataPage<SubscribedCollection>> loadSubscribedCollections({
    int page = 1,
  }) async {
    return AccountDataPage<SubscribedCollection>.success(
      items: const <SubscribedCollection>[
        SubscribedCollection(
          id: 900,
          title: '我的测试订阅',
          coverUrl: '',
          description: '合集简介',
          ownerMid: 7,
          ownerName: '测试UP主',
          ownerAvatarUrl: '',
          videoCount: 2,
          viewCount: 100,
        ),
      ],
      page: page,
      hasMore: false,
      totalCount: 1,
    );
  }
}

/// 提供视频详情服务接口的无网络测试替身。
class _FakeVideoService implements BilibiliService {
  /// 返回默认视频详情。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    return VideoPreview.placeholder();
  }

  /// 组件测试不使用搜索，因此返回空页。
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

  /// 组件测试不使用候选词，因此返回空列表。
  @override
  Future<List<String>> suggestKeywords(String input) async {
    return const <String>[];
  }
}

/// 创建使用 Material 主题的测试宿主。
Widget _host(Widget child) {
  return MaterialApp(home: child);
}

/// 验证用户主页和订阅合集页面的核心导航与信息架构。
void main() {
  /// 验证用户主页只有投稿、专栏和合集标签，不出现消息入口。
  testWidgets('用户主页显示投稿专栏合集且不显示消息', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        UserProfilePage(
          mid: 7,
          publicContentService: _FakePublicContentService(),
          videoService: _FakeVideoService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试UP主'), findsWidgets);
    expect(find.text('投稿'), findsOneWidget);
    expect(find.text('专栏'), findsOneWidget);
    expect(find.text('合集'), findsOneWidget);
    expect(find.text('发消息'), findsNothing);
    expect(find.text('测试投稿'), findsOneWidget);

    await tester.tap(find.text('专栏'));
    await tester.pumpAndSettle();
    expect(find.text('测试专栏'), findsOneWidget);

    await tester.tap(find.text('合集'));
    await tester.pumpAndSettle();
    expect(find.text('测试合集'), findsOneWidget);
  });

  /// 验证“我的订阅”展示 UGC 合集并可进入独立合集详情。
  testWidgets('我的订阅只展示合集并能打开详情', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        SubscribedCollectionsPage(
          accountDataService: _FakeSubscribedAccountService(),
          publicContentService: _FakePublicContentService(),
          videoService: _FakeVideoService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的订阅'), findsOneWidget);
    expect(find.text('我的测试订阅'), findsOneWidget);
    expect(find.textContaining('2 支视频'), findsOneWidget);

    await tester.tap(find.text('我的测试订阅'));
    await tester.pumpAndSettle();
    expect(find.text('合集中的独立视频'), findsOneWidget);
  });
}
