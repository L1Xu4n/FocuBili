import 'dart:async';
import 'dart:collection';

import '../models/video_preview.dart';
import 'bilibili_service.dart';

/// A page owns one pool, so obsolete searches do not increase parallel fan-out.
class MultiCategorySearchPool {
  static const maxConcurrentRequests = 3;
  int _running = 0;
  final _queue = Queue<Future<void> Function()>();

  Future<void> run(Future<void> Function() task) {
    final done = Completer<void>();
    _queue.add(() async {
      try {
        await task();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    _drain();
    return done.future;
  }

  void _drain() {
    while (_running < maxConcurrentRequests && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _running++;
      unawaited(
        task().whenComplete(() {
          _running--;
          _drain();
        }),
      );
    }
  }
}

/// Each chosen category uses its own real server-side search and page cursor.
/// No unfiltered request or metadata lookups are needed to combine the results.
class MultiCategoryVideoSearch {
  MultiCategoryVideoSearch({
    required BilibiliService service,
    required MultiCategorySearchPool pool,
    required String keyword,
    required VideoSearchFilter filter,
    required Iterable<int> categoryIds,
  }) : _service = service,
       _pool = pool,
       _keyword = keyword,
       _filter = filter,
       _cursors = {
         for (final id in (categoryIds.toSet().toList()..sort()))
           id: _CategoryCursor(),
       } {
    if (_cursors.length < 2 ||
        _cursors.length > maxSelectedCategories ||
        _cursors.keys.any((id) => id <= 0)) {
      throw ArgumentError(
        'Expected between 2 and $maxSelectedCategories category IDs.',
      );
    }
  }

  static const maxSelectedCategories = 5;
  static const _maxPage = 50;

  final BilibiliService _service;
  final MultiCategorySearchPool _pool;
  final String _keyword;
  final VideoSearchFilter _filter;
  final Map<int, _CategoryCursor> _cursors;
  final _firstReported = <String, VideoSearchResult>{};
  final _duplicates = <String, _KnownSearchEvidence>{};
  bool _closed = false;
  bool _loading = false;

  Set<int> get failedCategoryIds => {
    for (final entry in _cursors.entries)
      if (entry.value.failed) entry.key,
  };

  bool get hasNext =>
      !_closed &&
      _cursors.values.any(
        (cursor) => !cursor.failed && cursor.nextPage <= cursor.lastPage,
      );

  bool get hasLoadedCategory =>
      _cursors.values.any((cursor) => cursor.nextPage > 1);

  void close() => _closed = true;

  Future<void> loadNext() => _load(failedOnly: false);

  Future<void> retryFailures() => _load(failedOnly: true);

  Future<void> _load({required bool failedOnly}) async {
    if (_closed || _loading) return;
    _loading = true;
    try {
      await Future.wait([
        for (final entry in _cursors.entries)
          if (entry.value.failed == failedOnly &&
              entry.value.nextPage <= entry.value.lastPage)
            _pool.run(() => _loadCategory(entry.key, entry.value)),
      ]);
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadCategory(int categoryId, _CategoryCursor cursor) async {
    if (_closed) return;
    final page = cursor.nextPage;
    try {
      final result = await _service.searchVideos(
        _keyword,
        page: page,
        filter: _filter.copyWith(categoryId: categoryId),
      );
      if (_closed) return;
      if (result.page != page ||
          (result.reportedPage != null && result.reportedPage != page)) {
        throw const FormatException('Category search page did not advance');
      }
      // Keep server position before deduplication, since it breaks rank ties.
      for (var index = 0; index < result.results.length; index++) {
        final row = result.results[index];
        final first = _firstReported.putIfAbsent(row.bvid, () => row);
        if (!identical(row, first)) {
          _duplicates
              .putIfAbsent(row.bvid, () => _KnownSearchEvidence()..add(first))
              .add(row);
        }
        cursor.rows.putIfAbsent(
          row.bvid,
          () => (row: row, category: categoryId, page: page, index: index),
        );
      }
      cursor.nextPage = page + 1;
      cursor.lastPage = result.totalPages.clamp(page, _maxPage).toInt();
      cursor.failed = false;
    } catch (_) {
      if (!_closed) cursor.failed = true;
    }
  }

  /// For relevance, rank first within each category (page and position);
  /// at the same rank, order by numeric category ID. For metrics, rank loaded
  /// rows by the available values before falling back to the same rank rule.
  List<VideoSearchResult> get results {
    final rows = [for (final cursor in _cursors.values) ...cursor.rows.values]
      ..sort(_compare);
    final seen = <String>{};
    return [
      for (final rank in rows)
        if (seen.add(rank.row.bvid))
          _duplicates[rank.row.bvid]?.enrich(rank.row) ?? rank.row,
    ];
  }

  int _compare(_RankedRow a, _RankedRow b) {
    final metric = switch (_filter.order) {
      VideoSearchOrder.relevance => 0,
      VideoSearchOrder.mostPlayed => b.row.playCount.compareTo(a.row.playCount),
      VideoSearchOrder.newest => _compareMetric(
        a.row.publishedAt?.millisecondsSinceEpoch,
        b.row.publishedAt?.millisecondsSinceEpoch,
      ),
      VideoSearchOrder.mostDanmaku => b.row.danmakuCount.compareTo(
        a.row.danmakuCount,
      ),
      VideoSearchOrder.mostFavorited => _compareMetric(
        a.row.favoriteCount,
        b.row.favoriteCount,
      ),
    };
    if (metric != 0) return metric;
    final page = a.page.compareTo(b.page);
    if (page != 0) return page;
    final index = a.index.compareTo(b.index);
    if (index != 0) return index;
    return a.category.compareTo(b.category);
  }

  static int _compareMetric(int? a, int? b) {
    if (a == null) return b == null ? 0 : 1;
    return b == null ? -1 : b.compareTo(a);
  }
}

typedef _RankedRow = ({
  VideoSearchResult row,
  int category,
  int page,
  int index,
});

class _CategoryCursor {
  int nextPage = 1;
  int lastPage = 1;
  bool failed = false;
  final rows = <String, _RankedRow>{};
}

class _KnownSearchEvidence {
  final _tags = <String>{};
  final _ownerMids = <int>{};
  void add(VideoSearchResult row) {
    _tags.addAll(row.tags.where((tag) => tag.isNotEmpty));
    if (row.ownerMid > 0) _ownerMids.add(row.ownerMid);
  }

  VideoSearchResult enrich(VideoSearchResult row) {
    final mid = row.ownerMid > 0
        ? row.ownerMid
        : _ownerMids.length == 1
        ? _ownerMids.single
        : 0;
    return VideoSearchResult(
      bvid: row.bvid,
      title: row.title,
      ownerName: row.ownerName,
      duration: row.duration,
      thumbnailUrl: row.thumbnailUrl,
      publishedAt: row.publishedAt,
      playCount: row.playCount,
      danmakuCount: row.danmakuCount,
      episodeCountText: row.episodeCountText,
      favoriteCount: row.favoriteCount,
      categoryId: row.categoryId,
      ownerMid: mid,
      tags: List.unmodifiable(_tags),
      additionalReportedOwnerMids: Set.unmodifiable(
        _ownerMids.where((id) => id != mid),
      ),
    );
  }
}
