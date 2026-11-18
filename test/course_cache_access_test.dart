import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_access.dart';

const _nav = '/x/web-interface/nav';
const _paid = '/pugv/pay/web/my/paid';
const _season = '/pugv/view/web/season';
const _list = '/pugv/view/web/ep/list';
const _media = '/pugv/player/web/playurl';
const _cookie = 'SESSDATA=synthetic-session-header; DedeUserID=51';
const _backupCookie = 'SESSDATA=new-synthetic-session-header; DedeUserID=51';
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

  Map<String, Object?> identity = {'isLogin': true, 'mid': 51};
  String cookie = _cookie;
  DateTime now = _now;
  late List<Map<String, Object?>> purchases;
  late Map<String, Object?> accountStatus;
  late Map<String, Object?> meta;
  late Map<String, Object?> response;
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
      _media => response,
      _list => episodesPage!,
      _ => throw StateError('unexpected endpoint'),
    };
    return _body(data);
  }

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

  @override
  Future<BilibiliPlaybackCookieSnapshot> readPlaybackSession(
    String path,
  ) async {
    paths.add(path);
    return BilibiliPlaybackCookieSnapshot(
      header: _cookie,
      state: 'session',
      generation: generation,
    );
  }

  @override
  Future<bool> validatePlaybackSession(int snapshot, String path) async {
    paths.add(path);
    return snapshot == generation;
  }
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
    'binds complete DASH purchase and exact episode; selected URL TTL is shortest',
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
        'ep_id': '168',
        'cid': '243',
        'qn': '64',
        'fnver': '0',
        'fnval': '16',
        'fourk': '1',
      });
      expect(grant.mid, 51);
      expect(grant.checkedAt, _now);
      expect(grant.validUntil, _now.add(const Duration(hours: 4)));
      expect(grant.media.quality, 64);
      expect(grant.media.audio!.urls, hasLength(2));
      expect(grant.mediaHeaders.keys, isNot(contains('Cookie')));
      expect(grant.mediaHeaders.keys, isNot(contains('Authorization')));
      expect(grant.mediaHeaders.values.join(), isNot(contains(_cookie)));
      await grant.checkSession();
      fixture.now = grant.validUntil;
      await expectLater(grant.checkSession(), _rejected);
      fixture.now = _now.subtract(const Duration(seconds: 1));
      await expectLater(grant.checkSession(), _rejected);
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
    'explicit long-term purchase caps proven single MP4 at 24 hours',
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
      expect(grant.validUntil, _now.add(const Duration(hours: 24)));
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
      expect(native.paths.toSet(), {_media});
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
      fixture.pending!.complete(_body(fixture.response));
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
    'missing purchase deadline': (f) => f.accountStatus.remove('expire_at'),
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
        'data': fixture.response,
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
