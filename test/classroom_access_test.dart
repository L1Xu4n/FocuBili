import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_course_link.dart';
import 'package:focubili/services/bilibili_course_service.dart';
import 'package:focubili/services/bilibili_deep_link_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/windows_dash_media_plan.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'bilibili_course_service_test.dart' show purchasedResponse;

const course = VideoPreview(
  bvid: 'cheese:ss968174948',
  courseSeasonId: 968174948,
  cid: 31663719867,
  title: 'Synthetic course',
  ownerName: 'Synthetic teacher',
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 31663719867,
      title: 'Chapter one',
      duration: Duration(minutes: 5),
      courseEpisodeId: 1913937,
      courseAid: 114973875373160,
    ),
    VideoPart(
      pageNumber: 2,
      cid: 37970971612,
      title: 'Chapter two',
      duration: Duration(minutes: 6),
      courseEpisodeId: 2508999,
      courseAid: 116492549095986,
    ),
  ],
);

class MemorySession implements BilibiliCookieStore {
  String cookie = 'synthetic-session';
  @override
  Future<String> readCookies() async => cookie;
  @override
  Future<void> replaceCookies(String value) async {
    cookie = value;
  }

  @override
  Future<void> clearBilibiliCookies() async {
    cookie = '';
  }
}

String mediaResponse(Map<String, Object?> extra) => jsonEncode({
  'code': 0,
  'data': {
    'quality': 64,
    'durl': [
      {'url': 'https://lesson.bilivideo.com/synthetic.mp4'},
    ],
    ...extra,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'purchase proof follows later pages and rejects an account switch during that proof',
    () async {
      var cookie = 'synthetic-A';
      final pages = <String>[];
      final proof = BilibiliCourseService(
        readCookies: () async => cookie,
        requestJson: (uri, session) async {
          expect(session, 'synthetic-A');
          pages.add(uri.queryParameters['pn']!);
          return jsonEncode({
            'code': 0,
            'data': {
              'total': 2,
              'data': [
                {'id': pages.length == 1 ? 9 : 968174948},
              ],
            },
          });
        },
      );
      await proof.requirePurchasedCourse(968174948, cookie);
      expect(pages, ['1', '2']);
      final changed = BilibiliCourseService(
        readCookies: () async => cookie,
        requestJson: (_, _) async {
          cookie = 'synthetic-B';
          return purchasedResponse;
        },
      );
      await expectLater(
        changed.requirePurchasedCourse(968174948, 'synthetic-A'),
        throwsA(isA<CourseLookupException>()),
      );
    },
  );
  test(
    'unpaid expired and unavailable seasons cannot reach playurl even if a free full chapter would succeed',
    () async {
      for (final item in <Map<String, Object?>>[
        {'id': 999},
        {'id': 968174948, 'is_expired': 1},
        {'id': 968174948, 'status': -3},
      ]) {
        var playurls = 0;
        final service = BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: MemorySession()),
          requestJson: (uri, _) async {
            if (uri.path.endsWith('/my/paid')) {
              return jsonEncode({
                'code': 0,
                'data': {
                  'total': 1,
                  'data': [item],
                },
              });
            }
            playurls++;
            return mediaResponse({'paid_access': 1, 'is_preview': 0});
          },
        );
        await expectLater(
          service.loadCourse(
            video: course,
            part: course.parts.first,
            quality: 64,
          ),
          throwsA(isA<DesktopPlaybackSourceException>()),
        );
        expect(playurls, 0);
      }
      final metadata = BilibiliCourseService(
        readCookies: () async => 'synthetic',
        requestJson: (uri, _) async => uri.path.endsWith('/my/paid')
            ? '{"code":0,"data":{"total":0,"data":[]}}'
            : '{"code":0,"data":{"season_id":968174948,"episodes":[{"id":1,"cid":101,"aid":11}]}}',
      );
      await expectLater(
        metadata.lookup(
          Uri.parse('https://www.bilibili.com/cheese/play/ss968174948'),
        ),
        throwsA(isA<CourseLookupException>()),
      );
    },
  );
  test(
    'native channel preserves exact chapter identity and resume; incomplete identity never reaches platform',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.focubili.app/playback');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      final playback = NativePlaybackService();
      try {
        await playback.openVideo(
          course,
          part: course.parts[1],
          initialPosition: const Duration(seconds: 47),
        );
        final args = Map<Object?, Object?>.from(calls.single.arguments as Map);
        expect(args['courseEpisodeId'], 2508999);
        expect(args['courseAid'], 116492549095986);
        expect(args['cid'], 37970971612);
        expect(args['pageNumber'], 2);
        expect(args['initialPositionMs'], 47000);
        expect(args['bvid'], 'cheese:ss968174948');
        await expectLater(
          playback.openVideo(
            course,
            part: const VideoPart(
              pageNumber: 1,
              cid: 1,
              title: 'Invalid',
              duration: Duration.zero,
            ),
          ),
          throwsArgumentError,
        );
        expect(calls, hasLength(1));
      } finally {
        await playback.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
  test(
    'strict official ss/ep links, shares and 64-bit IDs; no AV conversion',
    () async {
      for (final suffix in ['ss968174948', 'ep2508999']) {
        final link = 'https://www.bilibili.com/cheese/play/$suffix';
        expect(BilibiliCourseLink.parse(link)?.toString(), link);
        expect(BilibiliDeepLinkParser.parse(link)?.bvid, link);
        expect(BilibiliCourseLink.fromInput('分享：$link。')?.toString(), link);
        final incoming = BilibiliIncomingLinkResolver(
          expandShortLink: (_) async => Uri.parse(link),
        );
        expect(
          (await incoming.resolve('https://b23.tv/synthetic'))?.bvid,
          link,
        );
      }
      for (final link in [
        'https://bilibili.com.evil.invalid/cheese/play/ss1',
        'https://user:password@www.bilibili.com/cheese/play/ss1',
        'https://www.bilibili.com:8443/cheese/play/ss1',
        'https://www.bilibili.com/cheese/play/ss0',
        'https://www.bilibili.com/cheese/play/ep9223372036854775808',
        'https://www.bilibili.com/bangumi/play/ep1',
      ]) {
        expect(BilibiliCourseLink.parse(link), isNull);
      }
      expect(
        BilibiliCourseLink.fromStorageKey(course.bvid)?.path,
        '/cheese/play/ss968174948',
      );
      expect(
        BilibiliCourseLink.isStorageKey('cheese:ss9223372036854775808'),
        isFalse,
      );
    },
  );

  test('purchases require a session; no anonymous API read', () async {
    var requests = 0;
    final service = BilibiliCourseService(
      readCookies: () async => '',
      requestJson: (_, _) async {
        requests++;
        return '{}';
      },
    );
    await expectLater(
      service.purchasedCourses(),
      throwsA(isA<CourseLookupException>()),
    );
    await expectLater(
      service.lookup(Uri.parse('https://www.bilibili.com/cheese/play/ss1')),
      throwsA(isA<CourseLookupException>()),
    );
    expect(requests, 0);
  });

  test(
    'purchases paginate under one session and preserve expired/unavailable entries',
    () async {
      final pages = <String>[];
      final service = BilibiliCourseService(
        readCookies: () async => 'synthetic',
        requestJson: (uri, _) async {
          expect(uri.path, '/pugv/pay/web/my/paid');
          pages.add(uri.queryParameters['pn']!);
          return jsonEncode({
            'code': 0,
            'data': {
              'total': 3,
              'data': pages.length == 1
                  ? [
                      {'id': 1, 'title': 'One'},
                      {'id': 2, 'title': 'Expired', 'is_expired': 1},
                    ]
                  : [
                      {'id': 3, 'title': 'Gone', 'status': -3},
                    ],
            },
          });
        },
      );
      final result = await service.purchasedCourses();
      expect(pages, ['1', '2']);
      expect(result.map((e) => e.id), [1, 2, 3]);
      expect(result[1].expired, isTrue);
      expect(result[2].unavailable, isTrue);
    },
  );

  test(
    'duplicate pagination and account switches never publish a partial purchase list',
    () async {
      var current = 'synthetic-A';
      final duplicate = BilibiliCourseService(
        readCookies: () async => current,
        requestJson: (_, _) async => jsonEncode({
          'code': 0,
          'data': {
            'total': 2,
            'data': [
              {'id': 1},
            ],
          },
        }),
      );
      await expectLater(
        duplicate.purchasedCourses(),
        throwsA(isA<CourseLookupException>()),
      );
      final changed = BilibiliCourseService(
        readCookies: () async => current,
        requestJson: (_, _) async {
          current = 'synthetic-B';
          return '{"code":0,"data":{"total":0,"data":[]}}';
        },
      );
      await expectLater(
        changed.purchasedCourses(),
        throwsA(isA<CourseLookupException>()),
      );
    },
  );

  test(
    'desktop classroom sends real IDs, chapter referer and never UGC/WBI',
    () async {
      final session = MemorySession();
      var requests = 0;
      final service = BilibiliDesktopPlaybackSourceService(
        authService: BilibiliAuthService(cookieStore: session),
        requestJson: (uri, headers) async {
          if (uri.path.endsWith('/my/paid')) return purchasedResponse;
          requests++;
          expect(uri.path, '/pugv/player/web/playurl');
          expect(uri.queryParameters['ep_id'], '2508999');
          expect(uri.queryParameters['avid'], '116492549095986');
          expect(uri.queryParameters['cid'], '37970971612');
          expect(uri.queryParameters.containsKey('bvid'), isFalse);
          expect(uri.queryParameters.containsKey('w_rid'), isFalse);
          expect(headers['Referer'], endsWith('/cheese/play/ep2508999'));
          return mediaResponse({});
        },
      );
      final sources = await service.loadCourse(
        video: course,
        part: course.parts[1],
        quality: 64,
      );
      expect(requests, 1);
      expect(sources.videoCodec, 'muxed');
      expect(WindowsDashMediaPlan.build(sources).single.audioUrl, isEmpty);
      expect(sources.mediaHeaders.containsKey('Cookie'), isFalse);
    },
  );

  test(
    'desktop checks per-chapter denial, DRM, preview and unsupported media before opening',
    () async {
      final replies = [
        '{"code":-403,"message":"untrusted response"}',
        '{"code":-101}',
        '{"code":0,"data":{"code":6002105}}',
        mediaResponse({'is_drm': true}),
        mediaResponse({'paid_access': 0, 'is_preview': 0}),
        mediaResponse({'drm_tech_type': 1}),
        mediaResponse({'is_preview': true}),
        mediaResponse({'is_preview': 1}),
        mediaResponse({
          'durl': [
            {'url': 'https://one.bilivideo.com/a'},
            {'url': 'https://one.bilivideo.com/b'},
          ],
        }),
        mediaResponse({
          'durl': [
            {'url': 'https://evil.invalid/a'},
          ],
        }),
      ];
      for (final reply in replies) {
        var requests = 0;
        final service = BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: MemorySession()),
          requestJson: (uri, _) async {
            if (uri.path.endsWith('/my/paid')) return purchasedResponse;
            requests++;
            return reply;
          },
        );
        await expectLater(
          service.loadCourse(
            video: course,
            part: course.parts.first,
            quality: 64,
          ),
          throwsA(isA<DesktopPlaybackSourceException>()),
        );
        expect(
          requests,
          1,
          reason:
              'Denial must not fall back to other endpoints or anonymous playback',
        );
      }
    },
  );

  test(
    'desktop rejects account change during playurl and missing chapter identity before request',
    () async {
      final session = MemorySession();
      var requests = 0;
      final service = BilibiliDesktopPlaybackSourceService(
        authService: BilibiliAuthService(cookieStore: session),
        requestJson: (uri, _) async {
          if (uri.path.endsWith('/my/paid')) return purchasedResponse;
          requests++;
          session.cookie = 'changed';
          return mediaResponse({});
        },
      );
      await expectLater(
        service.loadCourse(
          video: course,
          part: course.parts.first,
          quality: 64,
        ),
        throwsA(isA<DesktopPlaybackSourceException>()),
      );
      expect(requests, 1);
      await expectLater(
        service.loadCourse(
          video: course,
          part: const VideoPart(
            pageNumber: 9,
            cid: 9,
            title: 'Invalid',
            duration: Duration.zero,
          ),
          quality: 64,
        ),
        throwsA(isA<DesktopPlaybackSourceException>()),
      );
      expect(requests, 1);
    },
  );
}
