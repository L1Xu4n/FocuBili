import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/favorite_videos_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _bvid(int id) => 'BV${id.toString().padLeft(10, '0')}';

class _Videos implements BilibiliService {
  final lookups = <String>[];

  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async => VideoSearchPage(
    results: [
      for (final id in keyword == 'single' ? [1] : [1, 2, 3])
        VideoSearchResult(
          bvid: _bvid(id),
          title: '结果 $id',
          ownerName: '作者 $id',
          duration: const Duration(minutes: 2),
          thumbnailUrl: '',
          publishedAt: null,
          playCount: 1,
          danmakuCount: 2,
          episodeCountText: '1 P',
        ),
    ],
    page: page,
    totalPages: 1,
  );

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookups.add(input);
    final id = int.parse(input.substring(2));
    return VideoPreview(
      bvid: input,
      cid: id,
      title: '详情 $id',
      ownerName: '作者 $id',
      parts: [
        VideoPart(
          pageNumber: 1,
          cid: id,
          title: '分 P $id',
          duration: const Duration(minutes: 2),
        ),
      ],
    );
  }

  @override
  Future<List<String>> suggestKeywords(String input) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Favorites extends BilibiliAccountDataService {
  final pages = <int>[];

  @override
  Future<AccountDataPage<FavoriteVideo>> loadFavoriteVideos(
    int mediaId, {
    int page = 1,
  }) async {
    pages.add(page);
    return AccountDataPage.success(
      items: [
        for (final id in page == 1 ? [1, 2, 3] : [4])
          FavoriteVideo(
            bvid: _bvid(id),
            title: '收藏 $id',
            coverUrl: '',
            ownerName: '作者 $id',
            duration: const Duration(minutes: 2),
            partCount: 1,
            favoritedAt: null,
            playCount: 0,
            danmakuCount: 0,
            isAvailable: id != 2,
          ),
      ],
      page: page,
      hasMore: page == 1,
    );
  }
}

Future<void> _sweep(WidgetTester tester, Finder from, Finder to) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
  await gesture.moveTo(tester.getCenter(to));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder _checkbox(String prefix, int id) => find.descendant(
  of: find.byKey(Key('$prefix-${_bvid(id)}')),
  matching: find.byType(Checkbox),
);

Future<void> _submit(WidgetTester tester, String input) async {
  await tester.enterText(find.byKey(const Key('search-input-field')), input);
  await tester.tap(find.byKey(const Key('search-submit-button')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('关键词结果支持滑选、滑动取消及保存精确的 BV', (tester) async {
    final service = _Videos();
    final learning = LearningListService();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(service: service, learningListService: learning),
      ),
    );
    await _submit(tester, 'single');
    await tester.longPress(find.text('结果 1'));
    expect(find.byTooltip('多选视频'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    service.lookups.clear();

    await _submit(tester, 'multiple');
    await tester.longPress(find.text('结果 1'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 支视频'), findsOneWidget);
    Finder check(int id) => _checkbox('search', id);
    await _sweep(tester, check(2), check(3));
    expect(find.text('已选 3 支视频'), findsOneWidget);
    await _sweep(tester, check(2), check(3));
    expect(find.text('已选 1 支视频'), findsOneWidget);
    await tester.tap(find.text('结果 3'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加到'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-destination-favorites')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-destination-learning')));
    await tester.pumpAndSettle();
    expect(service.lookups, unorderedEquals([_bvid(1), _bvid(3)]));
    await tester.tap(find.text('确认加入'));
    await tester.pumpAndSettle();
    expect(
      (await learning.loadEntries()).map((entry) => entry.bvid),
      unorderedEquals([_bvid(1), _bvid(3)]),
    );
    expect(find.byType(Checkbox), findsNothing);

    await _submit(tester, _bvid(1));
    await tester.longPress(find.text('详情 1'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('多选视频'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('B站收藏仅选择可用条目，分页保留草稿且切换账号停止保存', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _Favorites();
    final videos = _Videos();
    final learning = LearningListService();
    await tester.pumpWidget(
      MaterialApp(
        home: FavoriteVideosPage(
          folder: const FavoriteFolder(
            mediaId: 42,
            title: '公开资料',
            coverUrl: '',
            mediaCount: 4,
            isAvailable: true,
          ),
          accountDataService: source,
          bilibiliService: videos,
          learningListService: learning,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('收藏 2'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);

    await tester.longPress(find.text('收藏 1'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 支视频'), findsOneWidget);
    expect(_checkbox('favorite-video', 2), findsNothing);
    await tester.tap(find.byKey(const Key('favorite-videos-load-more')));
    await tester.pumpAndSettle();
    expect(source.pages, [1, 2]);
    expect(find.text('已选 1 支视频'), findsOneWidget);
    await _sweep(
      tester,
      _checkbox('favorite-video', 3),
      _checkbox('favorite-video', 4),
    );
    expect(find.text('已选 3 支视频'), findsOneWidget);

    // The chooser is a draft; an account revision invalidates the source
    // before the user can submit these IDs to a destination.
    await tester.tap(find.text('添加到'));
    await tester.pumpAndSettle();
    CacheLifecycle.accountChanged();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-destination-learning')));
    await tester.pumpAndSettle();
    expect(find.text('账号已变化，请返回后重新打开收藏夹。'), findsOneWidget);
    expect(videos.lookups, isEmpty);
    expect(await learning.loadEntries(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
