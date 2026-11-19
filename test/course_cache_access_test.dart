import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_access.dart';
import 'package:focubili/services/course_cache_validity.dart';

const _nav = '/x/web-interface/nav';
const _paid = '/pugv/pay/web/my/paid';
const _season = '/pugv/view/web/season';
const _list = '/pugv/view/web/ep/list';
const _media = '/ogv/player/playview';
const _cookie = 'SESSDATA=synthetic-session-header; DedeUserID=51';
const _backupCookie = 'SESSDATA=new-synthetic-session-header; DedeUserID=51';
const _bvid = 'BV1xx411c7Xr';
final _now = DateTime.utc(2026, 11, 18, 12);
int _seconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

const _part = VideoPart(
  pageNumber: 1,
  cid: 243,
  title: '合成课程章节',
  duration: Duration(minutes: 2),
  courseEpisodeId: 168,
  courseAid: 297,
);

const _video = VideoPreview(
  bvid: 'cheese:ss145',
  cid: 243,
  title: '合成课程',
  ownerName: '示例账号',
  parts: [_part],
  courseSeasonId: 145,
);

Map<String, Object?> _lesson({int ep = 168, int cid = 243, int aid = 297}) => {
  'id': ep,
  'cid': cid,
  'aid': aid,
  'playable': true,
  'episode_can_view': true,
  'ep_status': 0,
};

class _Fixture {
  _Fixture() {
    purchases = [
      {'id': 145},
    ];
    accountStatus = {
      'payed': 1,
      'is_expired': false,
      'expire_at': _seconds(_now.add(const Duration(hours: 8))),
    };
    meta = {
      'season_id': 145,
      'show_watermark': false,
      'user_status': accountStatus,
      'episodes': [_lesson()],
      'episode_page': {'next': false, 'total': 1},
    };
    response = {
      'is_preview': 0,
      'is_drm': 0,
      'allow_download': true,
      'season_id': 145,
      'ep_id': 168,
      'cid': 243,
      'avid': 297,
      'quality': 64,
      'dash': {
        'video': [
          {
            'id': 64,
            'mimeType': 'video/mp4',
            'codecs': 'avc1.640028',
            'baseUrl': _url('v.m4s', const Duration(hours: 4)),
          },
        ],
        'audio': [
          {
            'id': 30280,
            'mime_type': 'audio/mp4',
            'codecs': 'mp4a.40.2',
            'base_url': _url('a.m4s', const Duration(hours: 6)),
            'backup_url': [_url('a-alt.m4s', const Duration(hours: 5))],
          },
        ],
      },
    };
  }

  Map<String, Object?> identity = {
    'isLogin': true,
    'mid': 51,
    'wbi_img': {
      'img_url':
          'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
      'sub_url':
          'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
    },
  };
  String cookie = _cookie;
  DateTime now = _now;
  late List<Map<String, Object?>> purchases;
  late Map<String, Object?> accountStatus;
  late Map<String, Object?> meta;
  late Map<String, Object?> response;
  Map<String, Object?> playviewFields = {};
  int playviewCode = 0;
  Map<String, Object?>? episodesPage;
  final requests = <Uri>[];
  String? hang;
  Completer<String>? pending;
  final started = Completer<void>();
  Object? requestFailure;

  Future<String> fetch(Uri uri, String sentCookie) async {
    expect(uri.host, 'api.bilibili.com');
    expect(uri.scheme, 'https');
    expect(sentCookie, _cookie);
    requests.add(uri);
    if (uri.path == hang) {
      if (!started.isCompleted) started.complete();
      return pending!.future;
    }
    if (requestFailure != null) throw requestFailure!;
    final data = switch (uri.path) {
      _nav => identity,
      _paid => {'total': purchases.length, 'data': purchases},
      _season => meta,
      _media => playview,
      _list => episodesPage!,
      _ => throw StateError('unexpected endpoint'),
    };
    return uri.path == _media
        ? jsonEncode({'code': playviewCode, 'data': data})
        : _body(data);
  }

  Map<String, Object?> get playview => {
    'video_info': response,
    ...playviewFields,
  };

  Map<String, Object?> get videoTrack =>
      ((response['dash'] as Map)['video'] as List).single
          as Map<String, Object?>;

  CourseCacheAccess service() => CourseCacheAccess(
    requestJson: fetch,
    readCookies: () async => cookie,
    clock: () => now,
  );
}

String _body(Map data) => jsonEncode({'code': 0, 'data': data});

