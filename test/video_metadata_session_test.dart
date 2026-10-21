import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/platform/platform_services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_metadata_request_diagnostic.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/bilibili_video_metadata_client.dart';
import 'package:focubili/services/bilibili_wbi_signing_service.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';

const _bvid = 'BV1GJ411x7h7';
const _secret = 'synthetic-secret-do-not-export';
const _nav =
    '{"code":-101,"data":{"wbi_img":{'
    '"img_url":"https://i0.hdslb.com/7cd084941338484aae1ad9425b84077c.png",'
    '"sub_url":"https://i0.hdslb.com/4932caff0ff746eab6f01bf08b70ac45.png"}}}';
const _view =
    '{"code":0,"data":{"bvid":"$_bvid","cid":101,"title":"complete title",'
    '"owner":{"name":"author"},"pages":[{"page":1,"cid":101,"part":"one","duration":12}]}}';
const _parts =
    '{"code":0,"data":[{"page":2,"cid":102,"part":"two","duration":20},'
    '{"page":1,"cid":101,"part":"one","duration":12}]}';

class _Cookies implements BilibiliCookieStore {
  _Cookies([this.value = 'SESSDATA=$_secret']);
  String value;
  int writes = 0;
  @override
  Future<String> readCookies() async => value;
  @override
  Future<void> replaceCookies(String cookieHeader) async {
    writes++;
    value = cookieHeader;
  }

  @override
  Future<void> clearBilibiliCookies() async {
    writes++;
    value = '';
  }
}

class _NativeCookies extends _Cookies implements BilibiliPlaybackSessionStore {
  int generation = 0;
  String state = 'session';
  final paths = <String>[];
  final merges = <String>[];
  @override
  Future<BilibiliPlaybackCookieSnapshot> readPlaybackSession(
    String path,
  ) async {
    paths.add(path);
    return BilibiliPlaybackCookieSnapshot(
      header: value,
      state: state,
      generation: generation,
    );
  }

  @override
  Future<bool> validatePlaybackSession(int revision, String path) async =>
      revision == generation;
  @override
  Future<BilibiliPlaybackCookieSnapshot> mergePlaybackResponseCookies(
    int revision,
    String path,
    List<String> cookies,
  ) async {
    if (revision != generation) {
      throw const BilibiliPlaybackSessionException('changing');
    }
    merges.add(path);
    value += '; bili_ticket=synthetic-ticket';
    return readPlaybackSession(path);
  }
}

class _LoginApi implements BilibiliAuthApi {
  @override
  Future<BilibiliNavResponse> requestNavigation(
    String cookieHeader,
  ) async => const BilibiliNavResponse(
    statusCode: 200,
    body:
        '{"code":0,"data":{"isLogin":true,"mid":123,"uname":"synthetic-account","face":""}}',
  );
}

class _Diagnostics extends ProblemDiagnosticsService {
  final entries = <VideoMetadataRequestDiagnostic>[];
  @override
  Future<void> recordVideoMetadataRequest(
    VideoMetadataRequestDiagnostic diagnostic, {
    required bool details,
  }) async {
    entries.add(diagnostic);
  }
}

VideoSearchResult _result({int cid = 0}) => VideoSearchResult(
  bvid: _bvid,
  cid: cid,
  title: 'search title',
  ownerName: 'author',
  duration: const Duration(seconds: 12),
  thumbnailUrl: '',
  publishedAt: null,
  playCount: 0,
  danmakuCount: 0,
  episodeCountText: '',
);

