import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/search_content_filter.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/search_content_filter_service.dart';

/// Generates metadata-rich results without depending on a live search endpoint.
VideoSearchResult result(
  String title, {
  int? category,
  int plays = 100,
  String bvid = 'BV1GJ411x7h7',
}) => VideoSearchResult(
  bvid: bvid,
  title: title,
  ownerName: 'UP',
  duration: const Duration(minutes: 1),
  thumbnailUrl: '',
  publishedAt: null,
  playCount: plays,
  danmakuCount: 0,
  episodeCountText: '1',
  categoryId: category,
);

/// Includes multiple fully filtered pages and an actual empty page before a match.
class FilterPages implements BilibiliService {
  final requested = <int>[];
  bool failOnce = false;

  /// Returns finite ascending pages so viewport-filling must continue beyond three.
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    requested.add(page);
    if (page == 2 && failOnce) {
      failOnce = false;
      throw StateError('network');
    }
    return VideoSearchPage(
      page: page,
      totalPages: 6,
      results: page <= 4
          ? List.generate(
              20,
              (index) => result(
                '娱乐八卦 $page $index',
                bvid:
                    'BV1GJ411${page.toString().padLeft(2, '0')}${index.toString().padLeft(2, '0')}',
              ),
            )
          : page == 5
          ? []
          : [result('编程入门')],
    );
  }

  /// Keeps typing tests independent of suggestion requests.
  @override
  Future<List<String>> suggestKeywords(String input) async => [];

  /// Rejects unexpected detail requests; episode counts are supplied by fixtures.
  @override
  Future<VideoPreview> lookupVideo(String input) async =>
      throw StateError('Unexpected detail request');
}

/// Covers semantics, saved custom inputs, finite auto-pagination, retries and mouse drag.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'learning rules preserve tutorials and unknown metadata, but remove probable entertainment',
    () {
      const filter = SearchContentFilter();
      expect(filter.includes(result('游戏开发教程', category: 4)), isTrue);
      expect(filter.includes(result('钢琴乐理教学', category: 3)), isTrue);
      expect(filter.includes(result('课程资料没有分类')), isTrue);
      expect(filter.includes(result('未知标题')), isTrue);
      expect(filter.includes(result('娱乐八卦')), isFalse);
      expect(filter.includes(result('游戏实况', category: 4)), isFalse);
      expect(
        const SearchContentFilter(learningOnly: false).includes(result('娱乐八卦')),
        isTrue,
      );
      expect(
        const SearchContentFilter(
          minimumPlayCount: 12345,
        ).includes(result('编程教程', plays: 12344)),
        isFalse,
      );
    },
  );

  testWidgets(
    'empty and filtered pages auto-load until the viewport has results or ends',
    (tester) async {
      final service = FilterPages();
      await tester.pumpWidget(MaterialApp(home: SearchPage(service: service)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-input-field')), '编程');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(service.requested, [1, 2, 3, 4, 5, 6]);
      expect(find.text('编程入门'), findsOneWidget);
      expect(find.textContaining('已过滤 80 条可能与学习无关'), findsOneWidget);
      expect(find.text('已经到底了'), findsOneWidget);
    },
  );

  testWidgets(
    'automatic pagination stops on failure and exposes an explicit retry',
    (tester) async {
      final service = FilterPages()..failOnce = true;
      await tester.pumpWidget(MaterialApp(home: SearchPage(service: service)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-input-field')), '编程');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(service.requested, [1, 2]);
      await tester.tap(find.text('重试加载'));
      await tester.pumpAndSettle();
      expect(service.requested, [1, 2, 2, 3, 4, 5, 6]);
      expect(find.text('编程入门'), findsOneWidget);
    },
  );

  testWidgets(
    'search sheet saves exact custom number and cancel does not change saved filters',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: SearchPage(service: FilterPages())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('search-learning-only')),
            )
            .value,
        isTrue,
      );
      await tester.enterText(
        find.byKey(const Key('search-play-count-input')),
        '12345',
      );
      await tester.ensureVisible(find.text('应用筛选'));
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect(
        (await const SearchContentFilterService().load()).minimumPlayCount,
        12345,
      );
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-play-count-input')),
        '99999',
      );
      await tester.tap(find.byKey(const Key('close-search-filter')));
      await tester.pumpAndSettle();
      expect(
        (await const SearchContentFilterService().load()).minimumPlayCount,
        12345,
      );
    },
  );

  /// 小屏仍保留顶部空隙，滚动与键盘不会带走关闭按钮和底部操作。
  testWidgets('筛选面板滚动和键盘弹出后仍可快捷关闭', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(home: SearchPage(service: FilterPages())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    final close = find.byKey(const Key('close-search-filter'));
    final headerRect = tester.getRect(close);
    expect(
      tester.getRect(find.byKey(const Key('search-filter-sheet'))).top,
      greaterThan(56),
    );
    expect(find.text('应用筛选').hitTestable(), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('search-filter-scroll')),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(close), headerRect);
    expect(find.text('应用筛选').hitTestable(), findsOneWidget);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-filter-sheet')), findsNothing);

    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-play-count-input')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    expect(tester.getRect(close).top, greaterThan(24));
    expect(tester.getRect(find.text('应用筛选')).bottom, lessThanOrEqualTo(380));
    expect(close.hitTestable(), findsOneWidget);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-filter-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop mouse can drag horizontal search quick filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: SearchPage(service: FilterPages())),
    );
    await tester.pumpAndSettle();
    final strip = find
        .byWidgetPredicate(
          (widget) =>
              widget is ListView && widget.scrollDirection == Axis.horizontal,
        )
        .first;
    final state = tester.state<ScrollableState>(
      find.descendant(of: strip, matching: find.byType(Scrollable)).first,
    );
    expect(state.position.pixels, 0);
    await tester.drag(
      strip,
      const Offset(-220, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(state.position.pixels, greaterThan(0));
  });
}
