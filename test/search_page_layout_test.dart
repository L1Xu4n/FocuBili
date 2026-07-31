import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/learning_list_service.dart';

/// 为搜索页布局测试提供可记录请求的固定视频服务，避免测试访问真实网络。
class _SearchPageTestService implements BilibiliService {
  /// 创建带固定候选词、搜索结果和视频详情的本地服务替身。
  _SearchPageTestService({
    required this.suggestions,
    required this.results,
    required this.video,
  });

  final List<String> suggestions;
  final List<VideoSearchResult> results;
  final VideoPreview video;
  final List<String> lookupRequests = <String>[];
  final List<String> searchRequests = <String>[];

  /// 记录详情查询并返回测试准备好的完整视频。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookupRequests.add(input);
    return video;
  }

  /// 记录搜索关键词并返回测试准备好的一页结果。
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    searchRequests.add(keyword);
    return VideoSearchPage(results: results, page: page, totalPages: page);
  }

  /// 返回固定候选词，让测试可以检查候选布局和前缀高亮。
  @override
  Future<List<String>> suggestKeywords(String input) async {
    return suggestions;
  }
}

/// 创建搜索结果和学习清单共同使用的完整视频资料。
VideoPreview _createVideo(String bvid) {
  return VideoPreview(
    bvid: bvid,
    cid: 778899,
    title: '星球研究所测试视频',
    ownerName: '星球研究所',
    duration: const Duration(minutes: 15, seconds: 22),
    parts: const <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 778899,
        title: '第一节',
        duration: Duration(minutes: 15, seconds: 22),
      ),
    ],
  );
}

/// 创建无需额外分P补查的搜索结果，避免详情请求干扰菜单断言。
VideoSearchResult _createSearchResult(String bvid) {
  return VideoSearchResult(
    bvid: bvid,
    title: '景德镇，你怎么才申遗成功啊？',
    ownerName: '星球研究所',
    duration: const Duration(minutes: 15, seconds: 22),
    thumbnailUrl: '',
    publishedAt: DateTime(2026, 7, 25),
    playCount: 563000,
    danmakuCount: 1692,
    episodeCountText: '全1集',
  );
}

/// 在 RichText 的嵌套片段中寻找指定文字，避免主题自动添加的外层样式影响断言。
TextSpan _findTextSpan(TextSpan root, String text) {
  if (root.text == text) {
    return root;
  }
  for (final InlineSpan child in root.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) {
      try {
        return _findTextSpan(child, text);
      } on StateError {
        // 当前分支没有目标文字时继续检查下一个片段。
      }
    }
  }
  throw StateError('没有找到文字片段：$text');
}

