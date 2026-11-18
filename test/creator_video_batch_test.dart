import 'dart:async';
import 'package:focubili/core/widgets/drag_selection_region.dart';
import 'package:focubili/features/common/video_batch_actions.dart';
import 'package:focubili/services/app_favorites_service.dart';
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
import 'package:focubili/services/learning_list_service.dart';

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

class _Many extends _FakePublicContentService {
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) async => CreatorContentPage(
    items: List.generate(
      40,
      (i) => CreatorVideo(
        bvid: 'BVqa$i',
        title: '投稿课程 $i',
        coverUrl: '',
        duration: const Duration(minutes: 4),
        partCount: 2,
      ),
    ),
    page: 1,
    hasMore: false,
    totalCount: 818,
  );
}

class _Paging extends _Many {
  final next = Completer<CreatorContentPage<CreatorVideo>>();
  int pages = 0;
  CreatorContentPage<CreatorVideo> pageOf(int page) => CreatorContentPage(
    items: List.generate(
      page == 1 ? 8 : 16,
      (i) => CreatorVideo(
        bvid: 'BVqa${i + (page == 1 ? 0 : 8)}',
        title: '投稿课程 ${i + (page == 1 ? 0 : 8)}',
        coverUrl: '',
        duration: const Duration(minutes: 4),
        partCount: 2,
      ),
    ),
    page: page,
    hasMore: page == 1,
    totalCount: 818,
  );
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) async {
    pages++;
    return page == 1 ? pageOf(1) : next.future;
  }
}