String _url(String file, Duration ttl) =>
    'https://cdn.bilivideo.com/$file?deadline=${_seconds(_now.add(ttl))}&upsig=masked';

final _rejected = throwsA(isA<CourseCacheAccessException>());

class _NativeSession extends Fake
    implements BilibiliCookieStore, BilibiliPlaybackSessionStore {
  int generation = 1;
  final paths = <String>[];
  final headers = <String, String>{};
  final generations = <String, int>{};

  @override
  Future<BilibiliPlaybackCookieSnapshot> readPlaybackSession(
    String path,
  ) async {
    paths.add(path);
    return BilibiliPlaybackCookieSnapshot(
      header: headers[path] ?? _cookie,
      state: 'session',
      generation: generations[path] ?? generation,
    );
  }

  @override
  Future<bool> validatePlaybackSession(int snapshot, String path) async {
    paths.add(path);
    return snapshot == generation;
  }
}

class _UnscopedSession extends Fake implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => _cookie;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() {
    fixture = _Fixture();
    CacheLifecycle.accountScope = 'mid:51';
    CacheLifecycle.accountChanged();
  });

  tearDown(() {
    CacheLifecycle.accountScope = 'guest';
    CacheLifecycle.accountChanged();
  });

  test(
    'signed PUGV playview selects exact DASH tracks without conflating URL and receipt deadlines',
    () async {
      final service = fixture.service();
      final grant = await service.authorize(_video, _part, 64);
      expect(fixture.requests.map((uri) => uri.path), [
        _nav,
        _paid,
        _season,
        _media,
      ]);
      expect(fixture.requests[2].queryParameters, {'ep_id': '168'});
      expect(fixture.requests.last.queryParameters, {
        'avid': '297',
        'bvid': _bvid,
        'ep_id': '168',
        'season_id': '145',
        'cid': '243',
        'qn': '64',
        'fnver': '0',
        'fnval': '4048',
        'fourk': '1',
        'biz_type': 'pugv',
        'scene': 'normal',
        'from_client': 'BROWSER',
        'app_id': '100',
        'wts': '1795003200',
        // Computed independently from the fixed public signing inputs.
        'w_rid': '3203b50a360daf904c1457f82f4e4a62',
      });
      expect(grant.mid, 51);
      expect(grant.checkedAt, _now);
      expect(grant.validUntil, _now.add(const Duration(hours: 8)));
      final videoUrl = Uri.parse(grant.media.video.urls.single);
      final audioUrl = Uri.parse(grant.media.audio!.urls.first);
      final afterVideoToken = _now.add(const Duration(hours: 4));
      expect(() => grant.checkTransport!(videoUrl, afterVideoToken), _rejected);
      expect(
        () => grant.checkTransport!(audioUrl, afterVideoToken),
        returnsNormally,
      );
      fixture.now = afterVideoToken;
      await grant.checkSession();
      expect(grant.media.quality, 64);
      expect(grant.media.audio!.urls, hasLength(2));
      expect(grant.mediaHeaders.keys, isNot(contains('Cookie')));
      expect(grant.mediaHeaders.keys, isNot(contains('Authorization')));
      expect(grant.mediaHeaders.values.join(), isNot(contains(_cookie)));
      await grant.checkSession();
      fixture.now = grant.validUntil!;
      await expectLater(grant.checkSession(), _rejected);
      fixture.now = _now.subtract(const Duration(seconds: 1));
      await expectLater(grant.checkSession(), _rejected);
    },
  );

  test(
    'OGV arc and exact episode supply clear and offline-authorized facts',
    () async {
      fixture.response
        ..remove('is_drm')
        ..remove('allow_download');
      fixture.meta['episodes'] = [
        {..._lesson(), 'offline_allowed': true},
      ];
      fixture.playviewFields['arc'] = {
        'aid': 297,
        'cid': 243,
        'bvid': _bvid,
        'is_drm': false,
      };
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.mid, 51);
      expect(grant.media.video.urls, [fixture.videoTrack['baseUrl']]);
      expect(grant.media.audio?.urls, hasLength(2));
    },
  );

  test(
    'successful online playback is not positive offline authorization',
    () async {
      fixture.response
        ..remove('allow_download')
        ..['paid_access'] = true;
      fixture.playviewFields['watch_progress'] = {'allow_download': true};
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        throwsA(
          isA<CourseCacheAccessException>().having(
            (e) => e.diagnosticCode,
            'diagnostic code',
            'course-cache/v1/playback/offlinePermissionUnknown',
          ),
        ),
      );
      expect(fixture.requests.map((u) => u.path), [
        _nav,
        _paid,
        _season,
        _media,
      ]);
    },
  );

  for (final reason in <String, void Function(_Fixture)>{
    'DRM on outer arc even with a clear rendition': (f) =>
        f.playviewFields['arc'] = {'is_drm': true},
    'DRM fallback trigger without video information': (f) => f.playviewFields
      ..['arc'] = {'is_drm': true}
      ..remove('video_info')
      ..['video_info'] = null,
    'explicit not playable reason with a usable-looking rendition': (f) =>
        f.playviewFields['not_playable_reason'] = {
          'code': -403,
          'message': 'denied',
        },
    'preview on outer result despite inner full marker': (f) =>
        f.playviewFields['is_preview'] = true,
    'outer offline denial despite inner grant': (f) =>
        f.playviewFields['allow_download'] = false,
    'unrelated chapter identities': (f) =>
        f.playviewFields['arc'] = {'cid': 244, 'is_drm': false},
    'legacy flat response': (f) => f.playviewFields
      ..addAll(f.response)
      ..['video_info'] = null,
    'provider API refusal': (f) => f.playviewCode = -403,
  }.entries) {
    test(
      'rejects ${reason.key} without making a second media request',
      () async {
        reason.value(fixture);
        await expectLater(
          fixture.service().authorize(_video, _part, 64),
          _rejected,
        );
        expect(fixture.requests.map((u) => u.path), [
          _nav,
          _paid,
          _season,
          _media,
        ]);
      },
    );
  }

  test(
    'absent WBI material never falls back to an unsigned media request',
    () async {
      fixture.identity.remove('wbi_img');
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        _rejected,
      );
      expect(fixture.requests.map((u) => u.path), [_nav, _paid, _season]);
    },
  );

  for (final scenario
      in <(String, void Function(_Fixture), bool, String, String)>[
        (
          'absent watermark metadata',
          (f) => f.meta.remove('show_watermark'),
          false,
          '当前无法确认本章能否离线缓存。',
          'course-cache/v1/course/watermarkUnknown',
        ),
        (
          'missing preview field despite enabled download hint',
          (f) => f.response
            ..remove('is_preview')
            ..['allow_download'] = true,
          true,
          '当前无法确认本章能否离线缓存。',
          'course-cache/v1/playback/previewUnknown',
        ),
        (
          'unknown nested DRM metadata',
          (f) => f.videoTrack['drm_unknown'] = 'future',
          true,
          '当前无法确认本章能否离线缓存。',
          'course-cache/v1/playback/policyUnknown',
        ),
        (
          'explicit download denial',
          (f) => f.videoTrack['download_allowed'] = false,
          true,
          '本章有播放保护、试看或下载限制，无法缓存。',
          'course-cache/v1/playback/restrictionReported',
        ),
        (
          'absent DRM metadata',
          (f) => f.response.remove('is_drm'),
          true,
          '当前无法确认本章能否离线缓存。',
          'course-cache/v1/playback/drmUnknown',
        ),
        (
          'unavailable media format',
          (f) => f.videoTrack['codecs'] = 'unknown',
          true,
          '当前课程未返回可确认的完整媒体格式，无法缓存。',
          'course-cache/v1/media/unsupportedMedia',
        ),
        (
          'expired media address',
          (f) => f.videoTrack['baseUrl'] = _url(
            'v.m4s',
            const Duration(seconds: -1),
          ),
          true,
          '课程下载地址已到期或无法确认，请重新联网确认。',
          'course-cache/v1/transport/addressUnavailable',
        ),
        (
          'explicit DRM',
          (f) => f.response['is_drm'] = true,
          true,
          '本章有播放保护、试看或下载限制，无法缓存。',
          'course-cache/v1/playback/restrictionReported',
        ),
      ]) {
    test('reports ${scenario.$1} without authorizing a cache', () async {
      scenario.$2(fixture);
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        throwsA(
          isA<CourseCacheAccessException>()
              .having((e) => e.message, 'message', scenario.$4)
              .having((e) => e.diagnosticCode, 'sanitized code', scenario.$5)
              .having(
                (e) => e.revokesReceipt,
                'revokesReceipt',
                scenario.$1 != 'expired media address',
              ),
        ),
      );
      expect(fixture.requests.map((u) => u.path), [
        _nav,
        _paid,
        _season,
        if (scenario.$3) _media,
      ]);
    });
  }

  test('authorized DASH selects a compatible lower quality and AAC', () async {
    fixture.response['allow_download'] = true;
    final dash = Map.of(fixture.response['dash'] as Map);
    fixture.response['dash'] = dash;
    final firstVideo = fixture.videoTrack;
    final firstAudio = (dash['audio'] as List).single as Map;
    dash['video'] = [
      {...firstVideo, 'codecs': 'av01.0.05M.08'},
      {...firstVideo, 'id': 32},
    ];
    dash['audio'] = [
      {...firstAudio, 'codecs': 'opus', 'bandwidth': 1000000},
      firstAudio,
    ];
    final grant = await fixture.service().authorize(_video, _part, 64);
    expect(grant.media.quality, 32);
    expect(grant.media.video.codec, 'avc1.640028');
    expect(grant.media.audio?.codec, 'mp4a.40.2');
    expect(fixture.requests.map((u) => u.path), [_nav, _paid, _season, _media]);

    // Too high is still rejected, even when the representation is compatible.
    await expectLater(
      fixture.service().authorize(_video, _part, 16),
      _rejected,
    );
  });

  test(
    'compatible fallback cannot override an explicit download restriction',
    () async {
      final dash = Map.of(fixture.response['dash'] as Map);
      fixture.response['dash'] = dash;
      final compatible = fixture.videoTrack;
      dash['video'] = [
        {...compatible, 'codecs': 'av01.0.05M.08', 'download_allowed': false},
        {...compatible, 'id': 32},
      ];
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        throwsA(
          isA<CourseCacheAccessException>().having(
            (e) => e.diagnosticCode,
            'sanitized code',
            'course-cache/v1/playback/restrictionReported',
          ),
        ),
      );
      expect(fixture.requests.map((u) => u.path), [
        _nav,
        _paid,
        _season,
        _media,
      ]);
    },
  );

  test(
    'authorized DASH with only incompatible audio remains unsupported',
    () async {
      final dash = Map.of(fixture.response['dash'] as Map);
      fixture.response['dash'] = dash;
      final oldAudio = (dash['audio'] as List).single as Map;
      dash['audio'] = [
        {...oldAudio, 'codecs': 'opus'},
      ];
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        _rejected,
      );
    },
  );

  for (final invalid in [
    {'isLogin': true, 'mid': 52},
    {'isLogin': false, 'mid': 51},
    {'mid': 51},
  ]) {
    test('remote login does not confirm cached identity: $invalid', () async {
      fixture.identity = invalid;
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        _rejected,
      );
      expect(fixture.requests.map((uri) => uri.path), [_nav]);
    });
  }

  test('purchase expiry can be earlier than the source TTL', () async {
    final purchaseEnd = _now.add(const Duration(minutes: 90));
    fixture.accountStatus['expire_at'] = purchaseEnd.millisecondsSinceEpoch;
    final grant = await fixture.service().authorize(_video, _part, 64);
    expect(grant.validUntil, purchaseEnd);
  });

  test(
    'an actual elapsed server cutoff is retained with the definitive refusal',
    () async {
      final end = _now.subtract(const Duration(minutes: 1));
      fixture.accountStatus['expire_at'] = _seconds(end);
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        throwsA(
          isA<CourseCacheAccessException>()
              .having((e) => e.revokesReceipt, 'revokes receipt', isTrue)
              .having((e) => e.knownUntil, 'known server end', end),
        ),
      );
    },
  );

  test(
    'the earliest explicit purchase or offline authorization wins',
    () async {
      fixture.purchases.single['expire_at'] = _seconds(
        _now.add(const Duration(hours: 5)),
      );
      fixture.accountStatus['offline_expires_at'] = _seconds(
        _now.add(const Duration(hours: 3)),
      );
      final earlier = _now.add(const Duration(hours: 2));
      fixture.response['offline_valid_until'] = earlier.millisecondsSinceEpoch;
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.validUntil, earlier);
      fixture.now = earlier;
      await expectLater(grant.checkSession(), _rejected);
    },
  );

  test(
    'an expired backup signing token cannot shorten valid media or block other URLs',
    () async {
      final expired = _url('expired.m4s', const Duration(hours: -1));
      fixture.videoTrack['backupUrl'] = [expired];
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.validUntil, _now.add(const Duration(hours: 8)));
      expect(grant.media.video.urls, [fixture.videoTrack['baseUrl']]);
      expect(
        () => grant.checkTransport!(
          Uri.parse(grant.media.video.urls.first),
          _now,
        ),
        returnsNormally,
      );
      expect(() => grant.checkTransport!(Uri.parse(expired), _now), _rejected);
    },
  );

  test(
    'malformed backup cannot reject an otherwise authorized video track',
    () async {
      const malformed = 'https://cdn.bilivideo.com/malformed.m4s?upsig=opaque';
      final fresh = _url('fresh.m4s', const Duration(hours: 5));
      fixture.response['allow_download'] = true;
      fixture.videoTrack['backupUrl'] = [malformed, fresh];
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.media.video.urls, [fixture.videoTrack['baseUrl'], fresh]);
      expect(grant.validUntil, _now.add(const Duration(hours: 8)));
      expect(
        () => grant.checkTransport!(Uri.parse(malformed), _now),
        _rejected,
      );
      expect(fixture.requests.map((uri) => uri.path), [
        _nav,
        _paid,
        _season,
        _media,
      ]);
    },
  );

  test(
    'ignores a malformed primary only if a valid same-track backup exists',
    () async {
      final fresh = _url('fresh.m4s', const Duration(hours: 5));
      fixture.videoTrack
        ..['baseUrl'] =
            'https://cdn.bilivideo.com/v.m4s?deadline=1795017600&deadline=broken'
        ..['backupUrl'] = [fresh];
      fixture.response['allow_download'] = true;
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.media.video.urls, [fresh]);
      expect(grant.validUntil, _now.add(const Duration(hours: 8)));
      fixture.response['allow_download'] = false;
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        throwsA(
          isA<CourseCacheAccessException>().having(
            (error) => error.diagnosticCode,
            'diagnostic code',
            'course-cache/v1/playback/restrictionReported',
          ),
        ),
      );
    },
  );

  test(
    'explicit long-term purchase imposes no synthetic deadline on verified MP4',
    () async {
      fixture.accountStatus['expire_at'] = 0;
      fixture.accountStatus['user_expiry_content'] = '长期有效';
      fixture.meta['expiry_day'] = 0;
      fixture.response.remove('dash');
      fixture.response['format'] = 'mp4';
      fixture.response['durl'] = [
        {
          'url': 'https://sample.bilivideo.cn/a.mp4',
          'backup_url': ['https://backup.bilivideo.cn/b.mp4'],
          'size': 4096,
        },
      ];
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.media.audio, isNull);
      expect(grant.media.video.expectedBytes, 4096);
      expect(grant.validUntil, isNull);
      expect(grant.expiryKind, CourseCacheExpiryKind.explicitLongTerm);
      fixture.now = _now.add(const Duration(days: 5));
      await grant.checkSession();
    },
  );

  test(
    'verified purchase with no server deadline remains valid beyond a day',
    () async {
      fixture.accountStatus.remove('expire_at');
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.validUntil, isNull);
      expect(grant.expiryKind, CourseCacheExpiryKind.noDeclaredDeadline);
      fixture.now = _now.add(const Duration(days: 9));
      await grant.checkSession();
      expect(
        () => grant.checkTransport!(
          Uri.parse(grant.media.video.urls.single),
          fixture.now,
        ),
        _rejected,
      );
      fixture.cookie = _backupCookie;
      await expectLater(grant.checkSession(), _rejected);
    },
  );

  test(
    'a confirmed purchase with a later real deadline does not end after 24 hours',
    () async {
      final end = _now.add(const Duration(days: 5));
      fixture.accountStatus['expire_at'] = _seconds(end);
      final grant = await fixture.service().authorize(_video, _part, 64);
      expect(grant.validUntil, end);
      fixture.now = _now.add(const Duration(days: 2));
      await grant.checkSession();
      fixture.now = end;
      await expectLater(grant.checkSession(), _rejected);
    },
  );

  test(
    'misleading, ambiguous or malformed purchase deadlines remain locked',
    () async {
      for (final update in <void Function(_Fixture)>[
        (f) => f.accountStatus['expire_at'] = 0,
        (f) => f.accountStatus['expire_at'] = 'not a date',
        (f) => f.accountStatus['expire_at'] = null,
        (f) {
          f.accountStatus.remove('expire_at');
          f.meta['expiry_day'] = 365;
        },
        (f) {
          f.accountStatus.remove('expire_at');
          f.accountStatus['user_expiry_content'] = '长期有效';
          f.meta['expiry_day'] = 365;
        },
      ]) {
        final bad = _Fixture();
        update(bad);
        await expectLater(
          bad.service().authorize(_video, _part, 64),
          _rejected,
        );
        expect(bad.requests.map((uri) => uri.path), isNot(contains(_media)));
      }
    },
  );

  test(
    'no reported deadline does not relax purchase, watermark, DRM or preview checks',
    () async {
      for (final update in <void Function(_Fixture)>[
        (f) => f.accountStatus['payed'] = 0,
        (f) => f.accountStatus['is_expired'] = true,
        (f) => f.meta['show_watermark'] = true,
        (f) => f.response['is_preview'] = true,
        (f) => f.response['is_drm'] = true,
        (f) => f.response['allow_download'] = false,
      ]) {
        final restricted = _Fixture()..accountStatus.remove('expire_at');
        update(restricted);
        await expectLater(
          restricted.service().authorize(_video, _part, 64),
          _rejected,
        );
      }
    },
  );

  test(
    'identifies an episode on the official catalogue page instead of the first lesson',
    () async {
      final other = {..._lesson(ep: 7), 'is_drm': true};
      fixture.meta['episodes'] = [other];
      fixture.meta['episode_page'] = {'next': true, 'total': 2};
      fixture.episodesPage = {
        'season_id': 145,
        'items': [other, _lesson()],
        'page': {'next': false, 'total': 2},
      };
      await fixture.service().authorize(_video, _part, 64);
      expect(fixture.requests.map((u) => u.path), [
        _nav,
        _paid,
        _season,
        _list,
        _media,
      ]);
      expect(fixture.requests[3].queryParameters['season_id'], '145');
    },
  );

  test(
    'duplicate snapshots without progress stop instead of retrying to the page bound',
    () async {
      fixture.meta['episodes'] = [_lesson(ep: 7)];
      fixture.meta['episode_page'] = {'next': true, 'total': 10};
      fixture.episodesPage = {
        'items': [_lesson(ep: 7)],
        'page': {'next': true},
      };
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        _rejected,
      );
      expect(fixture.requests.map((u) => u.path), [
        _nav,
        _paid,
        _season,
        _list,
        _list,
      ]);
    },
  );

  test(
    'cached MID must match a nonempty secure session; no network probes',
    () async {
      final service = fixture.service();
      expect(await service.currentLocalMid(), 51);
      for (final session in [
        '',
        'DedeUserID=51',
        'SESSDATA=; DedeUserID=51',
        'SESSDATA=""; DedeUserID=51',
        'SESSDATA=sample; DedeUserID=52',
        'SESSDATA=sample; DedeUserID=51; DedeUserID=52',
        'SESSDATA=sample; SESSDATA=other; DedeUserID=51',
      ]) {
        fixture.cookie = session;
        expect(await service.currentLocalMid(), isNull);
        await expectLater(service.authorize(_video, _part, 64), _rejected);
      }
      fixture.cookie = _cookie;
      CacheLifecycle.accountScope = 'guest';
      expect(await service.currentLocalMid(), isNull);
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'native course authorization forwards each exact endpoint scoped header',
    () async {
      final other = _lesson(ep: 7);
      final native = _NativeSession();
      final headers = {
        _nav: '$_cookie; buvid3=nav-only',
        _paid: '$_cookie; buvid3=paid-only',
        _season: '$_cookie; buvid3=season-only',
        _list: '$_cookie; buvid3=chapter-only',
        _media: '$_cookie; buvid3=playview-only',
      };
      native.headers.addAll(headers);
      fixture.meta['episodes'] = [other];
      fixture.meta['episode_page'] = {'next': true, 'total': 2};
      fixture.episodesPage = {
        'season_id': 145,
        'items': [other, _lesson()],
        'page': {'next': false, 'total': 2},
      };
      final forwarded = <String, String>{};
      final service = CourseCacheAccess(
        authService: BilibiliAuthService(cookieStore: native),
        clock: () => _now,
        requestJson: (uri, header) {
          forwarded[uri.path] = header;
          return fixture.fetch(uri, _cookie);
        },
      );
      final grant = await service.authorize(_video, _part, 64);
      expect(grant.mid, 51);
      expect(fixture.requests.map((u) => u.path), headers.keys);
      expect(forwarded, headers);
      expect(grant.mediaHeaders.keys, isNot(contains('Cookie')));
      expect(
        grant.mediaHeaders.values.join(),
        isNot(contains('playview-only')),
      );
    },
  );

  for (final (label, header, generation) in [
    ('different signed-in credential', _backupCookie, 1),
    (
      'different signed-in MID',
      'SESSDATA=synthetic-session-header; DedeUserID=52',
      1,
    ),
    ('no scoped credential', '', 1),
    ('new native generation', _cookie, 2),
  ]) {
    test('does not send requests with $label on the metadata path', () async {
      final native = _NativeSession()
        ..headers[_paid] = header
        ..generations[_paid] = generation;
      final service = CourseCacheAccess(
        authService: BilibiliAuthService(cookieStore: native),
        clock: () => _now,
        requestJson: fixture.fetch,
      );
      await expectLater(
        service.authorize(_video, _part, 64),
        throwsA(
          isA<CourseCacheAccessException>().having(
            (error) => error.reason,
            'reason',
            CourseCacheReason.sessionChanged,
          ),
        ),
      );
      expect(fixture.requests.map((u) => u.path), [_nav]);
    });
  }

  test('unscoped platforms keep stable secure-store forwarding', () async {
    final service = CourseCacheAccess(
      authService: BilibiliAuthService(cookieStore: _UnscopedSession()),
      clock: () => _now,
      requestJson: fixture.fetch,
    );
    final grant = await service.authorize(_video, _part, 64);
    expect(grant.mid, 51);
    expect(fixture.requests.map((u) => u.path), [_nav, _paid, _season, _media]);
  });

  test(
    'native generation invalidates a grant even if cookie text stays the same',
    () async {
      final native = _NativeSession();
      final service = CourseCacheAccess(
        authService: BilibiliAuthService(cookieStore: native),
        clock: () => _now,
        requestJson: fixture.fetch,
      );
      expect(await service.currentLocalMid(), 51);
      final grant = await service.authorize(_video, _part, 64);
      native.generation++;
      await expectLater(grant.checkSession(), _rejected);
      expect(native.paths.toSet(), {_nav, _paid, _season, _media});
    },
  );

  test(
    'same MID but replaced credential invalidates an existing grant',
    () async {
      final grant = await fixture.service().authorize(_video, _part, 64);
      fixture.cookie = _backupCookie;
      await expectLater(grant.checkSession(), _rejected);
    },
  );

  test(
    'late successful play response cannot return a grant after account switch',
    () async {
      fixture.hang = _media;
      fixture.pending = Completer<String>();
      final result = fixture.service().authorize(_video, _part, 64);
      await fixture.started.future;
      CacheLifecycle.accountChanged();
      fixture.pending!.complete(_body(fixture.playview));
      await expectLater(result, _rejected);
    },
  );

  test(
    'late catalogue response cannot continue to media after account switch',
    () async {
      fixture.hang = _season;
      fixture.pending = Completer<String>();
      final result = fixture.service().authorize(_video, _part, 64);
      await fixture.started.future;
      fixture.cookie = _backupCookie;
      fixture.pending!.complete(_body(fixture.meta));
      await expectLater(result, _rejected);
      expect(fixture.requests.map((u) => u.path), [_nav, _paid, _season]);
    },
  );

  for (final reason in <String, void Function(_Fixture)>{
    'empty paid list': (f) => f.purchases.clear(),
    'expired paid row': (f) => f.purchases.first['is_expired'] = true,
    'expired paid row represented as text': (f) =>
        f.purchases.first['is_expired'] = 'true',
    'paid row explicitly forbids caching': (f) =>
        f.purchases.first['can_cache'] = false,
    'delisted paid row': (f) => f.purchases.first['status'] = -3,
    'unpaid despite allowed preview': (f) {
      f.accountStatus['payed'] = 0;
      f.accountStatus['expire_at'] = 0;
      f.accountStatus['user_expiry_content'] = '长期有效';
      f.meta['expiry_day'] = 0;
    },
    'mismatched season': (f) => f.meta['season_id'] = 9,
    'duplicate episode': (f) => f.meta['episodes'] = [_lesson(), _lesson()],
    'wrong aid': (f) => f.meta['episodes'] = [_lesson(aid: 200)],
    'wrong cid': (f) => f.meta['episodes'] = [_lesson(cid: 200)],
    'wrong ep': (f) => f.meta['episodes'] = [_lesson(ep: 200)],
    'playable without explicit can view': (f) =>
        f.meta['episodes'] = [_lesson()..remove('episode_can_view')],
    'cannot play': (f) => f.meta['episodes'] = [
      {..._lesson(), 'playable': false},
    ],
    'explicit preview on episode': (f) => f.meta['episodes'] = [
      {..._lesson(), 'is_preview': 1},
    ],
    'explicit expiry on account': (f) => f.accountStatus['is_expired'] = true,
    'expired epoch': (f) => f.accountStatus['expire_at'] = _seconds(
      _now.subtract(const Duration(seconds: 1)),
    ),
    'finite purchase metadata without an absolute deadline': (f) {
      f.accountStatus.remove('expire_at');
      f.meta['expiry_day'] = 30;
    },
    'zero expiry without evidence': (f) => f.accountStatus['expire_at'] = 0,
    'watermark required': (f) => f.meta['show_watermark'] = true,
    'watermark unknown': (f) => f.meta.remove('show_watermark'),
    'hidden offline prohibition': (f) =>
        f.meta['permissions'] = {'allow_download': false},
  }.entries) {
    test('rejects ${reason.key} before requesting media', () async {
      reason.value(fixture);
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        _rejected,
      );
      expect(fixture.requests.map((u) => u.path), isNot(contains(_media)));
    });
  }

  for (final reason in <String, void Function(_Fixture)>{
    'DRM': (f) => f.response['is_drm'] = 1,
    'nested DRM': (f) => f.videoTrack['playInfo'] = {'drm_tech_type': 2},
    'unknown DRM': (f) => f.response.remove('is_drm'),
    'unknown nested DRM field': (f) => f.videoTrack['drm_unknown'] = 'future',
    'preview media': (f) => f.response['is_preview'] = true,
    'unknown preview': (f) => f.response.remove('is_preview'),
    'watermark in DASH': (f) => f.videoTrack['watermark'] = true,
    'unknown nested protection object': (f) =>
        f.videoTrack['protection'] = <String, Object?>{'provider': 5},
    'download prohibited': (f) => f.videoTrack['download_allowed'] = false,
    'download denied in nested data': (f) => f.response['flags'] = [
      {'download_forbidden': true},
    ],
    'download disabled alias': (f) => f.response['download_disabled'] = true,
    'incomplete watermark information': (f) =>
        f.response['watermark_interval'] = 60,
    'media episode mismatch': (f) => f.response['ep_id'] = 936,
    'bad media domain': (f) =>
        f.videoTrack['baseUrl'] = 'https://cdn.bilivideo.com.invalid/v.m4s',
    'wrong media container': (f) => f.videoTrack['mimeType'] = 'video/mpeg',
    'unknown video representation': (f) => f.videoTrack['codecs'] = 'unknown',
    'playlist': (f) =>
        f.videoTrack['baseUrl'] = 'https://cdn.bilivideo.com/playlist.m3u8',
    'nonnormal media port': (f) =>
        f.videoTrack['baseUrl'] = 'https://cdn.bilivideo.com:9443/v.m4s',
    'ambiguous expiry entries': (f) => f.videoTrack['baseUrl'] =
        'https://cdn.bilivideo.com/v.m4s?deadline=1795017600&deadline=broken',
    'opaque signature deadline': (f) => f.videoTrack['baseUrl'] =
        'https://cdn.bilivideo.com/v.m4s?upsig=opaque',
    'past expiry': (f) =>
        f.videoTrack['baseUrl'] = _url('v.m4s', const Duration(seconds: -1)),
    'multi-segment': (f) => f.response
      ..remove('dash')
      ..['durl'] = [
        {'url': 'https://cdn.bilivideo.com/a.mp4'},
        {'url': 'https://cdn.bilivideo.com/b.mp4'},
      ],
  }.entries) {
    test('rejects ${reason.key} without trying another stream', () async {
      reason.value(fixture);
      await expectLater(
        fixture.service().authorize(_video, _part, 64),
        _rejected,
      );
      expect(fixture.requests.map((u) => u.path), [
        _nav,
        _paid,
        _season,
        _media,
      ]);
    });
  }

  test('play response envelope cannot hide watermark outside data', () async {
    fixture.hang = _media;
    fixture.pending = Completer<String>();
    final access = fixture.service().authorize(_video, _part, 64);
    await fixture.started.future;
    fixture.pending!.complete(
      jsonEncode({
        'code': 0,
        'data': fixture.playview,
        'envelope': {'show_watermark': true},
      }),
    );
    await expectLater(access, _rejected);
  });

  test(
    'malformed or refused responses never repeat URL, cookie or body',
    () async {
      const sentinel =
          'response https://signed.bilivideo.com/full.mp4 token-value';
      fixture.hang = _media;
      fixture.pending = Completer<String>();
      final access = fixture.service().authorize(_video, _part, 64);
      await fixture.started.future;
      fixture.pending!.completeError(StateError('$sentinel $_cookie'));
      await expectLater(
        access,
        throwsA(
          isA<CourseCacheAccessException>().having(
            (error) => error.message,
            'safe message',
            allOf(isNot(contains('https')), isNot(contains('synthetic'))),
          ),
        ),
      );
    },
  );
}
