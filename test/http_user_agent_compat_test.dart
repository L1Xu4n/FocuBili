import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/app_behavior_preferences_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_http_user_agent.dart';
import 'package:focubili/services/bilibili_request_policy.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/bilibili_video_metadata_client.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/http_user_agent_preferences.dart';
import 'package:focubili/services/native_playback_service.dart';

import 'classroom_access_test.dart' show course;

const _ua = 'LocalQaClient/1.0 (Synthetic Fixture)';
const _ordinaryBvid = 'BV1000000000';
const _cookie = 'SESSDATA=local-session-fixture; DedeUserID=123';
const _goodRights = {
  'pay': 0,
  'ugc_pay': 0,
  'ugc_pay_preview': 0,
  'arc_pay': 0,
  'movie': 0,
};
const _parts = [
  VideoPart(
    pageNumber: 1,
    cid: 100,
    title: 'P1',
    duration: Duration(seconds: 60),
  ),
];
const _ordinary = VideoPreview(
  bvid: _ordinaryBvid,
  cid: 100,
  title: '普通投稿',
  ownerName: '',
  parts: _parts,
  isKnownUnrestrictedUpload: true,
);
const _offline = VideoPreview(
  bvid: _ordinaryBvid,
  cid: 100,
  title: '此前的缓存资料',
  ownerName: '',
  parts: _parts,
  fromOfflineCache: true,
  isKnownUnrestrictedUpload: true,
);
const _unknown = VideoPreview(
  bvid: _ordinaryBvid,
  cid: 100,
  title: '权限资料未知',
  ownerName: '',
  parts: _parts,
);

class _Cookies implements BilibiliCookieStore {
  String value = _cookie;
  int writes = 0;

  @override
  Future<String> readCookies() async => value;
  @override
  Future<void> replaceCookies(String header) async {
    writes++;
    value = header;
  }

  @override
  Future<void> clearBilibiliCookies() async {
    writes++;
    value = '';
  }
}

class _RealHttp extends HttpOverrides {}

/// Only the socket destination is changed. The actual production adapters
/// configure and send their own headers through a real Dart HttpClient.
class _LoopbackClient implements HttpClient {
  _LoopbackClient(this.client, this.port, this.officialRequests);
  final HttpClient client;
  final int port;
  final List<Uri> officialRequests;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    if (uri.scheme != 'https' ||
        !{'api.bilibili.com', 's.search.bilibili.com'}.contains(uri.host)) {
      throw StateError('The offline fixture only accepts explicit API hosts.');
    }
    officialRequests.add(uri);
    return client.getUrl(
      Uri.http('127.0.0.1:$port', uri.path).replace(query: uri.query),
    );
  }

  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Seen = ({String path, String? ua, String? cookie, String? referer});