class _Details extends _FakeVideoService {
  int reads = 0;
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    reads++;
    return VideoPreview(
      bvid: input,
      cid: 1,
      title: '课程详情',
      ownerName: '测试UP主',
      parts: const [
        VideoPart(
          pageNumber: 1,
          cid: 1,
          title: '第一讲',
          duration: Duration(minutes: 4),
        ),
        VideoPart(
          pageNumber: 2,
          cid: 2,
          title: '第二讲',
          duration: Duration(minutes: 5),
        ),
      ],
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  _Details? details,
  BilibiliPublicContentService? content,
  LearningListService? learning,
  AppFavoritesService? local,
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final videos = details ?? _Details(),
      learn = learning ?? LearningListService();
  final subscription = SubscriptionService(contentService: _Many());
  addTearDown(subscription.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: size.width > 900 ? ThemeData.dark() : ThemeData.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: UserProfilePage(
        mid: 7,
        publicContentService: content ?? _Many(),
        videoService: videos,
        interactionService: _FakeInteractionService(),
        learningListService: learn,
        subscriptionService: subscription,
        batchActions: VideoBatchActions(
          learningService: learn,
          videoService: videos,
          appFavoritesService: local,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 通过真实搜索入口收起资料，保留列表的真实内层 controller。
  await tester.tap(find.byTooltip('搜索投稿'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('收起投稿搜索'));
  await tester.pumpAndSettle();
}

class _Odd extends _Many {
  final pending = Completer<CreatorContentPage<CreatorVideo>>();
  final log = <String>[];
  bool repeat = false;
  CreatorVideo v(String id) => CreatorVideo(
    bvid: id,
    title: '独立验证 $id',
    coverUrl: '',
    duration: const Duration(minutes: 3),
    partCount: 2,
  );
  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) async {
    log.add('$order/$page');
    if (repeat) {
      return CreatorContentPage(
        items: [v('BV重复'), v('BV重复'), v(''), v('BV保留')],
        page: 1,
        hasMore: false,
        totalCount: 2,
      );
    }
    if (page > 1) return pending.future;
    final prefix = order == CreatorVideoOrder.latest ? '旧' : '新';
    return CreatorContentPage(
      items: List.generate(20, (i) => v('BV$prefix$i')),
      page: 1,
      hasMore: order == CreatorVideoOrder.latest,
      totalCount: 818,
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets('三点菜单不会播放，单项学习仍先选择分P且取消不写', (tester) async {
    final details = _Details(), learning = LearningListService();
    await _pump(tester, details: details, learning: learning);
    await tester.tap(find.byKey(const Key('add-creator-video-BVqa0')));
    await tester.pumpAndSettle();
    expect(find.text('加入学习清单'), findsOneWidget);
    expect(find.text('加入收藏夹'), findsOneWidget);
    expect(details.reads, 0);
    await tester.tap(find.text('加入学习清单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第一讲'), findsOneWidget);
    expect(find.textContaining('第二讲'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await learning.loadEntries(), isEmpty);
    expect(find.byType(UserProfilePage), findsOneWidget);
  });
  testWidgets('长按行后行点击与勾选只改变选择，取消目的地保留选择', (tester) async {
    final details = _Details();
    await _pump(tester, details: details);
    await tester.longPress(find.byKey(const Key('creator-video-BVqa0')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('creator-video-BVqa1')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2'), findsOneWidget);
    expect(details.reads, 0);
    await tester.tap(find.byKey(const Key('creator-batch-save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('save-destination-learning')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('save-destination-favorites')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('已选 2'), findsNothing);
    expect(find.byType(UserProfilePage), findsOneWidget);
  });
  testWidgets('两支投稿批量学习仍经分P选择，确认后保存默认P', (tester) async {
    final learning = LearningListService();
    await _pump(tester, learning: learning);
    await tester.longPress(find.byKey(const Key('creator-video-BVqa0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('check-creator-BVqa1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('creator-batch-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-destination-learning')));
    await tester.pumpAndSettle();
    expect(find.textContaining('第一讲'), findsWidgets);
    expect(find.textContaining('第二讲'), findsWidgets);
    expect(await learning.loadEntries(), isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '确认加入'));
    await tester.pumpAndSettle();
    expect((await learning.loadEntries()).map((e) => e.bvid).toSet(), {
      'BVqa0',
      'BVqa1',
    });
    expect(await learning.loadEntries(), hasLength(2));
    expect(find.byKey(const Key('creator-batch-save')), findsNothing);
  });
  testWidgets('两支投稿实际收藏到本机且成功退出多选', (tester) async {
    final local = AppFavoritesService();
    final folder = await tester.runAsync(() => local.createFolder('复习资料'));
    await _pump(tester, local: local);
    await tester.tap(find.byKey(const Key('add-creator-video-BVqa0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入收藏夹'));
    await tester.pumpAndSettle();
    expect(find.text('选择收藏夹'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await local.loadItems(folder!.id), isEmpty);
    await tester.longPress(find.byKey(const Key('creator-video-BVqa0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('check-creator-BVqa1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('creator-batch-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-destination-favorites')));
    await tester.pumpAndSettle();
    expect(find.text('选择收藏夹'), findsOneWidget);
    await tester.tap(find.text('复习资料'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入收藏夹'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();
    expect((await local.loadItems(folder.id)).map((e) => e.bvid).toSet(), {
      'BVqa0',
      'BVqa1',
    });
    expect(find.byKey(const Key('creator-batch-save')), findsNothing);
  });
  testWidgets('勾选长按拖过与边缘停留驱动真实内列表并选择新增可见行', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('多选投稿'));
    await tester.pumpAndSettle();
    final start = tester.getCenter(
          find.byKey(const Key('check-creator-BVqa0')),
        ),
        end = tester.getCenter(find.byKey(const Key('check-creator-BVqa2')));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(end);
    await tester.pump();
    expect(find.text('已选 3'), findsOneWidget);
    final region = tester.widget<DragSelectionRegion>(
      find.byType(DragSelectionRegion),
    );
    final before = region.controller.offset;
    final rect = tester.getRect(find.byType(DragSelectionRegion));
    await gesture.moveTo(Offset(start.dx, rect.bottom - 4));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(region.controller.offset, greaterThan(before));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(UserProfilePage), findsOneWidget);
  });
  testWidgets('排序和切换标签清除旧选择', (tester) async {
    await _pump(tester);
    await tester.longPress(find.byKey(const Key('creator-video-BVqa0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('creator-video-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最多播放'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('creator-batch-save')), findsNothing);
    await tester.longPress(find.byKey(const Key('creator-video-BVqa0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('专栏'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('creator-batch-save')), findsNothing);
    expect(find.text('测试专栏'), findsOneWidget);
  });
  for (final config in [
    (const Size(320, 740), 2.0),
    (const Size(1100, 800), 1.0),
  ]) {
    testWidgets('多选和方形目的地适配 ${config.$1}', (tester) async {
      await _pump(tester, size: config.$1, scale: config.$2);
      expect(tester.takeException(), isNull);
      await tester.longPress(find.byKey(const Key('creator-video-BVqa0')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('creator-batch-save')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('save-destination-learning')),
        findsOneWidget,
      );
    });
  }
  testWidgets('在UP内列表底边等待慢页，追加后无需移动手指继续滚选', (tester) async {
    final paging = _Paging();
    await _pump(tester, content: paging);
    await tester.tap(find.byTooltip('多选投稿'));
    await tester.pumpAndSettle();
    final start = tester.getCenter(
      find.byKey(const Key('check-creator-BVqa0')),
    );
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    final bounds = tester.getRect(find.byType(DragSelectionRegion));
    await gesture.moveTo(Offset(start.dx, bounds.bottom - 3));
    for (var i = 0; i < 110; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(paging.pages, 2);
    final before = tester
        .widget<DragSelectionRegion>(find.byType(DragSelectionRegion))
        .controller
        .offset;
    paging.next.complete(paging.pageOf(2));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final region = tester.widget<DragSelectionRegion>(
      find.byType(DragSelectionRegion),
    );
    expect(region.itemCount, 24);
    expect(region.controller.offset, greaterThan(before));
    expect(region.checkedAt(10), isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('首屏重复或空 BV 不创建重复卡和无法保存的伪选项', (t) async {
    final o = _Odd()..repeat = true;
    await _pump(t, content: o);
    final repeated = find.byKey(const ValueKey('creator-video-BV重复'));
    expect(repeated, findsOneWidget);
    expect(find.byKey(const ValueKey('creator-video-')), findsNothing);
    await t.longPress(repeated);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('creator-video-BV保留')));
    await t.pumpAndSettle();
    expect(find.text('已选 2'), findsOneWidget);
    await t.tap(find.byKey(const Key('creator-batch-save')));
    await t.pumpAndSettle();
    expect(find.text('已选 2 支视频'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('旧排序的慢分页响应不能重新进入新排序或改写新选区', (t) async {
    final o = _Odd();
    await _pump(t, content: o);
    final drag = t.widget<DragSelectionRegion>(
      find.byType(DragSelectionRegion),
    );
    drag.controller.jumpTo(drag.controller.position.maxScrollExtent);
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
    expect(o.log.last, 'CreatorVideoOrder.latest/2');
    await t.tap(find.byKey(const Key('creator-video-order')));
    await t.pump();
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.tap(find.text('最多播放').hitTestable());
    await t.pumpAndSettle();
    final r = t.widget<DragSelectionRegion>(find.byType(DragSelectionRegion));
    r.controller.jumpTo(0);
    await t.pumpAndSettle();
    await t.longPress(find.byKey(const ValueKey('creator-video-BV新0')));
    await t.pumpAndSettle();
    o.pending.complete(
      CreatorContentPage(items: [o.v('BV迟到')], page: 2, hasMore: false),
    );
    await t.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);
    expect(
      t.widget<DragSelectionRegion>(find.byType(DragSelectionRegion)).itemCount,
      20,
    );
    expect(find.textContaining('迟到'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
