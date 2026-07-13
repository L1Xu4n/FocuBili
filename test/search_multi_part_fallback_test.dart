import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';

/// 创建一个固定的关键词搜索结果，减少各个搜索组件测试中的重复数据。
VideoSearchResult _searchResult({
  required String bvid,
  required String title,
  String episodeCountText = '',
}) {
  return VideoSearchResult(
    bvid: bvid,
    title: title,
    ownerName: '测试 UP 主',
    duration: const Duration(minutes: 3),
    thumbnailUrl: '',
    publishedAt: DateTime(2026, 7, 14),
    playCount: 1,
    danmakuCount: 1,
    episodeCountText: episodeCountText,
  );
}

/// 创建具有指定分P数量的视频详情，用于验证搜索页从详情补充分集角标。
VideoPreview _videoPreview(String bvid, int partCount) {
  final List<VideoPart> parts = List<VideoPart>.generate(
    partCount,
    (int index) => VideoPart(
      pageNumber: index + 1,
      cid: 1000 + index,
      title: '第${index + 1}P',
      duration: const Duration(minutes: 3),
    ),
  );
  return VideoPreview(
    bvid: bvid,
    cid: parts.first.cid,
    title: '测试视频',
    ownerName: '测试 UP 主',
    duration: parts.first.duration,
    parts: parts,
  );
}

/// 向搜索框输入关键词并模拟键盘的“搜索”确认操作。
Future<void> _submitKeywordSearch(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byType(TextField), keyword);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump();
}

/// 为搜索页提供可记录详情请求、失败和延迟响应的本地服务替身。
class _SearchFallbackService implements BilibiliService {
  /// 创建一组固定搜索结果，并可为各 BV 号配置详情、失败或手动完成的请求。
  _SearchFallbackService({
    required this.results,
    Map<String, VideoPreview>? previews,
    Set<String>? failingBvids,
    Map<String, Completer<VideoPreview>>? pendingLookups,
  })  : _previews = previews ?? <String, VideoPreview>{},
        _failingBvids = failingBvids ?? <String>{},
        _pendingLookups = pendingLookups ?? <String, Completer<VideoPreview>>{};

  final List<VideoSearchResult> results;
  final Map<String, VideoPreview> _previews;
  final Set<String> _failingBvids;
  final Map<String, Completer<VideoPreview>> _pendingLookups;
  final List<String> lookupRequests = <String>[];
  int activeLookups = 0;
  int maximumConcurrentLookups = 0;

  /// 返回固定的一页搜索结果，让测试只关注页面的分集补查行为。
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    return VideoSearchPage(results: results, page: page, totalPages: page);
  }

  /// 记录详情请求，并按配置返回成功、失败或等待测试手动完成的 Future。
  @override
  Future<VideoPreview> lookupVideo(String input) {
    lookupRequests.add(input);
    activeLookups += 1;
    if (activeLookups > maximumConcurrentLookups) {
      maximumConcurrentLookups = activeLookups;
    }
    final Completer<VideoPreview>? pending = _pendingLookups[input];
    final Future<VideoPreview> response;
    if (pending != null) {
      response = pending.future;
    } else if (_failingBvids.contains(input)) {
      response = Future<VideoPreview>.error(
        const BilibiliLookupException('测试用的详情补查失败。'),
      );
    } else {
      final VideoPreview? preview = _previews[input];
      response = preview == null
          ? Future<VideoPreview>.error(
              const BilibiliLookupException('测试没有配置该视频详情。'),
            )
          : Future<VideoPreview>.value(preview);
    }
    return response.whenComplete(() => activeLookups -= 1);
  }

  /// 测试不关心候选词，因此始终返回空列表以避免额外异步干扰。
  @override
  Future<List<String>> suggestKeywords(String input) async {
    return const <String>[];
  }
}