/// 在固定手机尺寸中打开搜索页，并等待本地历史和学习清单完成初始化。
Future<void> _pumpSearchPage(
  WidgetTester tester, {
  required BilibiliService service,
  LearningListService? learningListService,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: SearchPage(
        service: service,
        learningListService: learningListService,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 注册搜索候选、历史换行、模式切换和更多菜单的布局回归测试。
void main() {
  /// 验证候选保持扁平、位于换行历史上方，并突出用户已输入的前缀。
  testWidgets('搜索候选高亮前缀并显示在自动换行的历史上方', (WidgetTester tester) async {
    const String firstHistory = '第一个非常非常长的搜索历史记录关键词';
    const String secondHistory = '第二个非常非常长的搜索历史记录关键词';
    SharedPreferences.setMockInitialValues(<String, Object>{
      'focubili_search_history': <String>[firstHistory, secondHistory],
    });
    final _SearchPageTestService service = _SearchPageTestService(
      suggestions: const <String>['星球动画', '星球研究所'],
      results: const <VideoSearchResult>[],
      video: _createVideo('BV1GJ411x7h7'),
    );
    await _pumpSearchPage(tester, service: service);

    await tester.enterText(find.byKey(const Key('search-input-field')), '星球');
    await tester.pump(const Duration(milliseconds: 351));
    await tester.pump();

    final Finder firstSuggestion = find.byKey(
      const ValueKey<String>('search-suggestion-0-星球动画'),
    );
    final Finder secondSuggestion = find.byKey(
      const ValueKey<String>('search-suggestion-1-星球研究所'),
    );
    final Finder historySection = find.byKey(
      const Key('search-history-section'),
    );
    expect(firstSuggestion, findsOneWidget);
    expect(secondSuggestion, findsOneWidget);
    expect(historySection, findsOneWidget);
    expect(
      find.ancestor(of: firstSuggestion, matching: find.byType(Card)),
      findsNothing,
    );
    expect(
      tester.getBottomRight(secondSuggestion).dy,
      lessThan(tester.getTopLeft(historySection).dy),
    );

    final RichText suggestionText = tester.widget<RichText>(
      find
          .descendant(of: firstSuggestion, matching: find.byType(RichText))
          .first,
    );
    final TextSpan suggestionSpan = suggestionText.text as TextSpan;
    final TextSpan highlightedSpan = _findTextSpan(suggestionSpan, '星球');
    final Color primaryColor = Theme.of(
      tester.element(firstSuggestion),
    ).colorScheme.primary;
    expect(highlightedSpan.text, '星球');
    expect(highlightedSpan.style?.color, primaryColor);
    expect(highlightedSpan.style?.fontWeight, FontWeight.w700);

    final Finder firstHistoryChip = find.byKey(
      const ValueKey<String>('search-history-$firstHistory'),
    );
    final Finder secondHistoryChip = find.byKey(
      const ValueKey<String>('search-history-$secondHistory'),
    );
    expect(firstHistoryChip, findsOneWidget);
    expect(secondHistoryChip, findsOneWidget);
    expect(
      tester.getTopLeft(secondHistoryChip).dy,
      greaterThan(tester.getTopLeft(firstHistoryChip).dy),
    );

    await tester.tap(find.text('用户'));
    await tester.pump();
    final TextField userInput = tester.widget<TextField>(
      find.byKey(const Key('search-input-field')),
    );
    expect(userInput.decoration?.hintText, '搜索用户名');
    expect(firstSuggestion, findsNothing);
    expect(find.byKey(const Key('search-mode-selector')), findsOneWidget);

    await tester.tap(find.text('视频'));
    await tester.pump();
    final TextField videoInput = tester.widget<TextField>(
      find.byKey(const Key('search-input-field')),
    );
    expect(videoInput.decoration?.hintText, '搜索关键词、BV 号或视频链接');
    expect(find.byKey(const Key('search-back-button')), findsNothing);
    expect(videoInput.decoration?.filled, isTrue);
    expect(
      videoInput.decoration?.fillColor,
      Theme.of(tester.element(find.byType(SearchPage))).scaffoldBackgroundColor,
    );
    expect(tester.takeException(), isNull);
  });

  /// 验证清空搜索历史必须二次确认，取消时不会误删本机记录。
  testWidgets('清空搜索历史先确认且取消不会删除', (WidgetTester tester) async {
    const String history = '需要保留的搜索记录';
    SharedPreferences.setMockInitialValues(<String, Object>{
      'focubili_search_history': <String>[history],
    });
    final _SearchPageTestService service = _SearchPageTestService(
      suggestions: const <String>[],
      results: const <VideoSearchResult>[],
      video: _createVideo('BV1GJ411x7h7'),
    );
    await _pumpSearchPage(tester, service: service);

    await tester.tap(find.byKey(const Key('search-history-clear-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('clear-search-history-dialog')),
      findsOneWidget,
    );
    expect(find.text('确定清除全部搜索记录吗？此操作无法撤销。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-clear-search-history')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('search-history-$history')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('search-history-clear-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-clear-search-history')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('search-history-$history')),
      findsNothing,
    );
  });

  /// 验证视频行只在三点菜单中提供学习清单动作，并在再次选择时询问取消。
  testWidgets('视频结果通过更多菜单加入学习清单并可询问取消', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    const String bvid = 'BV1GJ411x7h8';
    final _SearchPageTestService service = _SearchPageTestService(
      suggestions: const <String>[],
      results: <VideoSearchResult>[_createSearchResult(bvid)],
      video: _createVideo(bvid),
    );
    await _pumpSearchPage(
      tester,
      service: service,
      learningListService: learningListService,
    );

    await tester.enterText(find.byKey(const Key('search-input-field')), '景德镇');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-$bvid')), findsOneWidget);
    expect(find.text('加入学习清单'), findsNothing);
    expect(service.lookupRequests, isEmpty);

    await tester.tap(find.byKey(const Key('more-search-$bvid')));
    await tester.pumpAndSettle();
    expect(find.text('加入学习清单'), findsOneWidget);
    expect(service.lookupRequests, isEmpty);

    await tester.tap(find.byKey(const Key('add-learning-search-$bvid')));
    await tester.pumpAndSettle();
    expect(service.lookupRequests, <String>[bvid]);
    expect((await learningListService.loadEntries()).single.bvid, bvid);

    await tester.tap(find.byKey(const Key('more-search-$bvid')));
    await tester.pumpAndSettle();
    expect(find.text('取消加入学习清单'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-learning-search-$bvid')));
    await tester.pumpAndSettle();
    expect(find.text('取消加入学习清单？'), findsOneWidget);
    expect(find.text('保留'), findsOneWidget);
    expect(find.text('取消加入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
