import 'dart:async';
import 'dart:convert';

import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/multi_category_video_search.dart';
import 'package:flutter_test/flutter_test.dart';

const _emptyJson = '{"code":0,"data":{"page":1,"numPages":1,"result":[]}}';

VideoSearchResult _row(
  int id, {
  int plays = 0,
  int danmaku = 0,
  int? favorites,
  int? year,
}) => VideoSearchResult(
  bvid: 'BV${id.toString().padLeft(10, '0')}',
  title: 'video-$id',
  ownerName: 'owner',
  duration: const Duration(seconds: 60),
  thumbnailUrl: '',
  publishedAt: year == null ? null : DateTime.utc(year),
  playCount: plays,
  danmakuCount: danmaku,
  favoriteCount: favorites,
  episodeCountText: '共 2 P',
);

VideoSearchPage _page(int index, int total, List<VideoSearchResult> rows) =>
    VideoSearchPage(results: rows, page: index, totalPages: total);

class _Stub implements BilibiliService {
  _Stub(this.handler);
  final FutureOr<VideoSearchPage> Function(int id, int page) handler;
  final calls = <(int, int)>[];

  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    expect(keyword, 'Flutter');
    final id = filter.categoryId!;
    calls.add((id, page));
    return handler(id, page);
  }

  @override
  Future<VideoPreview> lookupVideo(String input) =>
      throw StateError('No detail requests for merge');

  @override
  Future<List<String>> suggestKeywords(String input) =>
      throw UnimplementedError();
}

Iterable<String> _titles(MultiCategoryVideoSearch search) =>
    search.results.map((row) => row.title);

MultiCategoryVideoSearch _search(
  BilibiliService service, {
  MultiCategorySearchPool? pool,
  List<int> ids = const [188, 36],
  VideoSearchOrder order = VideoSearchOrder.relevance,
}) => MultiCategoryVideoSearch(
  service: service,
  pool: pool ?? MultiCategorySearchPool(),
  keyword: 'Flutter',
  filter: VideoSearchFilter(
    order: order,
    publishedRange: VideoPublishedRange.lastDay,
    durationRange: VideoDurationRange.tenToThirtyMinutes,
  ),
  categoryIds: ids,
);

