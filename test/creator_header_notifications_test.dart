import 'dart:async';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/models/subscription.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/user_profile_page.dart';
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

class _Permission extends FocusNotificationService {
  int calls = 0;
  bool allowed = false;
  bool fail = false;
  @override
  Future<bool> requestPermission() async {
    calls++;
    if (fail) throw StateError('permission unavailable');
    return allowed;
  }
}

class _Subscriptions extends SubscriptionService {
  bool failAdd = false;
  bool failEnable = false;
  int adds = 0;
  int enables = 0;
  int notificationWrites = 0;
  _Subscriptions() : super(contentService: _FakePublicContentService());
  @override
  Future<void> addSource(SubscriptionSource source) async {
    adds++;
    if (failAdd) throw StateError('disk');
    await super.addSource(source);
  }

  @override
  Future<void> setEnabled(bool value) async {
    enables++;
    if (failEnable) throw StateError('disk');
    await super.setEnabled(value);
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
Future<void> _openNotification(
  WidgetTester tester,
  _Subscriptions service,
  _Permission permission, {
  bool creator = true,
}) async {
  await service.initialize();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FocusSubscriptionButton(
          source: _source,
          service: service,
          notificationService: permission,
          configureCreatorNotifications: creator,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('focus-subscribe-button')));
  await tester.pumpAndSettle();
}

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
  testWidgets('主页添加直接到通知设置，取消与系统返回零写入零授权', (tester) async {
    final service = _Subscriptions();
    final permission = _Permission();
    addTearDown(service.dispose);
    await _openNotification(tester, service, permission);
    expect(find.text('添加通知设置'), findsOneWidget);
    expect(find.text('确认订阅'), findsNothing);
    expect(service.sources, isEmpty);
    expect(service.enabled, isFalse);
    expect(permission.calls, 0);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(permission.calls, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.sources, isEmpty);
    expect(service.notificationWrites, 0);
    expect(service.enables, 0);
    await tester.tap(find.byKey(const Key('focus-subscribe-button')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(service.adds, 0);
  });
  testWidgets('关闭通知保存只订阅；原非主页入口仍是确认订阅', (tester) async {
    final service = _Subscriptions();
    final permission = _Permission();
    addTearDown(service.dispose);
    await _openNotification(tester, service, permission, creator: false);
    expect(find.text('确认订阅'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _openNotification(tester, service, permission);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(service.sources, hasLength(1));
    expect(service.enabled, isTrue);
    expect(service.notificationsEnabled, isFalse);
    expect(permission.calls, 0);
    await tester.tap(find.byKey(const Key('focus-subscribe-button')));
    await tester.pumpAndSettle();
    expect(find.text('取消焦点订阅'), findsOneWidget);
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(service.sources, hasLength(1));
  });
  testWidgets('权限拒绝不写入，关闭通知后可保存', (tester) async {
    final service = _Subscriptions();
    final permission = _Permission();
    addTearDown(service.dispose);
    await _openNotification(tester, service, permission);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(permission.calls, 1);
    expect(service.adds, 0);
    expect(find.textContaining('通知未获授权'), findsOneWidget);
    expect(service.notificationsEnabled, isFalse);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(service.sources, hasLength(1));
    expect(service.notificationsEnabled, isFalse);
  });
  testWidgets('允许权限才保存全局通知，失败保持可重试', (tester) async {
    final service = _Subscriptions()..failAdd = true;
    final permission = _Permission()..allowed = true;
    addTearDown(service.dispose);
    await _openNotification(tester, service, permission);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('订阅未保存，请重试。'), findsOneWidget);
    expect(service.notificationWrites, 0);
    service.failAdd = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(service.sources, hasLength(1));
    expect(service.notificationsEnabled, isTrue);
    expect(service.enabled, isTrue);
  });
  testWidgets('权限桥接失败可取消，部分保存失败明确并可重试', (tester) async {
    final service = _Subscriptions();
    final permission = _Permission()..fail = true;
    addTearDown(service.dispose);
    await _openNotification(tester, service, permission);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('订阅未保存，请重试。'), findsOneWidget);
    expect(service.sources, isEmpty);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    service.failEnable = true;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('订阅源已保存，但设置未全部完成，请重试。'), findsOneWidget);
    expect(service.sources, hasLength(1));
    service.failEnable = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(service.sources, hasLength(1));
    expect(service.enabled, isTrue);
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
  testWidgets('窄屏大字、键盘和深色桌面保持可滚动资料与通知取消', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    for (final size in [const Size(320, 740), const Size(1100, 800)]) {
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
      expect(find.text('添加通知设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
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
