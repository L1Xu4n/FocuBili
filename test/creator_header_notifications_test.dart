import 'dart:async';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/models/subscription.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/features/common/app_network_image.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_interaction_service.dart';
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
      sign:
          '这是一段用于验证展开行为的超长主页简介，包含课程方向、更新计划、资料说明和更多不能被静默隐藏的文字。'
          '这里继续补充课程适合人群、每周更新时间、配套练习获取方式、常见问题和联系说明，保证简介在手机宽度下真实超过两行。',
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
        CreatorArticle(id: 88, title: '测试专栏', summary: '专栏摘要', coverUrl: ''),
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

  /// 返回合集中的两支固定独立视频，供平板双列详情测试使用。
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
        CreatorVideo(
          bvid: 'BV1Q541167Qg',
          title: '合集中的第二支视频',
          coverUrl: '',
          duration: Duration(minutes: 3),
        ),
      ],
      page: page,
      hasMore: false,
      totalCount: 2,
    );
  }

  /// 返回多支固定公开投稿，让组件测试可以验证长列表和折叠资料头。
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) async {
    return CreatorContentPage<CreatorVideo>(
      items: List<CreatorVideo>.generate(
        8,
        (int index) => CreatorVideo(
          bvid: index == 0 ? 'BV1GJ411x7h7' : 'BV1GJ411x7${index + 1}',
          title: index == 0 ? '测试投稿' : '测试投稿 ${index + 1}',
          coverUrl: '',
          duration: Duration(minutes: index + 2),
          partCount: index == 0 ? 748 : 1,
          stats: VideoStats(
            viewCount: (index + 1) * 1000,
            danmakuCount: index * 10,
          ),
        ),
      ),
      page: page,
      hasMore: false,
      totalCount: 8,
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

/// 提供可切换的关注状态，让主页按钮测试不访问真实账号接口。
class _FakeInteractionService extends BilibiliInteractionService {
  bool following = false;
  int writeRequests = 0;

  /// 返回测试内存中的当前关注状态。
  @override
  Future<bool> loadFollowingState(int mid) async => following;

  /// 记录关注写操作并同步测试内存状态。
  @override
  Future<void> setFollowing({required int mid, required bool following}) async {
    writeRequests += 1;
    this.following = following;
  }
}

/// 创建使用 Material 主题的测试宿主。
Widget _host(Widget child) {
  return MaterialApp(home: child);
}

/// 验证用户主页和订阅合集页面的核心导航与信息架构。

class _TrackingContent extends _FakePublicContentService {
  final queries = <(int, String, CreatorVideoOrder)>[];
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) {
    queries.add((mid, keyword, order));
    return super.loadVideos(mid, page: page, keyword: keyword, order: order);
  }
}

class _HeldAvatarProfiles extends _FakePublicContentService {
  final requests = <(int, Completer<CreatorProfile>)>[];

  @override
  Future<CreatorProfile> loadProfile(int mid) {
    final pending = Completer<CreatorProfile>();
    requests.add((mid, pending));
    return pending.future;
  }

  void complete(int request, {int? returnedMid, String suffix = 'first'}) {
    final (mid, pending) = requests[request];
    pending.complete(
      CreatorProfile(
        mid: returnedMid ?? mid,
        name: '测试 UP',
        avatarUrl: 'https://i0.hdslb.com/bfs/face/$suffix.png',
        sign: '',
        officialDescription: '',
      ),
    );
  }
}

class _PendingFollow extends _FakeInteractionService {
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<void> setFollowing({required int mid, required bool following}) async {
    writeRequests++;
    await pending?.future;
    if (fail) throw StateError('关注失败，请重试');
    this.following = following;
  }
}

class _Subscriptions extends SubscriptionService {
  bool failAdd = false;
  int adds = 0;
  int notificationWrites = 0;
  Completer<void>? pendingAdd;
  _Subscriptions() : super(contentService: _FakePublicContentService());
  @override
  Future<void> addSource(
    SubscriptionSource source, {
    bool enableFocus = false,
  }) async {
    adds++;
    await pendingAdd?.future;
    if (failAdd) throw StateError('订阅未保存，请重试。');
    await super.addSource(source, enableFocus: enableFocus);
  }

  @override
  Future<void> setNotificationsEnabled(bool value) async {
    notificationWrites++;
    await super.setNotificationsEnabled(value);
  }
}

const _source = SubscriptionSource(
  kind: SubscriptionKind.creator,
  mid: 7,
  name: '测试UP主',
  token: 'qa',
);
Future<void> _showSubscriptionButton(
  WidgetTester tester,
  _Subscriptions service, {
  bool direct = true,
}) async {
  await service.initialize();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FocusSubscriptionButton(
          source: _source,
          service: service,
          addDirectly: direct,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _subscribeButton = find.byKey(const Key('focus-subscribe-button'));

class _RetryContent extends _TrackingContent {
  bool failing = true;
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) async {
    if (failing) throw StateError('投稿暂时不可用');
    return super.loadVideos(mid, page: page, keyword: keyword, order: order);
  }
}

class _DelayedContent extends _FakePublicContentService {
  final requests = <String, Completer<CreatorContentPage<CreatorVideo>>>{};
  bool delayed = false;
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) {
    if (!delayed) {
      return super.loadVideos(mid, page: page, keyword: keyword, order: order);
    }
    return (requests[keyword] = Completer<CreatorContentPage<CreatorVideo>>())
        .future;
  }

  void finish(String keyword, String title) => requests[keyword]!.complete(
    CreatorContentPage(
      items: [
        CreatorVideo(
          bvid: 'BV-result-$keyword',
          title: title,
          coverUrl: '',
          duration: const Duration(minutes: 1),
        ),
      ],
      page: 1,
      hasMore: false,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets('重开同一 UP 主先显示旧头像，再换成最新头像', (tester) async {
    final content = _HeldAvatarProfiles();
    Widget page(int mid) => _host(
      UserProfilePage(
        mid: mid,
        key: ValueKey(mid),
        publicContentService: content,
        interactionService: _FakeInteractionService(),
        videoService: _FakeVideoService(),
      ),
    );
    List<String> urls() => tester
        .widgetList<AppNetworkImage>(find.byType(AppNetworkImage))
        .map((image) => image.imageUrl)
        .toList();
    await tester.pumpWidget(page(7));
    await tester.pump();
    content.complete(0);
    await tester.pumpAndSettle();
    expect(urls(), contains('https://i0.hdslb.com/bfs/face/first.png'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page(7));
    await tester.pump();
    expect(content.requests, hasLength(2));
    expect(urls(), contains('https://i0.hdslb.com/bfs/face/first.png'));
    content.complete(1, suffix: 'second');
    await tester.pumpAndSettle();
    expect(urls(), contains('https://i0.hdslb.com/bfs/face/second.png'));

    await tester.pumpWidget(page(21));
    await tester.pump();
    expect(urls(), isEmpty);
    content.complete(2, returnedMid: 7, suffix: 'wrong');
    await tester.pumpAndSettle();
    expect(urls(), isEmpty);
  });

  testWidgets('切换账号立即去掉旧头像，忽略旧请求的迟到结果', (tester) async {
    final content = _HeldAvatarProfiles();
    Widget page() => _host(
      UserProfilePage(
        mid: 7,
        publicContentService: content,
        interactionService: _FakeInteractionService(),
        videoService: _FakeVideoService(),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pump();
    content.complete(0);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page());
    await tester.pump();
    expect(find.byType(AppNetworkImage), findsOneWidget);

    CacheLifecycle.accountChanged();
    await tester.pump();
    expect(find.byType(AppNetworkImage), findsNothing);
    expect(content.requests, hasLength(3));
    content.complete(1, suffix: 'old-account');
    await tester.pump();
    expect(find.byType(AppNetworkImage), findsNothing);
    content.complete(2, suffix: 'new-account');
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppNetworkImage>(find.byType(AppNetworkImage)).imageUrl,
      'https://i0.hdslb.com/bfs/face/new-account.png',
    );
  });

  testWidgets('顶栏不重复作者名称，搜索按需展开、键盘提交、收起保留筛选', (tester) async {
    final content = _TrackingContent();
    final service = _Subscriptions();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      _host(
        UserProfilePage(
          mid: 7,
          publicContentService: content,
          interactionService: _FakeInteractionService(),
          videoService: _FakeVideoService(),
          subscriptionService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试UP主'), findsOneWidget);
    expect(find.byTooltip('刷新主页'), findsNothing);
    expect(find.byKey(const Key('creator-video-search')), findsNothing);
    final bar = tester.widget<AppBar>(
      find.byKey(const Key('creator-profile-app-bar')),
    );
    expect(bar.actions, hasLength(1));
    expect(bar.title, isNull);
    await tester.tap(find.byTooltip('搜索投稿'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('creator-video-search')),
      '  线性代数  ',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(content.queries.last, (7, '线性代数', CreatorVideoOrder.latest));
    await tester.tap(find.byTooltip('收起投稿搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const Key('creator-video-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最多播放').last);
    await tester.pumpAndSettle();
    expect(content.queries.last, (7, '线性代数', CreatorVideoOrder.mostPlayed));
    await tester.tap(find.byTooltip('搜索投稿'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('creator-video-search')))
          .controller!
          .text,
      '线性代数',
    );
    await tester.enterText(find.byKey(const Key('creator-video-search')), '');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(content.queries.last.$2, '');
    await tester.tap(find.text('专栏'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('creator-video-search')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('等宽关注按钮忙碌去重、失败恢复并可重试', (tester) async {
    final interaction = _PendingFollow()..pending = Completer<void>();
    final service = _Subscriptions();
    addTearDown(service.dispose);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        UserProfilePage(
          mid: 7,
          publicContentService: _FakePublicContentService(),
          interactionService: interaction,
          videoService: _FakeVideoService(),
          subscriptionService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('creator-follow-button'));
    expect(tester.getSize(button).width, greaterThan(240));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    expect(interaction.writeRequests, 1);
    expect(find.text('处理中…'), findsOneWidget);
    interaction.fail = true;
    interaction.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('关注失败'), findsOneWidget);
    expect(find.text('关注'), findsWidgets);
    interaction.fail = false;
    interaction.pending = null;
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('取消关注'), findsOneWidget);
    expect(interaction.writeRequests, 2);
  });
  testWidgets('点一次直接订阅，成功提示自动消失，不修改系统通知开关', (tester) async {
    final service = _Subscriptions();
    addTearDown(service.dispose);
    await _showSubscriptionButton(tester, service);
    await tester.tap(_subscribeButton);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('已添加到焦点订阅'), findsOneWidget);
    expect(find.byTooltip('取消焦点订阅'), findsOneWidget);
    expect(service.sources.single.key, _source.key);
    expect(service.enabled, isTrue);
    expect(service.notificationsEnabled, isFalse);
    expect(service.notificationWrites, 0);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('已添加到焦点订阅'), findsNothing);
  });

  testWidgets('添加未完成时禁止重复操作，不提前报成功；失败可重试', (tester) async {
    final service = _Subscriptions()
      ..failAdd = true
      ..pendingAdd = Completer<void>();
    addTearDown(service.dispose);
    await _showSubscriptionButton(tester, service);
    await tester.tap(_subscribeButton);
    await tester.pump();
    await tester.tap(_subscribeButton);
    await tester.pump();
    expect(service.adds, 1);
    expect(find.text('已添加到焦点订阅'), findsNothing);
    service.pendingAdd!.complete();
    await tester.pumpAndSettle();
    expect(find.text('订阅未保存，请重试。'), findsOneWidget);
    expect(service.sources, isEmpty);
    expect(service.enabled, isFalse);
    service.failAdd = false;
    await tester.tap(_subscribeButton);
    await tester.pumpAndSettle();
    expect(service.adds, 2);
    expect(service.sources, hasLength(1));
    expect(find.text('已添加到焦点订阅'), findsOneWidget);
  });

  testWidgets('非主页的添加确认和已订阅的取消确认保持不变', (tester) async {
    final service = _Subscriptions();
    addTearDown(service.dispose);
    await _showSubscriptionButton(tester, service, direct: false);
    await tester.tap(_subscribeButton);
    await tester.pumpAndSettle();
    expect(find.text('确认订阅'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.adds, 0);
    await _showSubscriptionButton(tester, service);
    await tester.tap(_subscribeButton);
    await tester.pumpAndSettle();
    await tester.tap(_subscribeButton);
    await tester.pumpAndSettle();
    expect(find.text('取消焦点订阅'), findsOneWidget);
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(service.sources, hasLength(1));
  });
  testWidgets('快速 A 到 B 到空词时只采用最新结果', (tester) async {
    final content = _DelayedContent();
    final service = _Subscriptions();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      _host(
        UserProfilePage(
          mid: 7,
          publicContentService: content,
          interactionService: _FakeInteractionService(),
          videoService: _FakeVideoService(),
          subscriptionService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索投稿'));
    await tester.pumpAndSettle();
    content.delayed = true;
    final field = find.byKey(const Key('creator-video-search'));
    for (final keyword in ['A', 'B']) {
      await tester.enterText(field, keyword);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
    }
    content.finish('B', '新的 B 结果');
    await tester.pumpAndSettle();
    content.finish('A', '旧的 A 结果');
    await tester.pumpAndSettle();
    expect(find.text('新的 B 结果'), findsOneWidget);
    expect(find.text('旧的 A 结果'), findsNothing);
    for (final keyword in ['A', '']) {
      await tester.enterText(field, keyword);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
    }
    content.finish('', '全部投稿结果');
    await tester.pumpAndSettle();
    content.finish('A', '过时筛选');
    await tester.pumpAndSettle();
    expect(find.text('全部投稿结果'), findsOneWidget);
    expect(find.text('过时筛选'), findsNothing);
  });
  testWidgets('窄屏大字、键盘和深色桌面保持可滚动资料与订阅提示', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    for (final size in [const Size(320, 740), const Size(1100, 800)]) {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final service = _Subscriptions();
      await tester.pumpWidget(
        MaterialApp(
          theme: size.width > 900 ? ThemeData.dark() : ThemeData.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(size.width < 400 ? 2 : 1)),
            child: child!,
          ),
          home: UserProfilePage(
            mid: 7,
            publicContentService: _FakePublicContentService(),
            interactionService: _FakeInteractionService(),
            videoService: _FakeVideoService(),
            subscriptionService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('添加订阅源'));
      await tester.pumpAndSettle();
      expect(find.text('已添加到焦点订阅'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('搜索投稿'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const Key('creator-video-search')),
        '投稿',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起投稿搜索'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('creator-video-list')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      final scroll = tester.state<NestedScrollViewState>(
        find.byKey(const Key('creator-profile-scroll')),
      );
      expect(scroll.outerController.offset, greaterThan(0));
      expect(find.text('投稿').hitTestable(), findsOneWidget);
      expect(find.byTooltip('搜索投稿').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const Key('creator-video-order')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byKey(const Key('creator-video-order'))).top,
        greaterThanOrEqualTo(tester.getRect(find.byType(TabBar)).bottom),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    }
  });
  testWidgets('去掉刷新按钮后错误重试和下拉刷新仍可用', (tester) async {
    final content = _RetryContent();
    final service = _Subscriptions();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      _host(
        UserProfilePage(
          mid: 7,
          publicContentService: content,
          interactionService: _FakeInteractionService(),
          videoService: _FakeVideoService(),
          subscriptionService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('投稿暂时不可用'), findsOneWidget);
    content.failing = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('测试投稿'), findsOneWidget);
    final count = content.queries.length;
    await tester.drag(
      find.byKey(const Key('creator-video-list')),
      const Offset(0, 500),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(content.queries.length, greaterThan(count));
    expect(find.byTooltip('刷新主页'), findsNothing);
  });
}
