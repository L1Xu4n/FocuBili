import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/playback_request_diagnostic.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';

// All identifiers, cookies, bodies and responses here are synthetic. The HTTP
// override exercises the production transport without opening any socket.
const _image = '7cd084941338484aae1ad9425b84077c';
const _sub = '4932caff0ff746eab6f01bf08b70ac45';
const _nav =
    '{"code":-101,"data":{"wbi_img":{'
    '"img_url":"https://i0.hdslb.com/bfs/wbi/$_image.png",'
    '"sub_url":"https://i0.hdslb.com/bfs/wbi/$_sub.png"}}}';
const _privateMarker = 'synthetic-private-marker';
const _cookie = 'SESSDATA=$_privateMarker; buvid3=synthetic-device';
const _success =
    '{"code":0,"data":{"quality":80,"dash":{'
    '"video":[{"id":80,"codecs":"avc1.640028",'
    '"base_url":"https://video.bilivideo.com/synthetic.m4s"}],'
    '"audio":[{"codecs":"mp4a.40.2",'
    '"base_url":"https://audio.bilivideo.com/synthetic.m4s"}]}}}';

class _Cookies implements BilibiliCookieStore {
  String value = _cookie;
  int reads = 0, writes = 0;
  @override
  Future<String> readCookies() async {
    reads++;
    return value;
  }

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

class _Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  List<String>? operator [](String name) => null;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.uri, this.response);
  @override
  final Uri uri;
  final _Response response;
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.body, [this.setCookies = const []]);
  final List<String> setCookies;
  @override
  final int statusCode;
  final String body;
  @override
  HttpHeaders get headers => _ResponseHeaders(setCookies);
  @override
  List<Cookie> get cookies => [Cookie('bili_ticket', 'synthetic-response')];
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ResponseHeaders extends _Headers {
  _ResponseHeaders(this.cookies);
  final List<String> cookies;
  @override
  List<String>? operator [](String name) =>
      name.toLowerCase() == 'set-cookie' ? cookies : null;
}