BilibiliVideoInfoService _service(BilibiliVideoMetadataClient client) =>
    BilibiliVideoInfoService(
      metadataClient: client,
      requestJson: (_) async => '{"code":0,"data":[]}',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'app_behavior.wbi_signing_enabled': false,
      'app_behavior.account_read_only': true,
    }),
  );

  for (final loggedIn in [true, false]) {
    test(
      'details use current ${loggedIn ? 'login' : 'anonymous'} session and WBI with playback toggle off and read-only on',
      () async {
        final cookies = _Cookies(loggedIn ? 'SESSDATA=$_secret' : '');
        final requested = <Uri>[];
        final diagnostics = _Diagnostics();
        final client = BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: cookies),
          diagnostics: diagnostics,
          transport: (uri, headers) async {
            requested.add(uri);
            expect(headers['Cookie'], loggedIn ? 'SESSDATA=$_secret' : isNull);
            if (uri.path.endsWith('/nav')) {
              return const VideoMetadataResponse(200, _nav);
            }
            expect(uri.path, BilibiliVideoMetadataClient.viewPath);
            expect(
              headers['Referer'],
              'https://www.bilibili.com/video/$_bvid/',
            );
            final query = uri.queryParameters;
            final key = BilibiliWbiSigningService.deriveMixinKey(
              '7cd084941338484aae1ad9425b84077c',
              '4932caff0ff746eab6f01bf08b70ac45',
            );
            expect(
              query['w_rid'],
              BilibiliWbiSigningService.sign(
                {'bvid': _bvid},
                key,
                int.parse(query['wts']!),
              )['w_rid'],
            );
            return const VideoMetadataResponse(200, _view);
          },
        );
        final video = await _service(client).lookupVideo(_bvid);
        expect(video.cid, 101);
        expect(requested.map((uri) => uri.path), [
          '/x/web-interface/nav',
          BilibiliVideoMetadataClient.viewPath,
        ]);
        expect(
          diagnostics.entries.last.fields['auth_state'],
          loggedIn ? 'session_present_unverified' : 'anonymous',
        );
        expect(diagnostics.entries.last.fields['wbi_signed'], 'true');
        expect(cookies.writes, 0);
      },
    );
  }

  for (final business in [false, true]) {
    test(
      '${business ? 'business -412' : 'HTTP 412'} is distinct, redacted, no retry and no cookie mutation',
      () async {
        final cookies = _Cookies();
        final diagnostics = _Diagnostics();
        final paths = <String>[];
        final service = _service(
          BilibiliVideoMetadataClient(
            authService: BilibiliAuthService(cookieStore: cookies),
            diagnostics: diagnostics,
            transport: (uri, _) async {
              paths.add(uri.path);
              if (uri.path.endsWith('/nav')) {
                return const VideoMetadataResponse(200, _nav);
              }
              return VideoMetadataResponse(
                business ? 200 : 412,
                '{"code":-412,"message":"$_secret https://private.invalid/?w_rid=secret"}',
              );
            },
          ),
        );
        Object? failure;
        try {
          await service.lookupVideo(_bvid);
        } catch (error) {
          failure = error;
        }
        expect(failure, isA<BilibiliLookupException>());
        expect(failure.toString(), isNot(contains(_secret)));
        final facts = diagnostics.entries.last.fields;
        expect(facts['http_status'], business ? '200' : '412');
        expect(facts['api_code'], business ? '-412' : isNull);
        expect(facts['endpoint_kind'], 'view_wbi');
        expect(facts['outcome'], 'error');
        expect(jsonEncode(facts), isNot(contains(_secret)));
        expect(jsonEncode(facts), isNot(contains('w_rid')));
        expect(paths, hasLength(2));
        expect(cookies.writes, 0);
      },
    );
  }

  test(
    'signing HTTP failure never attempts details or falls back to legacy endpoint',
    () async {
      final diagnostics = _Diagnostics();
      final paths = <String>[];
      final service = _service(
        BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: _Cookies()),
          diagnostics: diagnostics,
          transport: (uri, _) async {
            paths.add(uri.path);
            return const VideoMetadataResponse(412, _secret);
          },
        ),
      );
      await expectLater(
        service.lookupVideo(_bvid),
        throwsA(
          isA<BilibiliLookupException>().having(
            (e) => e.httpStatus,
            'HTTP',
            412,
          ),
        ),
      );
      expect(paths, ['/x/web-interface/nav']);
      expect(diagnostics.entries.last.fields, containsPair('stage', 'signing'));
      expect(
        diagnostics.entries.last.fields,
        containsPair('endpoint_kind', 'nav'),
      );
    },
  );

  test('malformed signing material is safe and stops', () async {
    var calls = 0;
    final service = _service(
      BilibiliVideoMetadataClient(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        diagnostics: _Diagnostics(),
        transport: (_, _) async {
          calls++;
          return const VideoMetadataResponse(
            200,
            '{"code":0,"data":"$_secret"}',
          );
        },
      ),
    );
    await expectLater(
      service.lookupVideo(_bvid),
      throwsA(
        isA<BilibiliLookupException>().having(
          (e) => e.message,
          'safe',
          isNot(contains(_secret)),
        ),
      ),
    );
    expect(calls, 1);
  });

  test(
    'concurrent detail requests share nav and detail, failures are not cached',
    () async {
      final gate = Completer<VideoMetadataResponse>();
      final started = Completer<void>();
      final diagnostics = _Diagnostics();
      var calls = 0;
      final service = _service(
        BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: _Cookies()),
          diagnostics: diagnostics,
          transport: (uri, _) async {
            calls++;
            if (uri.path.endsWith('/nav')) {
              return const VideoMetadataResponse(200, _nav);
            }
            if (!started.isCompleted) {
              started.complete();
              return gate.future;
            }
            return const VideoMetadataResponse(200, _view);
          },
        ),
      );
      final first = service.lookupVideo(_bvid);
      final second = service.lookupVideo(_bvid);
      await started.future;
      final failures = [
        expectLater(first, throwsA(isA<BilibiliLookupException>())),
        expectLater(second, throwsA(isA<BilibiliLookupException>())),
      ];
      gate.complete(const VideoMetadataResponse(412, _secret));
      await Future.wait(failures);
      expect(calls, 2);
      expect(
        diagnostics.entries.any((e) => e.fields['dedup_shared'] == 'true'),
        isTrue,
      );
      expect((await service.lookupVideo(_bvid)).cid, 101);
      expect(calls, 3);
    },
  );

  for (final native in [false, true]) {
    test(
      '${native ? 'WK generation change' : 'logout'} rejects late signed results and isolates next request',
      () async {
        final cookies = native ? _NativeCookies() : _Cookies();
        final auth = BilibiliAuthService(cookieStore: cookies);
        final gate = Completer<VideoMetadataResponse>();
        final started = Completer<void>();
        final diagnostics = _Diagnostics();
        var views = 0, navs = 0;
        final client = BilibiliVideoMetadataClient(
          authService: auth,
          diagnostics: diagnostics,
          transport: (uri, headers) async {
            if (uri.path.endsWith('/nav')) {
              navs++;
              return const VideoMetadataResponse(200, _nav);
            }
            views++;
            if (views == 1) {
              started.complete();
              return gate.future;
            }
            return const VideoMetadataResponse(200, _view);
          },
        );
        final service = _service(client);
        final old = service.lookupVideo(_bvid);
        final rejected = expectLater(
          old,
          throwsA(isA<BilibiliPlaybackSessionException>()),
        );
        await started.future;
        if (cookies is _NativeCookies) {
          cookies.generation++;
          cookies.value = '';
          cookies.state = 'anonymous';
        } else {
          await auth.logout();
        }
        final next = service.lookupVideo(_bvid);
        expect((await next).cid, 101);
        gate.complete(
          const VideoMetadataResponse(
            200,
            _view,
            cookies: ['bili_ticket=$_secret'],
          ),
        );
        await rejected;
        expect(navs, 2);
        expect(views, 2);
        expect(diagnostics.entries.last.fields['session_read'], 'changing');
        if (cookies is _NativeCookies) expect(cookies.merges, isEmpty);
      },
    );
  }

  test(
    'native path snapshots and accepted server cookies are reused by signed details',
    () async {
      final cookies = _NativeCookies();
      final service = _service(
        BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: cookies),
          diagnostics: _Diagnostics(),
          transport: (uri, headers) async {
            if (uri.path.endsWith('/nav')) {
              return const VideoMetadataResponse(
                200,
                _nav,
                cookies: ['bili_ticket=synthetic-ticket'],
              );
            }
            expect(headers['Cookie'], contains('bili_ticket=synthetic-ticket'));
            return const VideoMetadataResponse(200, _view);
          },
        ),
      );
      await service.lookupVideo(_bvid);
      expect(
        cookies.paths,
        containsAll([
          '/x/web-interface/nav',
          BilibiliVideoMetadataClient.viewPath,
        ]),
      );
      expect(cookies.merges, ['/x/web-interface/nav']);
      expect(cookies.writes, 0);
    },
  );

  test(
    'existing CID resolves immediately; absent CID resolves real sorted parts without nav/details',
    () async {
      final paths = <String>[];
      final service = _service(
        BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: _Cookies()),
          diagnostics: _Diagnostics(),
          transport: (uri, _) async {
            paths.add(uri.path);
            return const VideoMetadataResponse(200, _parts);
          },
        ),
      );
      final known = await service.resolveSearchVideo(_result(cid: 999));
      expect(known.cid, 999);
      expect(paths, isEmpty);
      expect(known.detailsComplete, isFalse);
      final resolved = await service.resolveSearchVideo(_result());
      expect(resolved.cid, 101);
      expect(resolved.parts.map((part) => part.cid), [101, 102]);
      expect(paths, [BilibiliVideoMetadataClient.partsPath]);
    },
  );

  for (final body in [
    '{"code":0,"data":[]}',
    '{"code":0,"data":[{"page":1,"cid":0}]}',
    '{"code":0,"data":[{"page":2,"cid":102}]}',
    '{"code":0,"data":[{"page":1,"cid":101.5}]}',
  ]) {
    test('invalid pagelist never fabricates a CID: $body', () async {
      final service = _service(
        BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: _Cookies()),
          diagnostics: _Diagnostics(),
          transport: (_, _) async => VideoMetadataResponse(200, body),
        ),
      );
      await expectLater(
        service.resolveSearchVideo(_result()),
        throwsA(isA<BilibiliLookupException>()),
      );
    });
  }

  test('diagnostic whitelist rejects dynamic content and invalid types', () {
    final diagnostic = VideoMetadataRequestDiagnostic.fromMap({
      'request_id': 1,
      'http_status': 412,
      'api_code': -412,
      'stage': _secret,
      'endpoint_kind': 'https://private.invalid',
      'Cookie': _secret,
      'url': _secret,
      'message': _secret,
      'bvid': _bvid,
      'wbi_signed': _secret,
      'session_source': _secret,
    })!;
    expect(diagnostic.fields['http_status'], '412');
    expect(diagnostic.fields['api_code'], '-412');
    expect(diagnostic.fields['stage'], 'unknown');
    expect(jsonEncode(diagnostic.fields), isNot(contains(_secret)));
    expect(diagnostic.fields.containsKey('url'), isFalse);
    expect(diagnostic.fields.containsKey('wbi_signed'), isFalse);
  });
  for (final state in ['partial', 'conflict', 'unknown']) {
    test('native $state session stops before signing or request', () async {
      final cookies = _NativeCookies()..state = state;
      var calls = 0;
      final service = _service(
        BilibiliVideoMetadataClient(
          authService: BilibiliAuthService(cookieStore: cookies),
          diagnostics: _Diagnostics(),
          transport: (_, _) async {
            calls++;
            return const VideoMetadataResponse(200, _view);
          },
        ),
      );
      await expectLater(
        service.lookupVideo(_bvid),
        throwsA(isA<BilibiliPlaybackSessionException>()),
      );
      expect(calls, 0);
    });
  }

  test('logout during optional tags discards complete details', () async {
    final auth = BilibiliAuthService(cookieStore: _Cookies());
    final tagGate = Completer<String>(), tagStarted = Completer<void>();
    final service = BilibiliVideoInfoService(
      metadataClient: BilibiliVideoMetadataClient(
        authService: auth,
        diagnostics: _Diagnostics(),
        transport: (uri, _) async => VideoMetadataResponse(
          200,
          uri.path.endsWith('/nav') ? _nav : _view,
        ),
      ),
      requestJson: (_) {
        tagStarted.complete();
        return tagGate.future;
      },
    );
    final old = service.lookupVideo(_bvid);
    final rejected = expectLater(
      old,
      throwsA(isA<BilibiliPlaybackSessionException>()),
    );
    await tagStarted.future;
    await auth.logout();
    tagGate.complete('{"code":0,"data":[]}');
    await rejected;
  });

  test(
    'pagelist concurrency shares one request and rejects results after logout',
    () async {
      final auth = BilibiliAuthService(cookieStore: _Cookies());
      final gate = Completer<VideoMetadataResponse>(),
          started = Completer<void>();
      var calls = 0;
      final service = _service(
        BilibiliVideoMetadataClient(
          authService: auth,
          diagnostics: _Diagnostics(),
          transport: (_, _) async {
            calls++;
            if (!started.isCompleted) started.complete();
            return gate.future;
          },
        ),
      );
      final first = service.resolveSearchVideo(_result()),
          second = service.resolveSearchVideo(_result());
      final rejected = [
        expectLater(first, throwsA(isA<BilibiliPlaybackSessionException>())),
        expectLater(second, throwsA(isA<BilibiliPlaybackSessionException>())),
      ];
      await started.future;
      await auth.logout();
      gate.complete(const VideoMetadataResponse(200, _parts));
      await Future.wait(rejected);
      expect(calls, 1);
    },
  );

  test('cached offline replacement cannot cross native generation', () async {
    final cookies = _NativeCookies();
    final gate = Completer<VideoPreview?>(),
        fallbackStarted = Completer<void>();
    final client = BilibiliVideoMetadataClient(
      authService: BilibiliAuthService(cookieStore: cookies),
      diagnostics: _Diagnostics(),
      transport: (_, _) async => const VideoMetadataResponse(412, _secret),
    );
    final old = client.load<VideoPreview>(
      bvid: _bvid,
      details: true,
      parse: (_) => VideoPreview.placeholder(),
      offlineFallback: () {
        fallbackStarted.complete();
        return gate.future;
      },
    );
    final rejected = expectLater(
      old,
      throwsA(isA<BilibiliPlaybackSessionException>()),
    );
    await fallbackStarted.future;
    cookies.generation++;
    gate.complete(VideoPreview.placeholder());
    await rejected;
  });

  for (final platform in [
    AppPlatform.android,
    AppPlatform.windows,
    AppPlatform.macos,
    AppPlatform.ios,
  ]) {
    test(
      'shared details and pagelist use ${platform.name} cookie adapter',
      () async {
        const channel = MethodChannel('com.focubili.app/auth');
        final bridgeCalls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              bridgeCalls.add(call.method);
              if (call.method == 'readCookies') return 'SESSDATA=$_secret';
              if (call.method == 'validatePlaybackSession') return true;
              if (call.method == 'readPlaybackSession') {
                return {
                  'state': 'session',
                  'header': 'SESSDATA=$_secret',
                  'generation': 42,
                };
              }
              throw StateError('Unexpected bridge mutation');
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        FlutterSecureStorage.setMockInitialValues({
          'focubili_bilibili_cookie': 'SESSDATA=$_secret',
        });
        final diagnostics = _Diagnostics();
        final paths = <String>[];
        final service = _service(
          BilibiliVideoMetadataClient(
            authService: BilibiliAuthService(
              cookieStore: PlatformServices.forPlatform(
                platform,
              ).createBilibiliCookieStore(),
            ),
            diagnostics: diagnostics,
            transport: (uri, headers) async {
              paths.add(uri.path);
              expect(headers['Cookie'], 'SESSDATA=$_secret');
              return VideoMetadataResponse(
                200,
                uri.path.endsWith('/nav')
                    ? _nav
                    : uri.path.endsWith('/pagelist')
                    ? _parts
                    : _view,
              );
            },
          ),
        );
        await service.lookupVideo(_bvid);
        await service.resolveSearchVideo(_result());
        expect(paths, [
          '/x/web-interface/nav',
          BilibiliVideoMetadataClient.viewPath,
          BilibiliVideoMetadataClient.partsPath,
        ]);
        expect(
          diagnostics.entries.last.fields['session_source'],
          platform.isApple
              ? 'apple_wkwebview'
              : platform == AppPlatform.android
              ? 'platform_webview'
              : 'secure_storage',
        );
        if (platform.isApple) {
          expect(bridgeCalls, contains('readPlaybackSession'));
        } else if (platform == AppPlatform.windows) {
          expect(bridgeCalls, isEmpty);
        } else {
          expect(bridgeCalls.toSet(), {'readCookies'});
        }
      },
    );
  }
  test(
    'login while old nav is pending cannot share or publish old signing work',
    () async {
      final cookies = _Cookies('');
      final auth = BilibiliAuthService(cookieStore: cookies, api: _LoginApi());
      final oldNav = Completer<VideoMetadataResponse>(),
          started = Completer<void>();
      var navs = 0, views = 0;
      final client = BilibiliVideoMetadataClient(
        authService: auth,
        diagnostics: _Diagnostics(),
        transport: (uri, headers) async {
          if (uri.path.endsWith('/nav')) {
            navs++;
            if (navs == 1) {
              started.complete();
              return oldNav.future;
            }
            expect(headers['Cookie'], 'SESSDATA=synthetic-new');
            return const VideoMetadataResponse(200, _nav);
          }
          views++;
          expect(headers['Cookie'], 'SESSDATA=synthetic-new');
          return const VideoMetadataResponse(200, _view);
        },
      );
      final service = _service(client);
      final old = service.lookupVideo(_bvid);
      final rejected = expectLater(
        old,
        throwsA(isA<BilibiliPlaybackSessionException>()),
      );
      await started.future;
      await auth.loginWithCookie('SESSDATA=synthetic-new');
      expect((await service.lookupVideo(_bvid)).cid, 101);
      oldNav.complete(const VideoMetadataResponse(200, _nav));
      await rejected;
      expect(navs, 2);
      expect(views, 1);
      expect(cookies.writes, 1);
    },
  );

  test(
    'persisted diagnostic export retains status separation and drops all server text',
    () async {
      final diagnostics = ProblemDiagnosticsService();
      final client = BilibiliVideoMetadataClient(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        diagnostics: diagnostics,
        transport: (uri, _) async => uri.path.endsWith('/nav')
            ? const VideoMetadataResponse(200, _nav)
            : const VideoMetadataResponse(412, _secret),
      );
      await expectLater(
        client.load(bvid: _bvid, details: true, parse: (body) => body),
        throwsA(isA<BilibiliLookupException>()),
      );
      // Queue barrier ensures best-effort request recording finished before readback.
      await diagnostics.record(
        ProblemDiagnosticEntry(
          occurredAt: DateTime.now(),
          category: 'app',
          operation: 'test_barrier',
          description: 'fixed',
        ),
      );
      final entry = (await diagnostics.loadRecentErrors()).singleWhere(
        (e) => e.category == 'videoMetadataRequest',
      );
      expect(entry.additionalInfo['http_status'], '412');
      expect(entry.additionalInfo.containsKey('api_code'), isFalse);
      expect(entry.errorCode, isNull);
      expect(jsonEncode(entry.toJson()), isNot(contains(_secret)));
      expect(jsonEncode(entry.toJson()), isNot(contains('w_rid')));
    },
  );
}