/// 验证搜索卡片的分P文字能在不影响原始搜索结果的前提下安全补全。
void main() {
  /// 验证服务端角标优先、详情补查、单P隐藏与失败去重都符合预期。
  testWidgets('搜索结果只为缺失分集文字的卡片补查一次详情', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const String serverBvid = 'BV1GJ411x7h7';
    const String multiPartBvid = 'BV1GJ411x7h8';
    const String singlePartBvid = 'BV1GJ411x7h9';
    const String failureBvid = 'BV1GJ411x7hA';
    final _SearchFallbackService service = _SearchFallbackService(
      results: <VideoSearchResult>[
        _searchResult(
          bvid: serverBvid,
          title: '服务端已有分集文字',
          episodeCountText: '全12集',
        ),
        _searchResult(bvid: multiPartBvid, title: '需要补查的多P视频'),
        _searchResult(bvid: singlePartBvid, title: '单P视频'),
        _searchResult(bvid: failureBvid, title: '详情失败的视频'),
      ],
      previews: <String, VideoPreview>{
        multiPartBvid: _videoPreview(multiPartBvid, 3),
        singlePartBvid: _videoPreview(singlePartBvid, 1),
      },
      failingBvids: <String>{failureBvid},
    );

    await tester.pumpWidget(
      MaterialApp(home: SearchPage(service: service)),
    );
    await _submitKeywordSearch(tester, '测试关键词');
    await tester.pumpAndSettle();

    expect(find.text('全12集'), findsOneWidget);
    expect(find.text('共 3 P'), findsOneWidget);
    expect(find.text('共 1 P'), findsNothing);
    expect(
      service.lookupRequests,
      containsAllInOrder(<String>[multiPartBvid, singlePartBvid, failureBvid]),
    );
    expect(service.lookupRequests, isNot(contains(serverBvid)));
    expect(service.lookupRequests.where((String bvid) => bvid == failureBvid),
        hasLength(1));
    expect(
      find.byKey(const Key('search-BV1GJ411x7hA')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await _submitKeywordSearch(tester, '再次搜索');
    await tester.pumpAndSettle();
    expect(service.lookupRequests.where((String bvid) => bvid == multiPartBvid),
        hasLength(1));
    expect(service.lookupRequests.where((String bvid) => bvid == failureBvid),
        hasLength(1));
  });

  /// 验证多个可见卡片的详情补查最多同时运行两条请求。
  testWidgets('搜索分集补查最多同时发起两条详情请求', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const String firstBvid = 'BV1GJ411x7hB';
    const String secondBvid = 'BV1GJ411x7hC';
    const String thirdBvid = 'BV1GJ411x7hD';
    final Map<String, Completer<VideoPreview>> pendingLookups =
        <String, Completer<VideoPreview>>{
      firstBvid: Completer<VideoPreview>(),
      secondBvid: Completer<VideoPreview>(),
      thirdBvid: Completer<VideoPreview>(),
    };
    final _SearchFallbackService service = _SearchFallbackService(
      results: <VideoSearchResult>[
        _searchResult(bvid: firstBvid, title: '第一条多P视频'),
        _searchResult(bvid: secondBvid, title: '第二条多P视频'),
        _searchResult(bvid: thirdBvid, title: '第三条多P视频'),
      ],
      pendingLookups: pendingLookups,
    );

    await tester.pumpWidget(
      MaterialApp(home: SearchPage(service: service)),
    );
    await _submitKeywordSearch(tester, '并发测试');
    await tester.pump();

    expect(service.lookupRequests, hasLength(2));
    expect(service.maximumConcurrentLookups, 2);

    pendingLookups[firstBvid]!.complete(_videoPreview(firstBvid, 2));
    await tester.pump();
    await tester.pump();
    expect(service.lookupRequests, hasLength(3));
    expect(service.maximumConcurrentLookups, 2);

    pendingLookups[secondBvid]!.complete(_videoPreview(secondBvid, 2));
    pendingLookups[thirdBvid]!.complete(_videoPreview(thirdBvid, 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
