import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/content_blocklist.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/multi_category_video_search.dart';

void main() {
  test(
    'disagreeing reported UIDs never assign a guessed identity to an anonymous display row',
    () async {
      final api = BilibiliVideoInfoService(
        requestJson: (uri) async {
          final category = int.parse(uri.queryParameters['tids']!);
          return jsonEncode({
            'code': 0,
            'data': {
              'page': 1,
              'numPages': 1,
              'result': [
                {
                  'bvid': 'BV1000000001',
                  'title': 'winner',
                  'duration': '9:21',
                  if (category != 1) 'mid': category,
                },
              ],
            },
          });
        },
      );
      final session = MultiCategoryVideoSearch(
        service: api,
        pool: MultiCategorySearchPool(),
        keyword: 'qa',
        filter: const VideoSearchFilter(),
        categoryIds: [1, 36, 188],
      );
      await session.loadNext();
      final row = session.results.single;
      expect(row.ownerMid, 0);
      expect(row.additionalReportedOwnerMids, {36, 188});
      expect(
        const ContentBlocklist(creators: {36: 'rule'}).includes(row),
        isFalse,
      );
      // An explicit full-detail identity supersedes contradictory search hits.
      expect(
        const ContentBlocklist(
          creators: {36: 'rule'},
        ).includes(row, knownOwnerMid: 99),
        isTrue,
      );
    },
  );
  for (final edge in [
    'same-page-other-category',
    'next-page-same-category',
    'targeted-retry',
  ]) {
    test('retain known fields for one returned BV: $edge', () async {
      const bv = 'BV1000000001', unrelated = 'BV1000000002';
      var retry = true;
      final calls = <(int, int)>[];
      final api = BilibiliVideoInfoService(
        requestJson: (uri) async {
          expect(uri.path, '/x/web-interface/wbi/search/type');
          final id = int.parse(uri.queryParameters['tids']!),
              p = int.parse(uri.queryParameters['page']!);
          calls.add((id, p));
          if (edge == 'targeted-retry' && id == 188 && retry) {
            retry = false;
            throw StateError('offline');
          }
          final enriched = edge == 'next-page-same-category'
              ? id == 36 && p == 2
              : id == 188;
          final ordinary = id == 188 && edge == 'next-page-same-category';
          final item = {
            'bvid': ordinary ? unrelated : bv,
            'title': ordinary ? 'unrelated' : 'winner title',
            'play': 80,
            'duration': '9:21',
            if (enriched) 'tag': '合成标签,数学',
            if (enriched) 'mid': 414,
          };
          return jsonEncode({
            'code': 0,
            'data': {
              'page': p,
              'numPages': edge == 'next-page-same-category' && id == 36 ? 2 : 1,
              'result': [item],
            },
          });
        },
      );
      final s = MultiCategoryVideoSearch(
        service: api,
        pool: MultiCategorySearchPool(),
        keyword: 'geometry',
        filter: const VideoSearchFilter(),
        categoryIds: [36, 188],
      );
      await s.loadNext();
      if (edge == 'targeted-retry') {
        expect(s.failedCategoryIds, {188});
        expect(s.results.single.tags, isEmpty);
        await s.retryFailures();
      }
      if (edge == 'next-page-same-category') {
        await s.loadNext();
      }
      final rows = s.results.where((e) => e.bvid == bv).toList();
      expect(rows, hasLength(1));
      final tag = const ContentBlocklist(
        rules: {
          ContentBlockKind.videoTag: ['合成标签'],
        },
      );
      final uid = const ContentBlocklist(creators: {414: 'fixture'});
      final row = rows.single;
      expect(calls, containsAll([(36, 1), (188, 1)]));
      expect(row.title, 'winner title');
      expect(row.tags, contains('合成标签'));
      expect(row.ownerMid, 414);
      expect(tag.includes(row), isFalse);
      expect(uid.includes(row), isFalse);
    });
  }
}
