import 'dart:async';

import 'package:focubili/core/widgets/drag_checkbox_options.dart';
import 'package:flutter/material.dart';
import 'package:focubili/core/layout/adaptive_two_column_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/collection_detail_page.dart';
import 'package:focubili/features/common/video_batch_actions.dart';
import 'package:focubili/features/common/video_list_selection.dart';
import 'package:focubili/features/common/video_save_destination_dialog.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_interaction_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/subscription_service.dart';

import 'support/checkbox_sweep.dart';

CreatorVideo lesson(int n, {String ownerName = ''}) => CreatorVideo(
  bvid: 'BV$n',
  title: '课程$n',
  ownerName: ownerName,
  coverUrl: '',
  duration: const Duration(minutes: 3),
);

class _Content implements BilibiliPublicContentService {
  final requests = <int>[];
  Completer<void>? nextPage;
  int? overlapThrough;
  bool stalls = false;
  @override
  Future<CreatorContentPage<CreatorVideo>> loadCollectionVideos(
    int mid,
    int id, {
    int page = 1,
  }) async {
    requests.add(page);
    if (page > 1 && nextPage != null) await nextPage!.future;
    if (page > 1 && stalls) {
      return CreatorContentPage(
        items: [lesson(1)],
        page: page - 1,
        hasMore: true,
      );
    }
    if (page > 1 && overlapThrough != null && page <= overlapThrough!) {
      return CreatorContentPage(
        items: [for (var n = 1; n <= 18; n++) lesson(n)],
        page: page,
        hasMore: true,
      );
    }
    return CreatorContentPage(
      items: page == 1
          ? [lesson(1), lesson(1), for (var i = 2; i <= 18; i++) lesson(i)]
          : [lesson(18), for (var i = 19; i <= 40; i++) lesson(i)],
      page: page,
      hasMore: page == 1,
      totalCount: 40,
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Videos implements BilibiliService {
  final calls = <String>[];
  Completer<VideoPreview>? hold;
  VideoPreview model(int n) => VideoPreview(
    bvid: 'BV$n',
    cid: 100 + n,
    aid: 1000 + n,
    title: '课程$n',
    ownerName: '作者',
    parts: [
      VideoPart(
        pageNumber: 1,
        cid: 100 + n,
        title: '第一课',
        duration: const Duration(minutes: 3),
      ),
      VideoPart(
        pageNumber: 2,
        cid: 200 + n,
        title: '第二课',
        duration: const Duration(minutes: 3),
      ),
    ],
  );
  @override
  Future<VideoPreview> lookupVideo(String bvid) async {
    calls.add(bvid);
    return hold?.future ?? model(int.parse(bvid.substring(2)));
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Account extends BilibiliAccountDataService {
  int? mid = 13;
  @override
  Future<int?> currentAccountMid() async => mid;
  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() async =>
      AccountDataPage.success(
        items: const [
          FavoriteFolder(
            mediaId: 1,
            title: '线上物理',
            coverUrl: '',
            mediaCount: 4,
            isAvailable: true,
          ),
          FavoriteFolder(
            mediaId: 3,
            title: '不可写入的收藏夹',
            coverUrl: '',
            mediaCount: 0,
            isAvailable: false,
          ),
          FavoriteFolder(
            mediaId: 2,
            title: '线上笔记',
            coverUrl: '',
            mediaCount: 3,
            isAvailable: true,
          ),
        ],
        page: 1,
        hasMore: false,
      );
}

class _Remote extends BilibiliInteractionService {
  final writes = <int>[];
  final existing = <(int, int)>{};
  final attempts = <(int, int)>[];
  int? fail;
  (int, int)? failPair;
  @override
  Future<bool> addToVerifiedFavoriteFolder({
    required int aid,
    required int mediaId,
    required int expectedMid,
    required bool Function() isCurrent,
  }) async {
    expect(mediaId, isIn([1, 2]));
    expect(expectedMid, 13);
    if (!isCurrent()) throw StateError('account');
    final pair = (aid, mediaId);
    attempts.add(pair);
    if (fail == aid || failPair == pair) throw StateError('offline');
    if (!existing.add(pair)) return false;
    writes.add(aid);
    return true;
  }
}

class _MemoryFavorites extends AppFavoritesService {
  final folders = <AppFavoriteFolder>[];
  final contents = <String, Map<String, AppFavoriteItem>>{};

  @override
  Future<AppFavoriteFolder> createFolder(String name) async {
    final now = DateTime(2026);
    final folder = AppFavoriteFolder(
      id: 'folder-${folders.length}',
      name: name,
      createdAt: now,
      updatedAt: now,
    );
    folders.add(folder);
    return folder;
  }

  @override
  Future<List<AppFavoriteFolder>> loadFolders() async => List.of(folders);

  @override
  Future<List<AppFavoriteItem>> loadItems(String folderId) async =>
      contents[folderId]?.values.toList() ?? [];

  @override
  Future<int> addItems(String folderId, List<AppFavoriteItem> incoming) async {
    final saved = contents.putIfAbsent(folderId, () => {});
    final before = saved.length;
    for (final item in incoming) {
      saved.putIfAbsent(item.bvid, () => item);
    }
    return saved.length - before;
  }
}

class _Fixture {
  _Fixture({AppFavoritesService? local})
    : local = local ?? AppFavoritesService();

  final AppFavoritesService local;
  final content = _Content(),
      videos = _Videos(),
      account = _Account(),
      remote = _Remote(),
      learn = LearningListService();
  late final actions = VideoBatchActions(
    learningService: learn,
    videoService: videos,
    appFavoritesService: local,
    accountService: account,
    interactionService: remote,
  );
  Future<void> host(
    WidgetTester t, {
    Size size = const Size(390, 844),
    double scale = 1,
    bool page = true,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final sub = SubscriptionService(
      contentService: content,
      backgroundScheduler: (_, _) async {},
    );
    addTearDown(sub.dispose);
    await t.pumpWidget(
      MaterialApp(
        builder: (c, ch) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: ch!,
        ),
        home: page
            ? CollectionDetailPage(
                collection: const CreatorCollection(
                  id: 1,
                  ownerMid: 8,
                  title: '合集',
                  coverUrl: '',
                  description: '',
                  ownerName: '作者',
                  totalCount: 40,
                  previewVideos: [],
                ),
                publicContentService: content,
                videoService: videos,
                learningListService: learn,
                subscriptionService: sub,
                batchActions: actions,
              )
            : Builder(
                builder: (c) => Scaffold(
                  body: TextButton(
                    onPressed: () => actions.run(
                      c,
                      videos: [
                        lesson(1),
                        lesson(1),
                        lesson(2, ownerName: '另一位作者'),
                      ],
                      ownerName: '作者',
                      destination: VideoSaveDestination.favorites,
                    ),
                    child: const Text('保存两支'),
                  ),
                ),
              ),
      ),
    );
    await t.pumpAndSettle();
  }
}

Finder item(int n) => find.byKey(Key('collection-video-BV$n'));
Finder check(int n) => find.byKey(Key('check-collection-BV$n'));
Future<void> chooseTwo(WidgetTester t) async {
  await t.longPress(item(1));
  await t.pumpAndSettle();
  await t.tap(item(2));
  await t.pumpAndSettle();
  expect(find.text('已选 2'), findsOneWidget);
}

Future<void> chooseDest(WidgetTester t, String dest) async {
  await t.tap(find.byKey(const Key('batch-save-selected')));
  await t.pumpAndSettle();
  final f = find.byKey(ValueKey('save-destination-$dest'));
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('连续选区基于手势起点快照，反向缩回不擦已有勾选', () {
    final s = VideoListSelection()..start('BV4');
    final v = [for (var i = 1; i <= 6; i++) lesson(i)];
    s.range((anchor: 1, previous: 1, current: 1, checked: true), v);
    s.range((anchor: 1, previous: 1, current: 5, checked: true), v);
    s.range((anchor: 1, previous: 5, current: 2, checked: true), v);
    expect(s.ids, {'BV2', 'BV3', 'BV4'});
    s.end();
    expect(s.active, isFalse);
  });
  testWidgets('合集顶部只保留订阅，支持下拉刷新和显式多选', (t) async {
    final x = _Fixture();
    await x.host(t, size: const Size(390, 844));
    expect(find.byTooltip('批量加入学习清单'), findsNothing);
    expect(find.byTooltip('刷新合集'), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('合集'), findsOneWidget);
    expect(find.text('40 支视频'), findsOneWidget);
    expect(x.content.requests, [1]);

    await t.drag(find.byType(AdaptiveTwoColumnList), const Offset(0, 380));
    await t.pumpAndSettle();
    expect(x.content.requests, [1, 1]);

    await t.tap(find.byKey(const Key('select-collection-videos')));
    await t.pumpAndSettle();
    expect(check(1), findsOneWidget);
    expect(find.textContaining('按住勾选框'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('长按不播放、不写；两个正方形目标可达，取消后仍选中，返回只退出选择', (t) async {
    final x = _Fixture();
    await x.host(t, size: const Size(320, 600), scale: 2);
    await chooseTwo(t);
    expect(x.videos.calls, isEmpty);
    await t.tap(find.byKey(const Key('batch-save-selected')));
    await t.pumpAndSettle();
    for (final d in VideoSaveDestination.values) {
      final f = find.byKey(ValueKey('save-destination-${d.name}'));
      await t.ensureVisible(f);
      await t.pumpAndSettle();
      final size = t.getSize(f);
      expect(size.width, closeTo(size.height, .2));
      expect(size.width, greaterThan(110));
      expect(f.hitTestable(), findsOneWidget);
      expect(
        t.getSemantics(f),
        isSemantics(isButton: true, hasTapAction: true),
      );
    }
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('已选 2'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byType(CollectionDetailPage), findsOneWidget);
    expect(find.text('已选 2'), findsNothing);
    expect(x.remote.writes, isEmpty);
    expect(t.takeException(), isNull);
  });
  testWidgets('真实勾选后拖过移动范围、往回缩；普通滚动与分页不移除已有选择', (t) async {
    final x = _Fixture();
    await x.host(t);
    await t.longPress(item(1));
    await t.pumpAndSettle();
    final g = await t.startGesture(t.getCenter(check(2)));
    await t.pump(const Duration(milliseconds: 650));
    await g.moveTo(t.getCenter(check(5)));
    await t.pump();
    expect(find.text('已选 5'), findsOneWidget);
    await g.moveTo(t.getCenter(check(3)));
    await t.pump();
    expect(find.text('已选 3'), findsOneWidget);
    await g.up();
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      item(24),
      550,
      scrollable: find.byType(Scrollable).first,
    );
    await t.pumpAndSettle();
    expect(x.content.requests, contains(2));
    await t.tap(item(24));
    await t.pumpAndSettle();
    expect(find.text('已选 4'), findsOneWidget);
    expect(x.videos.calls, isEmpty);
  });
  testWidgets('停在真实列表底边等待慢页，加载前不越界，追加后不挪手指也能继续勾选', (t) async {
    final x = _Fixture();
    x.content.nextPage = Completer<void>();
    await x.host(t, size: const Size(390, 680));
    await t.longPress(item(1));
    await t.pumpAndSettle();
    final handle = t.getCenter(check(2));
    final bottom = t
        .getRect(find.byKey(const Key('collection-detail-video-list')))
        .bottom;
    final g = await t.startGesture(handle);
    await t.pump(const Duration(milliseconds: 650));
    await t.pump();
    await g.moveTo(Offset(handle.dx, bottom - 2));
    Future<void> advance() async {
      for (var i = 0; i < 170; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    int count() => int.parse(
      t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .singleWhere((s) => s.startsWith('已选 '))
          .substring(3),
    );
    await advance();
    expect(x.content.requests, [1, 2]);
    expect(count(), 18);
    x.content.nextPage!.complete();
    await t.pump();
    await advance();
    expect(count(), greaterThan(18));
    expect(count(), lessThanOrEqualTo(40));
    await g.up();
    await t.pumpAndSettle();
    expect(x.videos.calls, isEmpty);
    expect(t.takeException(), isNull);
  });
  Future<void> jumpToBottom(WidgetTester t) async {
    final controller = t
        .widget<AdaptiveTwoColumnList>(
          find.byKey(const Key('collection-detail-video-list')),
        )
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await t.pumpAndSettle();
  }

  testWidgets('整页 BV 重叠不遮住第3页，先前勾选保持', (t) async {
    final x = _Fixture();
    x.content.overlapThrough = 2;
    await x.host(t);
    await t.longPress(item(1));
    await t.pumpAndSettle();
    await jumpToBottom(t);
    expect(x.content.requests, [1, 2, 3]);
    await t.scrollUntilVisible(
      item(24),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(item(24), findsOneWidget);
    expect(find.text('已选 1'), findsOneWidget);
  });
  testWidgets('连续重复页有上限，显式继续后仍能取得新视频', (t) async {
    final x = _Fixture();
    x.content.overlapThrough = 5;
    await x.host(t);
    await jumpToBottom(t);
    expect(x.content.requests, [1, 2, 3, 4]);
    await jumpToBottom(t);
    expect(x.content.requests, [1, 2, 3, 4]);
    final more = find.byKey(const Key('continue-collection-pages'));
    await t.ensureVisible(more);
    await t.tap(more);
    await t.pumpAndSettle();
    expect(x.content.requests, [1, 2, 3, 4, 5, 6]);
    await t.scrollUntilVisible(
      item(24),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(item(24), findsOneWidget);
  });
  testWidgets('页码停滞不忙等；重试沿用最后可靠页码', (t) async {
    final x = _Fixture();
    x.content.stalls = true;
    await x.host(t);
    await jumpToBottom(t);
    expect(x.content.requests, [1, 2]);
    x.content.stalls = false;
    final more = find.byKey(const Key('continue-collection-pages'));
    await t.ensureVisible(more);
    await t.tap(more);
    await t.pumpAndSettle();
    expect(x.content.requests, [1, 2, 2]);
    await t.scrollUntilVisible(
      item(24),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(item(24), findsOneWidget);
  });
  testWidgets('桌面双列从第二列越过下一行；排序稳定，单击只选择', (t) async {
    final x = _Fixture();
    await x.host(t, size: const Size(1100, 760));
    await t.longPress(item(1));
    await t.pumpAndSettle();
    expect(t.getCenter(check(2)).dx, greaterThan(t.getCenter(check(1)).dx));
    final g = await t.startGesture(t.getCenter(check(2)));
    await t.pump(const Duration(milliseconds: 650));
    await g.moveTo(t.getCenter(check(5)));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('已选 5'), findsOneWidget);
    expect(x.videos.calls, isEmpty);
  });
  testWidgets('加入本机夹两支去重、保留原视频元数据，不读在线详情且成功退出多选', (t) async {
    final x = _Fixture();
    final folder = (await t.runAsync(() => x.local.createFolder('力学')))!;
    await t.runAsync(
      () => x.local.addItem(
        AppFavoriteItem(
          folderId: folder.id,
          bvid: 'BV1',
          title: '不要覆盖',
          coverUrl: '',
          ownerName: '旧作者',
          durationText: '',
          addedAt: DateTime(2023),
        ),
      ),
    );
    await x.host(t);
    await chooseTwo(t);
    await chooseDest(t, 'favorites');
    await t.tap(find.text('力学'));
    await t.pumpAndSettle();
    await t.tap(find.text('加入收藏夹'));
    await t.pump();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await t.pumpAndSettle();
    expect(find.text('已选 2'), findsNothing);
    final saved = (await t.runAsync(() => x.local.loadItems(folder.id)))!;
    expect(saved.map((e) => e.bvid).toSet(), {'BV1', 'BV2'});
    expect(saved.singleWhere((e) => e.bvid == 'BV1').title, '不要覆盖');
    expect(x.videos.calls, isEmpty);
    expect(x.remote.writes, isEmpty);
  });
  testWidgets('本机扫选、取消某一项并在窄屏大字确认', (t) async {
    final x = _Fixture(local: _MemoryFavorites());
    final first = (await t.runAsync(() => x.local.createFolder('先保存')))!;
    final second = (await t.runAsync(() => x.local.createFolder('也保存')))!;
    final skipped = (await t.runAsync(() => x.local.createFolder('不保存')))!;
    await x.host(t, size: const Size(320, 640), scale: 1.7, page: false);
    await t.tap(find.text('保存两支'));
    await t.pumpAndSettle();
    Finder folder(String title) =>
        checkboxIn(find.widgetWithText(DragCheckboxTile, title));
    await sweepCheckboxes(t, folder('先保存'), folder('不保存'));
    expect(find.text('2 支视频 · 已选 3 个'), findsOneWidget);
    await t.tap(find.text('不保存'));
    await t.pumpAndSettle();
    expect(find.text('2 支视频 · 已选 2 个'), findsOneWidget);
    expect(await t.runAsync(() => x.local.loadItems(first.id)), isEmpty);
    await t.tap(find.text('加入收藏夹'));
    await t.pumpAndSettle();
    for (final folder in [first, second]) {
      final saved = (await t.runAsync(() => x.local.loadItems(folder.id)))!;
      expect(
        {for (final item in saved) item.bvid: item.ownerName},
        {'BV1': '作者', 'BV2': '另一位作者'},
      );
    }
    expect(await t.runAsync(() => x.local.loadItems(skipped.id)), isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('批量收藏长列表可一屏看到更多项，滚动不移动底部按钮', (t) async {
    final x = _Fixture(local: _MemoryFavorites());
    for (var index = 1; index <= 14; index++) {
      await x.local.createFolder('收藏夹 $index');
    }
    await x.host(t, page: false);
    await t.tap(find.text('保存两支'));
    await t.pumpAndSettle();

    final list = find.byKey(const Key('batch-favorite-folder-list'));
    expect(t.getSize(list).height, greaterThan(450));
    expect(find.text('收藏夹 8').hitTestable(), findsOneWidget);
    final submit = find.widgetWithText(FilledButton, '加入收藏夹');
    final initialPosition = t.getCenter(submit);
    expect(submit.hitTestable(), findsOneWidget);

    await t.drag(list, const Offset(0, -720));
    await t.pumpAndSettle();
    expect(find.text('收藏夹 14').hitTestable(), findsOneWidget);
    await t.tap(find.text('收藏夹 14'));
    await t.pumpAndSettle();
    expect(t.widget<FilledButton>(submit).onPressed, isNotNull);
    expect(t.getCenter(submit), initialPosition);
    expect(t.takeException(), isNull);
  });

  testWidgets('B站多选按视频与收藏夹跟踪，重试不追加已完成组合', (t) async {
    final x = _Fixture();
    x.remote.existing.add((1001, 1));
    x.remote.failPair = (1002, 2);
    await x.host(t, page: false);
    await t.tap(find.text('保存两支'));
    await t.pumpAndSettle();
    await t.tap(find.text('B 站'));
    await t.pumpAndSettle();
    expect(find.text('不可写入的收藏夹'), findsNothing);
    final first = checkboxIn(find.widgetWithText(DragCheckboxTile, '线上物理'));
    final second = checkboxIn(find.widgetWithText(DragCheckboxTile, '线上笔记'));
    await sweepCheckboxes(t, first, second);
    expect(find.text('2 支视频 · 已选 2 个'), findsOneWidget);
    expect(x.remote.attempts, isEmpty);
    await t.tap(find.text('加入收藏夹'));
    await t.pumpAndSettle();
    expect(x.remote.attempts, [(1001, 1), (1001, 2), (1002, 1), (1002, 2)]);
    expect(x.videos.calls, ['BV1', 'BV2']);
    expect(find.textContaining('新增 2 项、已有 1 项、剩余 1 项'), findsOneWidget);
    await sweepCheckboxes(t, first, second);
    expect(find.text('2 支视频 · 已选 2 个'), findsOneWidget);
    expect(t.widget<Checkbox>(first).onChanged, isNull);
    x.remote.failPair = null;
    await t.tap(find.text('继续剩余项'));
    await t.pumpAndSettle();
    expect(x.remote.attempts, [
      (1001, 1),
      (1001, 2),
      (1002, 1),
      (1002, 2),
      (1002, 2),
    ]);
    expect(x.remote.writes, [1001, 1002, 1002]);
    expect(x.videos.calls, ['BV1', 'BV2', 'BV2']);
    expect(find.textContaining('新增 3 项、已有 1 项'), findsOneWidget);
  });

  testWidgets('新建夹仅为草稿，取消不会产生空文件夹', (t) async {
    final x = _Fixture();
    await x.host(t, page: false);
    await t.tap(find.text('保存两支'));
    await t.pumpAndSettle();
    await t.tap(find.text('新建本机收藏夹'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '草稿夹');
    await t.pumpAndSettle();
    await t.tap(find.text('使用此名称'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(await t.runAsync(x.local.loadFolders), isEmpty);
  });
  testWidgets('学习去向仅取选中的视频并保留多 P 和旧进度；未确认不写', (t) async {
    final x = _Fixture();
    final one = x.videos.model(1);
    await t.runAsync(
      () => x.learn.addBatch([
        LearningPartSelection(
          one,
          one.parts.first,
          position: const Duration(seconds: 38),
        ),
      ]),
    );
    await x.host(t);
    await chooseTwo(t);
    await chooseDest(t, 'learning');
    expect(x.videos.calls, ['BV1', 'BV2']);
    expect(find.text('选择独立视频'), findsNothing);
    await t.tap(find.text('全部 P'));
    await t.pumpAndSettle();
    await t.tap(find.text('确认加入'));
    await t.pumpAndSettle();
    final entries = (await t.runAsync(x.learn.loadEntries))!;
    expect(entries.length, 4);
    expect(
      entries.singleWhere((e) => e.bvid == 'BV1' && e.partCid == 101).position,
      const Duration(seconds: 38),
    );
    expect(find.text('已选 2'), findsNothing);
  });
  testWidgets('B站失败重试只处理剩余；不移除其他夹，不重写已成功项', (t) async {
    final x = _Fixture();
    x.remote.fail = 1002;
    await x.host(t, page: false);
    await t.tap(find.text('保存两支'));
    await t.pumpAndSettle();
    await t.tap(find.text('B 站'));
    await t.pumpAndSettle();
    await t.tap(find.text('线上物理'));
    await t.pumpAndSettle();
    await t.tap(find.text('加入收藏夹'));
    await t.pumpAndSettle();
    expect(x.remote.writes, [1001]);
    expect(find.textContaining('剩余 1 支'), findsOneWidget);
    x.remote.fail = null;
    await t.tap(find.text('继续剩余项'));
    await t.pumpAndSettle();
    expect(x.remote.writes, [1001, 1002]);
    expect(x.videos.calls, ['BV1', 'BV2', 'BV2']);
  });
  testWidgets('B站退出或切号时进行中的详情不能触发迟到写入', (t) async {
    final x = _Fixture();
    x.videos.hold = Completer();
    await x.host(t, page: false);
    await t.tap(find.text('保存两支'));
    await t.pumpAndSettle();
    await t.tap(find.text('B 站'));
    await t.pumpAndSettle();
    await t.tap(find.text('线上物理'));
    await t.pumpAndSettle();
    await t.tap(find.text('加入收藏夹'));
    await t.pump();
    expect(x.videos.calls, ['BV1']);
    x.account.mid = 77;
    CacheLifecycle.accountChanged();
    await t.pump();
    x.videos.hold!.complete(x.videos.model(1));
    await t.pumpAndSettle();
    expect(x.remote.writes, isEmpty);
    expect(find.text('线上物理'), findsNothing);
  });
}