void main() {
  test(
    'uses scalar tids once per selected category and no unfiltered request',
    () async {
      final requests = <Uri>[];
      final service = BilibiliVideoInfoService(
        requestJson: (uri) async {
          requests.add(uri);
          return _emptyJson;
        },
      );
      final search = _search(service);
      await search.loadNext();
      expect(requests.map((uri) => uri.queryParameters['tids']), ['36', '188']);
      for (final uri in requests) {
        expect(uri.host, 'api.bilibili.com');
        expect(uri.path, '/x/web-interface/wbi/search/type');
        expect(uri.queryParameters['search_type'], 'video');
        expect(uri.queryParameters['keyword'], 'Flutter');
        expect(uri.queryParameters['order'], 'totalrank');
        expect(uri.queryParameters['page'], '1');
        expect(uri.queryParameters['duration'], '2');
        expect(uri.queryParameters['pubtime_begin_s'], isNotNull);
        expect(uri.queryParameters['pubtime_end_s'], isNotNull);
      }
      expect(search.hasNext, isFalse);
    },
  );

  test(
    'failure retains peers; retry resumes only the failing category and page',
    () async {
      var first = true;
      final service = _Stub((id, page) {
        if (id == 36 && page == 2 && first) {
          first = false;
          throw StateError('offline');
        }
        return switch ((id, page)) {
          (36, 1) => _page(1, 2, [_row(1), _row(2)]),
          (188, 1) => _page(1, 3, [_row(3), _row(1)]),
          (36, 2) => _page(2, 2, [_row(2), _row(4)]),
          (188, 2) => _page(2, 3, [_row(5)]),
          (188, 3) => _page(3, 3, [_row(6)]),
          _ => throw StateError('unexpected page'),
        };
      });
      final search = _search(service);
      await search.loadNext();
      expect(_titles(search), ['video-1', 'video-3', 'video-2']);
      await search.loadNext();
      expect(search.failedCategoryIds, {36});
      expect(search.hasNext, isTrue);
      expect(_titles(search), ['video-1', 'video-3', 'video-2', 'video-5']);
      await search.loadNext();
      expect(search.hasNext, isFalse);
      await search.retryFailures();
      expect(search.failedCategoryIds, isEmpty);
      expect(search.hasNext, isFalse);
      expect(_titles(search), [
        'video-1',
        'video-3',
        'video-2',
        'video-5',
        'video-4',
        'video-6',
      ]);
      expect(service.calls, [
        (36, 1),
        (188, 1),
        (36, 2),
        (188, 2),
        (188, 3),
        (36, 2),
      ]);
    },
  );

  test('out-of-order pages cannot skip a category cursor', () async {
    final service = _Stub(
      (id, page) => _page(id == 36 ? page + 1 : page, 3, [_row(id)]),
    );
    final search = _search(service);
    await search.loadNext();
    expect(search.failedCategoryIds, {36});
    expect(_titles(search), ['video-188']);
    await search.retryFailures();
    expect(service.calls, [(36, 1), (188, 1), (36, 1)]);
    expect(search.failedCategoryIds, {36});
  });

  test(
    'pool caps active requests; closing retires queued and late old work',
    () async {
      final inflight = <int, Completer<VideoSearchPage>>{};
      final service = _Stub((id, _) => (inflight[id] = Completer()).future);
      final pool = MultiCategorySearchPool();
      final old = _search(service, pool: pool, ids: [1, 3, 4, 36, 188]);
      final oldLoading = old.loadNext();
      final overlappingCall = old.loadNext();
      expect(service.calls, [(1, 1), (3, 1), (4, 1)]);
      old.close();

      final fresh = _search(service, pool: pool, ids: [5, 13]);
      final freshLoading = fresh.loadNext();
      expect(service.calls, [(1, 1), (3, 1), (4, 1)]);
      inflight[4]!.complete(_page(1, 1, [_row(44)]));
      await Future<void>.delayed(Duration.zero);
      expect(service.calls, [(1, 1), (3, 1), (4, 1), (5, 1)]);
      inflight[3]!.complete(_page(1, 1, [_row(33)]));
      await Future<void>.delayed(Duration.zero);
      expect(service.calls, [(1, 1), (3, 1), (4, 1), (5, 1), (13, 1)]);
      inflight[1]!.complete(_page(1, 1, [_row(11)]));
      inflight[13]!.complete(_page(1, 1, [_row(13)]));
      inflight[5]!.complete(_page(1, 1, [_row(5)]));
      await Future.wait([oldLoading, overlappingCall, freshLoading]);
      expect(old.results, isEmpty);
      expect(_titles(fresh), ['video-5', 'video-13']);
    },
  );

  test(
    'combines local metrics, with stable per-category positions as ties',
    () async {
      final service = _Stub(
        (id, _) => id == 36
            ? _page(1, 1, [
                _row(1, plays: 8, favorites: 0, year: 2024),
                _row(2, plays: 20, danmaku: 1, year: 2025),
              ])
            : _page(1, 1, [
                _row(3, plays: 20, danmaku: 5, favorites: 1),
                _row(4, plays: 5, danmaku: 2),
              ]),
      );
      final orders = {
        VideoSearchOrder.relevance: [
          'video-1',
          'video-3',
          'video-2',
          'video-4',
        ],
        VideoSearchOrder.mostPlayed: [
          'video-3',
          'video-2',
          'video-1',
          'video-4',
        ],
        VideoSearchOrder.newest: ['video-2', 'video-1', 'video-3', 'video-4'],
        VideoSearchOrder.mostDanmaku: [
          'video-3',
          'video-4',
          'video-2',
          'video-1',
        ],
        VideoSearchOrder.mostFavorited: [
          'video-3',
          'video-1',
          'video-2',
          'video-4',
        ],
      };
      for (final entry in orders.entries) {
        final search = _search(service, order: entry.key);
        await search.loadNext();
        expect(_titles(search), entry.value, reason: entry.key.name);
      }
    },
  );

  test('known zero favorites and unknown favorites remain distinct', () async {
    final service = BilibiliVideoInfoService(
      requestJson: (uri) async {
        return jsonEncode({
          'code': 0,
          'data': {
            'page': 1,
            'numPages': 1,
            'result': [
              {'bvid': 'BV1000000001', 'favorites': '0'},
              {'bvid': 'BV1000000002', 'favorite': 18},
              {'bvid': 'BV1000000003'},
              {'bvid': 'BV1000000004', 'favorites': '12万'},
            ],
          },
        });
      },
    );
    final page = await service.searchVideos('Flutter');
    expect(page.results.map((row) => row.favoriteCount), [0, 18, null, null]);
  });
}