class _Transport implements HttpClient {
  _Transport(this.respond);
  final _Response Function(Uri) respond;
  final requests = <_Request>[];
  @override
  Duration? connectionTimeout;
  int closes = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final request = _Request(uri, respond(uri));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Object> _failure(Future<Object> future) async {
  try {
    await future;
  } catch (error) {
    return error;
  }
  throw StateError('Expected synthetic failure');
}

Future<Map<String, String>> _facts() async =>
    (await ProblemDiagnosticsService().loadRecentErrors())
        .where((entry) => entry.category == 'playbackRequest')
        .single
        .additionalInfo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<T> run<T>(
    _Transport transport,
    Future<T> Function(BilibiliDesktopPlaybackSourceService, _Cookies) action, {
    bool wbi = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_behavior.wbi_signing_enabled': wbi,
      'app_behavior.account_read_only': true,
    });
    final cookies = _Cookies();
    return HttpOverrides.runZoned(
      () => action(
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: cookies),
        ),
        cookies,
      ),
      createHttpClient: (_) => transport,
    );
  }

  test(
    'HTTP 412 records transport status and never retries or drops login',
    () async {
      final transport = _Transport((_) => _Response(412, _privateMarker));
      await run(transport, (service, cookies) async {
        final error = await _failure(
          service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80),
        );
        expect(error.toString(), contains('HTTP 412'));
        expect(error.toString(), isNot(contains(_privateMarker)));
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single.headers.values['cookie'], _cookie);
        expect(transport.requests.single.followRedirects, isFalse);
        expect(cookies.writes, 0);
        final facts = await _facts();
        expect(facts['http_status'], '412');
        expect(facts.containsKey('api_code'), isFalse);
        expect(facts['endpoint_kind'], 'playurl_legacy');
        expect(facts['wbi_signed'], 'false');
      });
    },
  );

  test(
    'HTTP 200 with API -412 is distinct and never echoes server text',
    () async {
      final transport = _Transport(
        (_) => _Response(
          200,
          '{"code":-412,"message":"$_privateMarker https://example.invalid/private"}',
        ),
      );
      await run(transport, (service, _) async {
        final error = await _failure(
          service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80),
        );
        expect(error.toString(), isNot(contains(_privateMarker)));
        expect(error.toString(), contains('-412'));
        expect(transport.requests, hasLength(1));
        final facts = await _facts();
        expect(facts['http_status'], '200');
        expect(facts['api_code'], '-412');
        expect(facts['stage'], 'parse');
        expect(facts['outcome'], 'error');
      });
    },
  );

  test(
    'nav HTTP 412 remains identifiable with playurl never attempted',
    () async {
      final transport = _Transport((_) => _Response(412, _privateMarker));
      await run(transport, (service, _) async {
        final error = await _failure(
          service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80),
        );
        expect(error.toString(), contains('HTTP 412'));
        expect(error.toString(), isNot(contains('关闭')));
        expect(transport.requests.map((r) => r.uri.path), [
          '/x/web-interface/nav',
        ]);
        final facts = await _facts();
        expect(facts['http_status'], '412');
        expect(facts['endpoint_kind'], 'nav');
        expect(facts['wbi_enabled'], 'true');
        expect(facts['wbi_signed'], 'false');
        expect(facts['playurl_attempted'], 'false');
        expect(facts['stage'], 'signing');
      }, wbi: true);
    },
  );

  test('signed desktop request facts survive storage without secrets', () async {
    final transport = _Transport(
      (uri) => _Response(200, uri.path.endsWith('/nav') ? _nav : _success),
    );
    await run(transport, (service, cookies) async {
      final sources = await service.load(
        bvid: 'BV1GJ411x7h7',
        cid: 1,
        quality: 80,
      );
      expect(sources.actualQuality, 80);
      expect(sources.mediaHeaders.containsKey('Cookie'), isFalse);
      expect(cookies.reads, 1);
      // Characterizes the current lack of Set-Cookie synchronization.
      expect(cookies.writes, 0);
      expect(transport.requests, hasLength(2));
      for (final request in transport.requests) {
        expect(request.headers.values['cookie'], _cookie);
        expect(
          request.headers.values['referer'],
          'https://www.bilibili.com/video/BV1GJ411x7h7',
        );
        expect(
          request.headers.values['user-agent'],
          BilibiliDesktopPlaybackSourceService.desktopUserAgent,
        );
        expect(request.headers.values.containsKey('origin'), isFalse);
        expect(request.followRedirects, isFalse);
      }
      final query = transport.requests.last.uri.queryParameters;
      expect(transport.requests.last.uri.path, '/x/player/wbi/playurl');
      expect(query['fnval'], '16');
      expect(query['web_location'], '1315873');
      final unsigned = Map<String, String>.of(query)..remove('w_rid');
      final keys = unsigned.keys.toList()..sort();
      final canonical = keys
          .map(
            (k) =>
                '${Uri.encodeComponent(k)}=${Uri.encodeComponent(unsigned[k]!)}',
          )
          .join('&');
      expect(
        query['w_rid'],
        md5
            .convert(
              utf8.encode(
                '$canonical'
                'ea1db124af3c7062474693fa704f4ff8',
              ),
            )
            .toString(),
      );
      expect(
        (DateTime.now().millisecondsSinceEpoch ~/ 1000 -
                int.parse(query['wts']!))
            .abs(),
        lessThan(5),
      );
      final facts = await _facts();
      expect(facts['endpoint_kind'], 'playurl_wbi');
      expect(facts['http_status'], '200');
      expect(facts['api_code'], '0');
      expect(facts['wbi_enabled'], 'true');
      expect(facts['wbi_signed'], 'true');
      expect(facts['session_source'], 'injected');
      expect(facts['auth_state'], 'session_present_unverified');
      expect(facts['has_buvid3'], 'true');
      expect(facts['has_buvid4'], 'false');
      expect(facts['has_bili_ticket'], 'false');
      expect(facts['requested_quality'], '80');
      expect(facts['returned_quality'], '80');
      expect(jsonEncode(facts), isNot(contains(_privateMarker)));
      expect(jsonEncode(facts), isNot(contains('BV1GJ411x7h7')));
      expect(jsonEncode(facts), isNot(contains('https://')));
    }, wbi: true);
  });

  test('concurrent callers share nav but each still sends a playurl', () async {
    final transport = _Transport(
      (uri) =>
          _Response(200, uri.path.endsWith('/nav') ? _nav : '{"code":-412}'),
    );
    await run(transport, (service, _) async {
      await Future.wait(
        List.generate(
          3,
          (_) =>
              _failure(service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80)),
        ),
      );
      expect(
        transport.requests.where((r) => r.uri.path.endsWith('/nav')),
        hasLength(1),
      );
      expect(
        transport.requests.where((r) => r.uri.path.endsWith('/playurl')),
        hasLength(3),
      );
    }, wbi: true);
  });

  test('HTTP status is captured exactly rather than assuming 200', () async {
    final transport = _Transport((_) => _Response(201, _success));
    await run(transport, (service, _) async {
      await service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80);
      expect((await _facts())['http_status'], '201');
    });
  });

  test('nav API refusal stops even when signing material is present', () async {
    final transport = _Transport(
      (_) => _Response(200, _nav.replaceFirst('"code":-101', '"code":-412')),
    );
    await run(transport, (service, _) async {
      final error = await _failure(
        service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80),
      );
      expect(error.toString(), contains('-412'));
      expect(transport.requests, hasLength(1));
      final facts = await _facts();
      expect(facts['http_status'], '200');
      expect(facts['api_code'], '-412');
      expect(facts['playurl_attempted'], 'false');
      expect(facts['endpoint_kind'], 'nav');
    }, wbi: true);
  });

  test('legacy string fixtures never invent an HTTP status', () async {
    final service = BilibiliDesktopPlaybackSourceService(
      authService: BilibiliAuthService(cookieStore: _Cookies()),
      requestJson: (_, _) async => _success,
    );
    await service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80);
    final facts = await _facts();
    expect(facts.containsKey('http_status'), isFalse);
    expect(facts['api_code'], '0');
  });

  test(
    'a preference change during nav cannot alter the captured request',
    () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final paths = <String>[];
      SharedPreferences.setMockInitialValues({
        'app_behavior.wbi_signing_enabled': true,
      });
      final service = BilibiliDesktopPlaybackSourceService(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        requestJson: (uri, _) async {
          paths.add(uri.path);
          if (uri.path.endsWith('/nav')) {
            entered.complete();
            await resume.future;
            return _nav;
          }
          return _success;
        },
      );
      final pending = service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80);
      await entered.future;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('app_behavior.wbi_signing_enabled', false);
      resume.complete();
      await pending;
      expect(paths, ['/x/web-interface/nav', '/x/player/wbi/playurl']);
      final facts = await _facts();
      expect(facts['wbi_enabled'], 'true');
      expect(facts['wbi_signed'], 'true');
      expect(facts['endpoint_kind'], 'playurl_wbi');
    },
  );

  test('diagnostic storage failure does not change playback', () async {
    final service = BilibiliDesktopPlaybackSourceService(
      authService: BilibiliAuthService(cookieStore: _Cookies()),
      requestJson: (_, _) async => _success,
      diagnosticsService: _BrokenDiagnostics(),
    );
    final sources = await service.load(
      bvid: 'BV1GJ411x7h7',
      cid: 1,
      quality: 80,
    );
    expect(sources.actualQuality, 80);
  });

  test('partial session is not diagnosed as confirmed anonymous', () async {
    final cookies = _Cookies()..value = 'bili_jct=synthetic-partial';
    final service = BilibiliDesktopPlaybackSourceService(
      authService: BilibiliAuthService(cookieStore: cookies),
      requestJson: (_, _) async => _success,
    );
    await service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80);
    final facts = await _facts();
    expect(facts['session_read'], 'partial');
    expect(facts['auth_state'], 'unknown');
    expect(jsonEncode(facts), isNot(contains('synthetic-partial')));
    expect(cookies.writes, 0);
  });

  test(
    'opaque legacy store retains its snapshot without a native session fence',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_behavior.wbi_signing_enabled': true,
      });
      final cookies = _Cookies();
      final entered = Completer<void>();
      final resume = Completer<void>();
      String? sentCookie;
      final service = BilibiliDesktopPlaybackSourceService(
        authService: BilibiliAuthService(cookieStore: cookies),
        requestJson: (uri, headers) async {
          if (uri.path.endsWith('/nav')) {
            entered.complete();
            await resume.future;
            return _nav;
          }
          sentCookie = headers['Cookie'];
          return _success;
        },
      );
      final pending = service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80);
      await entered.future;
      cookies.value = 'SESSDATA=synthetic-new-session';
      resume.complete();
      final oldSources = await pending;
      // This documents a separate pre-existing desktop gap, not a repaired race.
      // A future session fence should change these expectations to rejection.
      expect(sentCookie, _cookie);
      expect(oldSources.cookieHeader, _cookie);
      expect(cookies.value, 'SESSDATA=synthetic-new-session');
      expect(cookies.reads, 1);
    },
  );
  const authChannel = MethodChannel('com.focubili.app/auth');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(authChannel, null));

  Future<T> runApple<T>(
    _Transport transport,
    _AppleSession native,
    Future<T> Function(BilibiliDesktopPlaybackSourceService) action,
  ) async {
    SharedPreferences.setMockInitialValues({
      'app_behavior.wbi_signing_enabled': true,
    });
    messenger.setMockMethodCallHandler(authChannel, native.handle);
    return HttpOverrides.runZoned(
      () => action(
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(
            cookieStore: const AppleBilibiliCookieStore(),
          ),
        ),
      ),
      createHttpClient: (_) => transport,
    );
  }

  test('Apple nav response cookie reaches playurl in the same session', () async {
    final native = _AppleSession();
    final transport = _Transport(
      (uri) => uri.path.endsWith('/nav')
          ? _Response(200, _nav, [
              'bili_ticket=synthetic-issued; Domain=.bilibili.com; Path=/; Secure',
            ])
          : _Response(200, _success),
    );
    await runApple(transport, native, (service) async {
      final sources = await service.load(
        bvid: 'BV1GJ411x7h7',
        cid: 1,
        quality: 80,
      );
      expect(native.merges, 1);
      expect(
        transport.requests.last.headers.values['cookie'],
        contains('bili_ticket=synthetic-issued'),
      );
      expect(sources.mediaHeaders.containsKey('Cookie'), isFalse);
      expect(native.validations, greaterThanOrEqualTo(1));
      final facts = await _facts();
      expect(facts['session_source'], 'apple_wkwebview');
      expect(facts['has_bili_ticket'], 'true');
      expect(jsonEncode(facts), isNot(contains('synthetic-issued')));
      native.generation++;
      await expectLater(
        sources.validateSession!(),
        throwsA(isA<BilibiliPlaybackSessionException>()),
      );
    });
  });

  test(
    'Apple identity change during nav stops before sending playurl',
    () async {
      final native = _AppleSession();
      final transport = _Transport((uri) {
        if (uri.path.endsWith('/nav')) native.generation++;
        return _Response(200, _nav);
      });
      await runApple(transport, native, (service) async {
        await expectLater(
          service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80),
          throwsA(isA<BilibiliPlaybackSessionException>()),
        );
        expect(transport.requests, hasLength(1));
        final facts = await _facts();
        expect(facts['session_read'], 'changing');
        expect(facts['playurl_attempted'], 'false');
      });
    },
  );

  test('Apple identity change during playurl discards response', () async {
    final native = _AppleSession();
    final transport = _Transport((uri) {
      if (uri.path.endsWith('/playurl')) native.generation++;
      return _Response(200, uri.path.endsWith('/nav') ? _nav : _success);
    });
    await runApple(transport, native, (service) async {
      await expectLater(
        service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80),
        throwsA(isA<BilibiliPlaybackSessionException>()),
      );
      expect(transport.requests, hasLength(2));
      expect((await _facts())['session_read'], 'changing');
    });
  });

  for (final state in ['conflict', 'partial', 'changing', 'unknown']) {
    test(
      'Apple $state session fails closed without anonymous request',
      () async {
        final native = _AppleSession()..state = state;
        final transport = _Transport((_) => _Response(200, _success));
        await runApple(transport, native, (service) async {
          await expectLater(
            service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80),
            throwsA(isA<BilibiliPlaybackSessionException>()),
          );
          expect(transport.requests, isEmpty);
          expect(native.merges, 0);
        });
      },
    );
  }

  test(
    'Apple HTTP 412 stops without cookie writes or unsigned retry',
    () async {
      final native = _AppleSession();
      final transport = _Transport(
        (_) => _Response(412, '', [
          'bili_ticket=synthetic-rejected; Domain=.bilibili.com; Path=/',
        ]),
      );
      await runApple(transport, native, (service) async {
        await _failure(service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 80));
        expect(transport.requests, hasLength(1));
        expect(native.merges, 0);
        expect((await _facts())['http_status'], '412');
      });
    },
  );
}

class _BrokenDiagnostics extends ProblemDiagnosticsService {
  @override
  Future<void> recordPlaybackRequest(
    PlaybackRequestDiagnostic diagnostic,
  ) async => throw const FileSystemException('synthetic failure');
}

class _AppleSession {
  int generation = 7;
  String state = 'session';
  String header = _cookie;
  int merges = 0, validations = 0;
  Map<String, Object> get snapshot => {
    'generation': generation,
    'state': state,
    'header': header,
  };
  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map;
    switch (call.method) {
      case 'readPlaybackSession':
        return snapshot;
      case 'validatePlaybackSession':
        validations++;
        return args['generation'] == generation && state == 'session';
      case 'mergePlaybackResponseCookies':
        expect(args['generation'], generation);
        expect(args['path'], '/x/web-interface/nav');
        expect(args['cookies'], [
          'bili_ticket=synthetic-issued; Domain=.bilibili.com; Path=/; Secure',
        ]);
        merges++;
        header += '; bili_ticket=synthetic-issued';
        return snapshot;
      default:
        throw StateError('Unexpected synthetic channel operation');
    }
  }
}
