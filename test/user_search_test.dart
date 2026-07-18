import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/user_search.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';

/// 记录用户搜索请求并返回一条带认证的公开用户结果。
class _UserSearchJsonRequest {
  Uri? requestedUri;

  /// 返回固定 JSON，确保服务测试不访问真实网络。
  Future<String> call(Uri uri) async {
    requestedUri = uri;
    return '''
      {
        "code": 0,
        "message": "0",
        "data": {
          "page": 1,
          "numPages": 2,
          "result": [
            {
              "mid": 778899,
              "uname": "<em class='keyword'>星球</em>研究所",
              "upic": "//i0.hdslb.com/avatar.jpg",
              "usign": "公开签名",
              "fans": 5367000,
              "videos": 198,
              "level": 6,
              "is_upuser": 1,
              "official_verify": {"type": 0, "desc": "bilibili 知名UP主"}
            }
          ]
        }
      }
    ''';
  }
}

/// 为搜索页提供空的视频能力，让组件测试只关注用户模式。
class _EmptyVideoSearchService implements BilibiliService {
  /// 视频详情在本测试中不会调用。
  @override
  Future<VideoPreview> lookupVideo(String input) {
    throw const BilibiliLookupException('测试不应查询视频详情。');
  }

  /// 视频搜索在用户模式中不会调用。
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

  /// 用户模式不展示视频候选词。
  @override
  Future<List<String>> suggestKeywords(String input) async {
    return const <String>[];
  }
}

/// 返回固定用户分页，供搜索页验证筛选、卡片和页面跳转。
class _FakeUserSearchService implements BilibiliUserSearchService {
  UserSearchFilter? lastFilter;

  /// 保存筛选并返回一条认证用户结果。
  @override
  Future<UserSearchPage> searchUsers(
    String keyword, {
    int page = 1,
    UserSearchFilter filter = const UserSearchFilter(),
  }) async {
    lastFilter = filter;
    return UserSearchPage(
      results: const <UserSearchResult>[
        UserSearchResult(
          mid: 778899,
          name: '星球研究所',
          avatarUrl: '',
          signature: '公开签名',
          followerCount: 5367000,
          videoCount: 198,
          level: 6,
          isUploader: true,
          certification: 'bilibili 知名UP主',
        ),
      ],
      page: page,
      totalPages: page,
    );
  }
}

/// 验证用户搜索解析和页面交互。
void main() {
  /// 验证服务会发送用户排序与类型参数，并解析公开认证资料。
  test('用户搜索解析认证粉丝等级和筛选参数', () async {
    final _UserSearchJsonRequest request = _UserSearchJsonRequest();
    final BilibiliVideoInfoService service = BilibiliVideoInfoService(
      requestJson: request.call,
    );

    final UserSearchPage page = await service.searchUsers(
      '星球研究所',
      filter: const UserSearchFilter(
        order: UserSearchOrder.fansDescending,
        type: UserSearchType.certified,
      ),
    );

    expect(request.requestedUri?.queryParameters['search_type'], 'bili_user');
    expect(request.requestedUri?.queryParameters['order'], 'fans');
    expect(request.requestedUri?.queryParameters['user_type'], '3');
    expect(page.results.single.name, '星球研究所');
    expect(page.results.single.followerCount, 5367000);
    expect(page.results.single.level, 6);
    expect(page.results.single.certification, 'bilibili 知名UP主');
  });

  /// 验证搜索页可以切换用户模式、展示认证卡片并进入对应主页。
  testWidgets('搜索页展示用户结果并打开UP主页', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _FakeUserSearchService userService = _FakeUserSearchService();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          service: _EmptyVideoSearchService(),
          userSearchService: userService,
        ),
      ),
    );

    await tester.tap(find.text('用户'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '星球研究所');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('user-search-778899')), findsOneWidget);
    expect(find.text('bilibili 知名UP主'), findsOneWidget);
    expect(find.text('LV6'), findsOneWidget);
    final ListTile userTile = tester.widget<ListTile>(
      find.descendant(
        of: find.byKey(const Key('user-search-778899')),
        matching: find.byType(ListTile),
      ),
    );
    userTile.onTap!();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(UserProfilePage, skipOffstage: false), findsOneWidget);
  });
}