class _Api {
  _Api(this.server) {
    server.listen((request) async {
      final path = request.uri.path;
      received.add((
        path: path,
        ua: request.headers.value(HttpHeaders.userAgentHeader),
        cookie: request.headers.value(HttpHeaders.cookieHeader),
        referer: request.headers.value(HttpHeaders.refererHeader),
      ));
      final response = request.response;
      final status = deny[path];
      if (status != null) {
        response.statusCode = status;
        response.write('private-test-body');
      } else if (redirect[path] case final target?) {
        response.statusCode = 302;
        response.headers.set(HttpHeaders.locationHeader, '/$target');
      } else {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(_reply(path)));
      }
      await response.close();
    });
  }

  final HttpServer server;
  final received = <_Seen>[];
  final requestedOfficialUris = <Uri>[];
  final deny = <String, int>{};
  final redirect = <String, String>{};
  final responseOverrides = <String, Object>{};

  Object _reply(String path) =>
      responseOverrides[path] ??
      switch (path) {
        '/x/web-interface/view' || '/x/web-interface/wbi/view' => {
          'code': 0,
          'data': {
            'title': '合成投稿',
            'bvid': _ordinaryBvid,
            'cid': 100,
            'duration': 60,
            'rights': _goodRights,
            'is_upower_exclusive': false,
            'is_upower_play': false,
          },
        },
        '/x/tag/archive/tags' => {
          'code': 0,
          'data': [
            {'tag_name': '本地测试'},
          ],
        },
        '/x/web-interface/wbi/search/type' => {
          'code': 0,
          'data': {'numPages': 1, 'numResults': 0, 'result': []},
        },
        '/main/suggest' => {'code': 0, 'result': []},
        '/x/web-interface/nav' => {
          'code': 0,
          'data': {
            'isLogin': true,
            'wbi_img': {
              'img_url':
                  'https://i0.hdslb.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png',
              'sub_url':
                  'https://i0.hdslb.com/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png',
            },
          },
        },
        '/pugv/pay/web/my/paid' => {
          'code': 0,
          'data': {
            'total': 1,
            'data': [
              {'id': course.courseSeasonId, 'is_expired': false, 'status': 1},
            ],
          },
        },
        '/x/player/playurl' ||
        '/x/player/wbi/playurl' ||
        '/pugv/player/web/playurl' => {
          'code': 0,
          'data': {
            'quality': 64,
            'dash': {
              'video': [
                {
                  'id': 64,
                  'codecs': 'avc1.640028',
                  'base_url': 'https://a.bilivideo.com/local-fixture.m4s',
                },
              ],
              'audio': [
                {
                  'codecs': 'mp4a.40.2',
                  'base_url': 'https://a.bilivideo.com/local-audio.m4s',
                },
              ],
            },
          },
        },
        _ => {'code': -404},
      };

  Future<T> run<T>(Future<T> Function() fn) => HttpOverrides.runZoned(
    fn,
    createHttpClient: (context) => _LoopbackClient(
      _RealHttp().createHttpClient(context),
      server.port,
      requestedOfficialUris,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const prefs = HttpUserAgentPreferences();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final before = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = before);
  });

  Future<_Api> localApi() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    return _Api(server);
  }

  test(
    'input accepts product lists and rejects unsafe or malformed header values',
    () {
      expect(HttpUserAgentInput.normalize('  $_ua '), _ua);
      expect(
        HttpUserAgentInput.normalize('First/1 (nested (ok) \\)) Second/2'),
        isNotNull,
      );
      expect(HttpUserAgentInput.normalize('   '), isNull);
      expect(HttpUserAgentInput.normalize('a' * 512), hasLength(512));
      for (final value in [
        'a' * 513,
        'Client/1\rInjected: x',
        'Client/1\nInjected: x',
        'Client/1\t',
        'Client/1\u0000',
        'Client/1\u007f',
        '客户端/1',
        'X = Token',
        'Product/',
        '(without product)',
        'Product (unclosed',
        'NoSpace/1(no space)',
      ]) {
        expect(
          () => HttpUserAgentInput.normalize(value),
          throwsFormatException,
          reason: value,
        );
      }
    },
  );

  test(
    'default and failed writes do not install a value; reset removes the key',
    () async {
      expect(await prefs.load(), isNull);
      await prefs.save(' $_ua ');
      expect(await const HttpUserAgentPreferences().forRequest(), _ua);
      await expectLater(prefs.save('bad\r\n'), throwsFormatException);
      expect(await prefs.load(), _ua);
      final broken = HttpUserAgentPreferences(
        readValue: () async => _ua,
        writeValue: (_) async =>
            throw const FileSystemException('private failure'),
      );
      await expectLater(
        broken.save('NewClient/2'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await broken.forRequest(), _ua);
      await prefs.save('  ');
      expect(await prefs.load(), isNull);
      expect(
        await SharedPreferencesAsync().containsKey(
          HttpUserAgentPreferences.storageKey,
        ),
        isFalse,
      );
      await SharedPreferencesAsync().setString(
        HttpUserAgentPreferences.storageKey,
        'corrupt\nraw',
      );
      expect(await prefs.forRequest(), isNull);
    },
  );

  test(
    'metadata whitelist does not match login, nav, course, CDN or wrong origins',
    () {
      for (final path in [
        '/x/web-interface/view',
        '/x/web-interface/wbi/view',
        '/x/player/pagelist',
        '/x/tag/archive/tags',
        '/x/web-interface/wbi/search/type',
      ]) {
        expect(
          BilibiliHttpUserAgent.allowsMetadata(
            Uri.https('api.bilibili.com', path),
          ),
          isTrue,
        );
      }
      expect(
        BilibiliHttpUserAgent.allowsMetadata(
          Uri.https('s.search.bilibili.com', '/main/suggest'),
        ),
        isTrue,
      );
      for (final raw in [
        'https://api.bilibili.com/x/web-interface/nav',
        'https://passport.bilibili.com/h5-app/passport/login',
        'https://api.bilibili.com/pugv/player/web/playurl',
        'https://api.bilibili.com/x/player/wbi/playurl',
        'https://a.bilivideo.com/x/web-interface/view',
        'https://api.bilibili.com.fake.invalid/x/web-interface/view',
        'https://acct@api.bilibili.com/x/web-interface/view',
        'https://api.bilibili.com:84/x/web-interface/view',
        'http://api.bilibili.com/x/web-interface/view',
      ]) {
        expect(
          BilibiliHttpUserAgent.allowsMetadata(Uri.parse(raw)),
          isFalse,
          reason: raw,
        );
      }
    },
  );

  test(
    'video rights classification is fail-closed and remains true through tags',
    () {
      final positive = {
        'rights': _goodRights,
        'is_upower_exclusive': false,
        'is_upower_play': false,
      };
      expect(
        BilibiliHttpUserAgent.isUnrestrictedUploadResponse(positive),
        isTrue,
      );
      for (final change in [
        {'rights': null},
        {
          'rights': {'pay': 0},
        },
        {
          'rights': {..._goodRights, 'ugc_pay': 1},
        },
        {
          'rights': {..._goodRights, 'is_drm': 1},
        },
        {'is_upower_exclusive': true},
        {'is_upower_play': null},
        {
          'is_drm': {'unknown': true},
        },
        {
          'ugc_season': {'is_pay_season': true},
        },
        {'ugc_season': {}},
      ]) {
        expect(
          BilibiliHttpUserAgent.isUnrestrictedUploadResponse({
            ...positive,
            ...change,
          }),
          isFalse,
          reason: '$change',
        );
      }
      expect(_ordinary.withTags(['extra']).isKnownUnrestrictedUpload, isTrue);
    },
  );

  test(
    'real Dart public APIs use default, selected value and restored default on local wire',
    () async {
      final api = await localApi();
      final service = BilibiliVideoInfoService(
        metadataClient: BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: _Cookies()..value = ''),
        ),
      );
      await api.run(() async {
        final ordinary = await service.lookupVideo(_ordinaryBvid);
        expect(ordinary.isKnownUnrestrictedUpload, isTrue);
        expect(ordinary.tags, ['本地测试']);
        expect(api.received.map((call) => call.path), [
          '/x/web-interface/nav',
          '/x/web-interface/wbi/view',
          '/x/tag/archive/tags',
        ]);
        final original = api.received[1].ua;
        final originalReferer = api.received[1].referer;
        expect(api.received.first.ua, original);
        expect(original, isNotEmpty);
        api.received.clear();
        await prefs.save(_ua);
        await service.lookupVideo(_ordinaryBvid);
        await service.searchVideos('example fixture');
        await service.searchUsers('example fixture');
        await service.suggestKeywords('example fixture');
        expect(api.received.map((call) => call.path), [
          '/x/web-interface/wbi/view',
          '/x/tag/archive/tags',
          '/x/web-interface/wbi/search/type',
          '/x/web-interface/wbi/search/type',
          '/main/suggest',
        ]);
        expect(
          api.received.every((call) => call.ua == _ua && call.cookie == null),
          isTrue,
        );
        expect(api.received.first.referer, originalReferer);
        api.received.clear();
        await prefs.save('');
        await service.lookupVideo(_ordinaryBvid);
        expect(api.received.every((call) => call.ua == original), isTrue);
      });
    },
  );

  test(
    'local HTTP rejection and redirects stop after one custom public request',
    () async {
      final api = await localApi();
      final service = BilibiliVideoInfoService();
      await prefs.save(_ua);
      const path = '/x/web-interface/wbi/search/type';
      await api.run(() async {
        for (final status in [403, 412]) {
          api.deny[path] = status;
          api.received.clear();
          await expectLater(
            service.searchVideos('local request'),
            throwsA(
              isA<BilibiliLookupException>().having(
                (e) => e.message,
                'message',
                contains('HTTP $status'),
              ),
            ),
          );
          expect(api.received, hasLength(1));
          expect(api.received.single.ua, _ua);
        }
        api.deny.clear();
        api.redirect[path] = 'not-allowed';
        api.received.clear();
        await expectLater(
          service.searchVideos('local request'),
          throwsA(isA<BilibiliLookupException>()),
        );
        expect(api.received.map((call) => call.path), [path]);
      });
    },
  );

  test(
    'desktop playback changes only confirmed playurl, not signing, media or course',
    () async {
      final api = await localApi();
      final cookies = _Cookies();
      final service = BilibiliDesktopPlaybackSourceService(
        authService: BilibiliAuthService(cookieStore: cookies),
      );
      final behavior = AppBehaviorPreferencesService();
      await behavior.saveWbiSigningEnabled(true);
      await prefs.save(_ua);
      await api.run(() async {
        final sources = await service.loadForVideo(
          video: _ordinary,
          cid: 100,
          quality: 64,
        );
        final defaultUa = BilibiliDesktopPlaybackSourceService.desktopUserAgent;
        expect(api.received.map((req) => (req.path, req.ua)), [
          ('/x/web-interface/nav', defaultUa),
          ('/x/player/wbi/playurl', _ua),
        ]);
        expect(
          api.received.every(
            (req) =>
                req.cookie?.contains('SESSDATA=local-session-fixture') == true,
          ),
          isTrue,
        );
        expect(
          api.requestedOfficialUris.last.queryParameters.keys,
          containsAll(['w_rid', 'wts']),
        );
        expect(sources.mediaHeaders['User-Agent'], defaultUa);
        expect(sources.mediaHeaders, isNot(contains('Cookie')));
        expect(cookies.writes, 0);
        api.received.clear();

        await service.loadForVideo(video: _ordinary, cid: 100, quality: 80);
        await service.loadForVideo(video: _unknown, cid: 100, quality: 64);
        await service.loadForVideo(video: _offline, cid: 100, quality: 64);
        await service.load(bvid: _ordinaryBvid, cid: 100, quality: 64);
        await service.loadCourse(
          video: course,
          part: course.initialPart,
          quality: 64,
        );
        expect(api.received.map((call) => call.ua).toSet(), {defaultUa});
        expect(
          api.received.map((call) => call.path),
          contains('/pugv/player/web/playurl'),
        );
        expect(cookies.value, _cookie);
      });
    },
  );

  test(
    'desktop does not retry an HTTP or JSON rejection with another identity',
    () async {
      final api = await localApi();
      final cookies = _Cookies();
      final service = BilibiliDesktopPlaybackSourceService(
        authService: BilibiliAuthService(cookieStore: cookies),
      );
      await prefs.save(_ua);
      await api.run(() async {
        const path = '/x/player/playurl';
        api.deny[path] = 412;
        await expectLater(
          service.loadForVideo(video: _ordinary, cid: 100, quality: 64),
          throwsA(
            isA<DesktopPlaybackSourceException>().having(
              (e) => e.httpStatus,
              'HTTP status',
              412,
            ),
          ),
        );
        expect(api.received.map((call) => (call.path, call.ua)), [(path, _ua)]);
        api.deny.clear();
        api.responseOverrides[path] = {'code': -403, 'message': 'denied'};
        api.received.clear();
        await expectLater(
          service.loadForVideo(video: _ordinary, cid: 100, quality: 64),
          throwsA(
            isA<DesktopPlaybackSourceException>().having(
              (e) => e.apiCode,
              'API code',
              -403,
            ),
          ),
        );
        expect(api.received.map((call) => (call.path, call.ua)), [(path, _ua)]);
        expect(cookies.value, _cookie);
        expect(cookies.writes, 0);
      });
    },
  );

  test(
    'Android channel forwards confirmed ordinary selection; other opens preserve defaults',
    () async {
      const channel = MethodChannel('com.focubili.app/playback');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await prefs.save(_ua);
      final service = NativePlaybackService(appPlatform: AppPlatform.android);
      await service.openVideo(_ordinary);
      expect(calls.last.arguments, containsPair('ordinaryApiUserAgent', _ua));
      expect(
        calls.last.arguments,
        containsPair('ordinaryApiUserAgentAllowed', true),
      );
      await service.selectQuality(32);
      expect(calls.last.arguments, containsPair('ordinaryApiUserAgent', _ua));
      await service.selectQuality(80);
      expect(calls.last.arguments, isNot(contains('ordinaryApiUserAgent')));
      await prefs.save('');
      await service.selectQuality(64);
      expect(calls.last.arguments, isNot(contains('ordinaryApiUserAgent')));
      await prefs.save(_ua);
      for (final video in [course, _unknown, _offline]) {
        await service.openVideo(video);
        expect(calls.last.arguments, isNot(contains('ordinaryApiUserAgent')));
        expect(
          calls.last.arguments,
          isNot(contains('ordinaryApiUserAgentAllowed')),
        );
        await service.selectQuality(64);
        expect(calls.last.arguments, isNot(contains('ordinaryApiUserAgent')));
      }
      await service.openLocalFile(filePath: '/synthetic/test-only.mp4');
      expect(calls.last.arguments, isNot(contains('ordinaryApiUserAgent')));
      await service.dispose();
      final notAndroid = NativePlaybackService(appPlatform: AppPlatform.ios);
      await notAndroid.openVideo(_ordinary);
      expect(calls.last.arguments, isNot(contains('ordinaryApiUserAgent')));
      await notAndroid.dispose();
      expect(
        BilibiliRequestPolicy.ensureMobileWebUserAgent('Platform/1 Mobile'),
        'Platform/1 Mobile',
      );
    },
  );

  test(
    'WBI details keeps signing and cookies while a preference change fences in-flight details',
    () async {
      final firstSeen = Completer<void>();
      final releaseFirst = Completer<void>();
      addTearDown(() {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
      });
      final observed = <(Uri, Map<String, String>)>[];
      final cookies = _Cookies();
      final meta = BilibiliVideoMetadataClient(
        authService: BilibiliAuthService(cookieStore: cookies),
        transport: (uri, headers) async {
          observed.add((uri, Map.of(headers)));
          if (uri.path == '/x/web-interface/nav') {
            return const VideoMetadataResponse(
              200,
              '{"code":0,"data":{"isLogin":true,"wbi_img":{'
              '"img_url":"https://i0.hdslb.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png",'
              '"sub_url":"https://i0.hdslb.com/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png"}}}',
            );
          }
          if (headers['User-Agent'] == _ua) {
            firstSeen.complete();
            await releaseFirst.future;
          }
          return VideoMetadataResponse(
            200,
            jsonEncode({'code': 0, 'data': headers['User-Agent']}),
          );
        },
      );
      Future<String> detail({bool full = true}) => meta.load(
        bvid: _ordinaryBvid,
        details: full,
        parse: (body) => (jsonDecode(body) as Map)['data'] as String,
      );
      await prefs.save(_ua);
      final first = detail();
      await firstSeen.future;
      await prefs.save('AnotherFixture/2');
      expect(await detail(), 'AnotherFixture/2');
      expect(await detail(full: false), 'AnotherFixture/2');
      releaseFirst.complete();
      expect(await first, _ua);
      await prefs.save('');
      final unchanged = await detail();

      expect(observed.map((request) => request.$1.path), [
        '/x/web-interface/nav',
        '/x/web-interface/wbi/view',
        '/x/web-interface/wbi/view',
        '/x/player/pagelist',
        '/x/web-interface/wbi/view',
      ]);
      expect(observed.first.$2['User-Agent'], unchanged);
      expect(
        observed[1].$1.queryParameters.keys,
        containsAll(['w_rid', 'wts']),
      );
      expect(
        observed[2].$1.queryParameters.keys,
        containsAll(['w_rid', 'wts']),
      );
      expect(
        observed.every(
          (request) =>
              request.$2['Cookie']?.contains(
                'SESSDATA=local-session-fixture',
              ) ==
              true,
        ),
        isTrue,
      );
      expect(cookies.writes, 0);
    },
  );
}
