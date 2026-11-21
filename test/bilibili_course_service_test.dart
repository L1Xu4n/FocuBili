import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_course_service.dart';
import 'package:focubili/services/bilibili_service.dart';

const purchasedResponse =
    '{"code":0,"data":{"total":1,"data":[{"id":968174948}]}}';

Map<String, Object> episode(int id, {int cid = 123, int aid = 456}) => {
  'id': id,
  'cid': cid,
  'aid': aid,
  'title': 'Chapter $id',
  'duration': 90,
};
String response(
  List<Map<String, Object>> episodes, {
  bool next = false,
  int? total,
}) => jsonEncode({
  'code': 0,
  'data': {
    'season_id': 968174948,
    'title': 'Course',
    'up_info': {'uname': 'Teacher'},
    'episodes': episodes,
    'episode_page': {'next': next, 'total': total ?? episodes.length},
  },
});
void main() {
  test(
    'course metadata keeps namespace and 64-bit episode media IDs',
    () async {
      final service = BilibiliCourseService(
        readCookies: () async => 'synthetic-session',
        requestJson: (uri, cookie) async {
          if (uri.path.endsWith('/my/paid')) return purchasedResponse;
          expect(uri.path, '/pugv/view/web/season');
          expect(uri.queryParameters['season_id'], '968174948');
          return response([
            episode(1913937, cid: 31663719867, aid: 114973875373160),
          ]);
        },
      );
      final video = await service.lookup(
        Uri.parse('https://www.bilibili.com/cheese/play/ss968174948'),
      );
      expect(video.bvid, 'cheese:ss968174948');
      expect(video.isCourse, isTrue);
      expect(video.initialPart.courseEpisodeId, 1913937);
      expect(video.initialPart.courseAid, 114973875373160);
      expect(video.initialPart.cid, 31663719867);
      expect(video.withTags(['test']).courseSeasonId, 968174948);
    },
  );
  test(
    'episode links select exact episode; unavailable IDs do not fall back',
    () async {
      final service = BilibiliCourseService(
        readCookies: () async => 'synthetic-session',
        requestJson: (uri, _) async => uri.path.endsWith('/my/paid')
            ? purchasedResponse
            : response([episode(1), episode(2, cid: 124)]),
      );
      final video = await service.lookup(
        Uri.parse('https://www.bilibili.com/cheese/play/ep2'),
      );
      expect(video.cid, 124);
      await expectLater(
        service.lookup(Uri.parse('https://www.bilibili.com/cheese/play/ep3')),
        throwsA(isA<CourseLookupException>()),
      );
    },
  );
  test('loads all pages without duplicate chapters', () async {
    final service = BilibiliCourseService(
      readCookies: () async => 'test-session',
      requestJson: (uri, cookie) async {
        if (uri.path.endsWith('/my/paid')) return purchasedResponse;
        expect(cookie, 'test-session');
        if (uri.path.endsWith('/season')) {
          return response([episode(1)], next: true, total: 3);
        }
        final pn = uri.queryParameters['pn'];
        return jsonEncode({
          'code': 0,
          'data': {
            'items': pn == '1'
                ? [episode(1), episode(2, cid: 124)]
                : [episode(3, cid: 125)],
            'page': {'next': pn == '1', 'total': 3},
          },
        });
      },
    );
    final video = await service.lookup(
      Uri.parse('https://www.bilibili.com/cheese/play/ss968174948'),
    );
    expect(video.parts.map((p) => p.courseEpisodeId), [1, 2, 3]);
  });
  test('rejects incomplete pagination and session changes', () async {
    var reads = 0;
    final service = BilibiliCourseService(
      readCookies: () async => '${reads++}',
      requestJson: (uri, _) async => uri.path.endsWith('/my/paid')
          ? purchasedResponse
          : response([episode(1)]),
    );
    await expectLater(
      service.lookup(
        Uri.parse('https://www.bilibili.com/cheese/play/ss968174948'),
      ),
      throwsA(isA<CourseLookupException>()),
    );
    final broken = BilibiliCourseService(
      readCookies: () async => 'synthetic-session',
      requestJson: (uri, _) async => uri.path.endsWith('/my/paid')
          ? purchasedResponse
          : uri.path.endsWith('/season')
          ? response([episode(1)], next: true, total: 2)
          : jsonEncode({
              'code': 0,
              'data': {
                'items': [],
                'page': {'next': true},
              },
            }),
    );
    await expectLater(
      broken.lookup(
        Uri.parse('https://www.bilibili.com/cheese/play/ss968174948'),
      ),
      throwsA(isA<CourseLookupException>()),
    );
  });
  test('history storage keys reopen through course API, never UGC', () async {
    final course = BilibiliCourseService(
      readCookies: () async => 'synthetic-session',
      requestJson: (uri, _) async => uri.path.endsWith('/my/paid')
          ? purchasedResponse
          : response([episode(1)]),
    );
    final service = BilibiliVideoInfoService(
      courseService: course,
      requestJson: (_) async => throw StateError('UGC must not be requested'),
    );
    expect((await service.lookupVideo('cheese:ss968174948')).isCourse, isTrue);
  });
  test(
    'server purchase denial is surfaced without alternate endpoints',
    () async {
      var requests = 0;
      final service = BilibiliCourseService(
        readCookies: () async => 'synthetic-session',
        requestJson: (_, _) async {
          requests++;
          return '{"code":-403}';
        },
      );
      await expectLater(
        service.lookup(
          Uri.parse('https://www.bilibili.com/cheese/play/ss968174948'),
        ),
        throwsA(
          isA<CourseLookupException>().having(
            (e) => e.message,
            'message',
            contains('权限'),
          ),
        ),
      );
      expect(requests, 1);
    },
  );
}
