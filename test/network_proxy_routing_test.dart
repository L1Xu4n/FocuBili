import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/network_proxy_settings.dart';
import 'package:focubili/services/routing_http_client.dart';

// Bypass Flutter's test-only 400-response override, never the production router.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final servers = <HttpServer>[];
  final clients = <RoutingHttpClient>[];
  final sockets = <Socket>[];
  final tunnels = <ServerSocket>[];

  Future<HttpServer> server(
    FutureOr<void> Function(HttpRequest) handler,
  ) async {
    final value = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(value);
    value.listen(handler);
    return value;
  }

  Uri url(HttpServer value, [String path = '/']) =>
      Uri.parse('http://127.0.0.1:${value.port}$path');
  RoutingHttpClient client(ProxyResolver resolve) {
    final value = RoutingHttpClient(
      resolve: resolve,
      createClient: () => _RealHttpOverrides().createHttpClient(null),
    );
    value.connectionTimeout = const Duration(seconds: 3);
    clients.add(value);
    return value;
  }

  Future<String> get(RoutingHttpClient client, Uri uri) async =>
      utf8.decoder.bind(await (await client.getUrl(uri)).close()).join();

  tearDown(() async {
    for (final client in clients) {
      client.close(force: true);
    }
    for (final socket in sockets) {
      socket.destroy();
    }
    for (final server in servers) {
      await server.close(force: true);
    }
    for (final tunnel in tunnels) {
      await tunnel.close();
    }
    tunnels.clear();
    clients.clear();
    sockets.clear();
    servers.clear();
  });

  test(
    'direct requests reach the origin with original path and query',
    () async {
      final seen = <Uri>[];
      final origin = await server((request) async {
        seen.add(request.uri);
        request.response.write('origin');
        await request.response.close();
      });
      final resolved = <Uri>[];
      final http = client((uri) async {
        resolved.add(uri);
        return const NetworkProxyRoute.direct();
      });
      final uri = url(origin, '/video?id=123');
      expect(await get(http, uri), 'origin');
      expect(seen.single.path, '/video');
      expect(seen.single.query, 'id=123');
      expect(resolved, [uri]);
    },
  );

  test(
    'manual HTTP route sends absolute URI to proxy without reaching origin',
    () async {
      var originRequests = 0;
      final origin = await server((request) async {
        originRequests++;
        await request.response.close();
      });
      final proxyRequests = <Uri>[];
      final proxy = await server((request) async {
        proxyRequests.add(request.uri);
        request.response.write('proxy');
        await request.response.close();
      });
      final http = client(
        (_) async => NetworkProxyRoute.http('127.0.0.1', proxy.port),
      );
      final uri = url(origin, '/image?q=1');
      expect(await get(http, uri), 'proxy');
      expect(proxyRequests, [uri]);
      expect(originRequests, 0);
    },
  );

  test('dead proxy connection never retries the origin directly', () async {
    var originRequests = 0;
    final origin = await server((request) async {
      originRequests++;
      await request.response.close();
    });
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = reserved.port;
    await reserved.close();
    final http = client(
      (_) async => NetworkProxyRoute.http('127.0.0.1', closedPort),
    );
    await expectLater(get(http, url(origin)), throwsA(isA<SocketException>()));
    expect(originRequests, 0);
  });

  test('resolver failure cannot open an origin connection', () async {
    var originRequests = 0;
    final origin = await server((request) async {
      originRequests++;
      await request.response.close();
    });
    final http = client(
      (_) async => throw const FormatException('Unsupported proxy protocol'),
    );
    await expectLater(get(http, url(origin)), throwsFormatException);
    expect(originRequests, 0);
  });

  test('proxy authentication error is returned without direct retry', () async {
    var originRequests = 0;
    final origin = await server((request) async {
      originRequests++;
      await request.response.close();
    });
    final proxy = await server((request) async {
      request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
      request.response.headers.set(
        HttpHeaders.proxyAuthenticateHeader,
        'Basic realm="test"',
      );
      await request.response.close();
    });
    final http = client(
      (_) async => NetworkProxyRoute.http('127.0.0.1', proxy.port),
    );
    final response = await (await http.getUrl(url(origin))).close();
    expect(response.statusCode, HttpStatus.proxyAuthenticationRequired);
    await response.drain<void>();
    expect(originRequests, 0);
  });

  test(
    'redirect resolves each destination and strips cross-origin secrets',
    () async {
      var destinationRequests = 0;
      final destination = await server((request) async {
        destinationRequests++;
        await request.response.close();
      });
      final redirected = url(destination, '/redirected');
      final proxyHeaders = <String, String?>{};
      final proxy = await server((request) async {
        for (final header in [
          'authorization',
          'cookie',
          'cookie2',
          'proxy-authorization',
          'x-request-id',
        ]) {
          proxyHeaders[header] = request.headers.value(header);
        }
        expect(request.uri, redirected);
        request.response.write('routed redirect');
        await request.response.close();
      });
      final origin = await server((request) async {
        expect(request.headers.value('authorization'), 'Bearer secret');
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          redirected.toString(),
        );
        await request.response.close();
      });
      final resolved = <Uri>[];
      final http = client((uri) async {
        resolved.add(uri);
        return uri.port == origin.port
            ? const NetworkProxyRoute.direct()
            : NetworkProxyRoute.http('127.0.0.1', proxy.port);
      });
      final request = await http.getUrl(url(origin));
      request.headers.set('authorization', 'Bearer secret');
      request.headers.set('cookie', 'session=secret');
      request.headers.set('cookie2', 'session2=secret');
      request.headers.set('proxy-authorization', 'Basic secret');
      request.headers.set('x-request-id', 'retained');
      final response = await request.close();
      expect(await utf8.decoder.bind(response).join(), 'routed redirect');
      expect(resolved, [url(origin), redirected]);
      expect(response.redirects.map((entry) => entry.location), [redirected]);
      expect(proxyHeaders, {
        'authorization': null,
        'cookie': null,
        'cookie2': null,
        'proxy-authorization': null,
        'x-request-id': 'retained',
      });
      expect(destinationRequests, 0);
    },
  );

  test('same-origin redirects preserve application auth and cookies', () async {
    final origin = await server((request) async {
      if (request.uri.path == '/start') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/end');
      } else {
        expect(request.headers.value('authorization'), 'Bearer same-origin');
        expect(request.headers.value('cookie'), 'session=same-origin');
        request.response.write('ok');
      }
      await request.response.close();
    });
    final http = client((_) async => const NetworkProxyRoute.direct());
    final request = await http.getUrl(url(origin, '/start'));
    request.headers.set('authorization', 'Bearer same-origin');
    request.headers.set('cookie', 'session=same-origin');
    expect(await utf8.decoder.bind(await request.close()).join(), 'ok');
  });

  test(
    'automatic redirect limit and loops fail instead of repeated requests',
    () async {
      var hits = 0;
      final origin = await server((request) async {
        hits++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          request.uri.path == '/a' ? '/b' : '/a',
        );
        await request.response.close();
      });
      final http = client((_) async => const NetworkProxyRoute.direct());
      await expectLater(
        get(http, url(origin, '/a')),
        throwsA(isA<RedirectException>()),
      );
      expect(hits, 2);
      final request = await http.getUrl(url(origin, '/a'));
      request.maxRedirects = 0;
      await expectLater(request.close(), throwsA(isA<RedirectException>()));
      expect(hits, 3);
    },
  );

  test(
    'manual redirect works after stream consumption and ignores maxRedirects',
    () async {
      final resolved = <Uri>[];
      final origin = await server((request) async {
        if (request.uri.path == '/a') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/b');
          request.response.write('consumed');
        } else {
          request.response.write('next');
        }
        await request.response.close();
      });
      final http = client((uri) async {
        resolved.add(uri);
        return const NetworkProxyRoute.direct();
      });
      final request = await http.getUrl(url(origin, '/a'));
      request.followRedirects = false;
      request.maxRedirects = 0;
      final response = await request.close();
      expect(await utf8.decoder.bind(response).join(), 'consumed');
      final next = await response.redirect();
      expect(await utf8.decoder.bind(next).join(), 'next');
      expect(resolved, [url(origin, '/a'), url(origin, '/b')]);
      expect(next.redirects, hasLength(1));
    },
  );

  test(
    'manual followLoops permits one hop rather than automatic endless follow',
    () async {
      var hits = 0;
      final origin = await server((request) async {
        hits++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/loop');
        await request.response.close();
      });
      final http = client((_) async => const NetworkProxyRoute.direct());
      final request = await http.getUrl(url(origin, '/loop'));
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      await expectLater(response.redirect(), throwsA(isA<RedirectException>()));
      final next = await response.redirect(null, null, true);
      await next.drain<void>();
      expect(next.statusCode, HttpStatus.found);
      expect(hits, 2);
    },
  );

  test('POST 303 becomes GET without forwarding body', () async {
    final seenMethods = <String>[];
    final seenBodies = <String>[];
    final origin = await server((request) async {
      seenMethods.add(request.method);
      seenBodies.add(await utf8.decoder.bind(request).join());
      if (request.uri.path == '/post') {
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers.set(HttpHeaders.locationHeader, '/result');
      }
      await request.response.close();
    });
    final http = client((_) async => const NetworkProxyRoute.direct());
    final request = await http.postUrl(url(origin, '/post'));
    request.write('payload');
    await (await request.close()).drain<void>();
    expect(seenMethods, ['POST', 'GET']);
    expect(seenBodies, ['payload', '']);
  });

  test('POST 302 is not automatically replayed', () async {
    var hits = 0;
    final origin = await server((request) async {
      hits++;
      await request.drain<void>();
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/another');
      await request.response.close();
    });
    final http = client((_) async => const NetworkProxyRoute.direct());
    final request = await http.postUrl(url(origin, '/post'));
    request.write('payload');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.found);
    await response.drain<void>();
    expect(hits, 1);
  });

  test('non-HTTP redirect is rejected without another resolution', () async {
    final origin = await server((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'file:///tmp/secret',
      );
      await request.response.close();
    });
    var resolutions = 0;
    final http = client((_) async {
      resolutions++;
      return const NetworkProxyRoute.direct();
    });
    await expectLater(get(http, url(origin)), throwsA(isA<HttpException>()));
    expect(resolutions, 1);
  });

  test(
    'closing while resolver is pending prevents connection and client creation',
    () async {
      var origins = 0;
      final origin = await server((request) async {
        origins++;
        await request.response.close();
      });
      final resolved = Completer<NetworkProxyRoute>();
      var created = 0;
      final http = RoutingHttpClient(
        resolve: (_) => resolved.future,
        createClient: () {
          created++;
          return _RealHttpOverrides().createHttpClient(null);
        },
      );
      clients.add(http);
      final pending = http.getUrl(url(origin));
      final assertion = expectLater(pending, throwsStateError);
      http.close(force: true);
      resolved.complete(const NetworkProxyRoute.direct());
      await assertion;
      expect(
        created,
        1,
        reason: 'Only template exists, no request client after close',
      );
      expect(origins, 0);
      await expectLater(http.getUrl(url(origin)), throwsStateError);
    },
  );
  test(
    'HTTPS uses CONNECT and rejects an untrusted certificate without bypass',
    () async {
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_testCertificate))
        ..usePrivateKeyBytes(utf8.encode(_testPrivateKey));
      final secureOrigin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      servers.add(secureOrigin);
      var originRequests = 0;
      secureOrigin.listen(
        (request) async {
          originRequests++;
          request.response.write('must not be reached');
          await request.response.close();
        },
        onError: (Object error) {
          // The rejected client certificate handshake may also surface server-side.
          expect(error, isA<HandshakeException>());
        },
      );
      var connectRequests = 0;
      // Raw tunnel listener avoids HttpServer's origin-form request parser.
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      tunnels.add(proxy);
      proxy.listen((downstream) {
        sockets.add(downstream);
        Socket? upstream;
        final buffered = <int>[];
        late StreamSubscription<List<int>> subscription;
        subscription = downstream.listen(
          (bytes) async {
            if (upstream != null) {
              upstream!.add(bytes);
              return;
            }
            buffered.addAll(bytes);
            final header = latin1.decode(buffered);
            final end = header.indexOf('\r\n\r\n');
            if (end == -1) return;
            subscription.pause();
            expect(
              header,
              startsWith('CONNECT 127.0.0.1:${secureOrigin.port} HTTP/1.1'),
            );
            connectRequests++;
            upstream = await Socket.connect(
              InternetAddress.loopbackIPv4,
              secureOrigin.port,
            );
            sockets.add(upstream!);
            upstream!.listen(
              downstream.add,
              onDone: downstream.destroy,
              onError: (Object _) => downstream.destroy(),
            );
            downstream.write('HTTP/1.1 200 Connection established\r\n\r\n');
            await downstream.flush();
            if (buffered.length > end + 4) {
              upstream!.add(buffered.sublist(end + 4));
            }
            subscription.resume();
          },
          onDone: () => upstream?.destroy(),
          onError: (Object _) => upstream?.destroy(),
        );
      });
      final http = client(
        (_) async => NetworkProxyRoute.http('127.0.0.1', proxy.port),
      );
      final destination = Uri.parse(
        'https://127.0.0.1:${secureOrigin.port}/private',
      );
      await expectLater(
        get(http, destination),
        throwsA(isA<HandshakeException>()),
      );
      expect(connectRequests, 1);
      expect(originRequests, 0);
      // Positive control: trusting only this test certificate makes the same
      // CONNECT tunnel work, proving the prior failure was TLS verification.
      final trustedContext = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(_testCertificate));
      final trustedClient = RoutingHttpClient(
        resolve: (_) async => NetworkProxyRoute.http('127.0.0.1', proxy.port),
        createClient: () =>
            _RealHttpOverrides().createHttpClient(trustedContext),
      );
      clients.add(trustedClient);
      expect(await get(trustedClient, destination), 'must not be reached');
      expect(connectRequests, 2);
      expect(originRequests, 1);
    },
  );
}

// Public, test-only self-signed material. Never used by the application.
const _testCertificate = '''
-----BEGIN CERTIFICATE-----
MIIDJzCCAg+gAwIBAgIUJGseWED0+MKXvx8OLXriCXSDi1wwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTEwNTA3NTMwOFoYDzIxMjYx
MDEyMDc1MzA4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQC8a/ppD9i9Sd49kGPnBRG1YXNMRcDOAynKMsXtmlVs
DRJkOolANy6EGvwqwbwrX3TiUmKJ/DNG9YtVhQZ+2FL78rASxpWVUlaxkaHCtsAo
ivOT9dql99lXUXP7eDcxeE6wu2sfT6zCVNLqadhTqP3sU5LMxc96mQZ1NroPje+Y
kZjjK0dH15dGPRnuHgxNdw86Tn/opSvNB4SvAE7oTp5C0iFMJ5OEMzs8a8yV6FAW
n3EJStijAvNukqIE+CZR7DnI49x8QoJPickSpRwTEV5eWSOr1HwQQmBBjon+RMhO
VafVDqpLew1RVI4kKai8OcfzjUts8iquxK3nc0cymoH1AgMBAAGjbzBtMB0GA1Ud
DgQWBBRe5hZizPut2WQsut0IGi4QRnNvcjAfBgNVHSMEGDAWgBRe5hZizPut2WQs
ut0IGi4QRnNvcjAPBgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGCCWxvY2FsaG9z
dIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEATp+esuge1KYH7NKoRGvYZyW+AUi1
JvYOnt7bjOaxRC3MkiGjP+8aHKjemas3+l4gMStz6bsHshtGxNPSZFOjR9TwX/d1
LvgdUg6lTTCMzEVSwK5bQJgxgvOW5qVtcQ5qu3dTuHQteVGKXfE9S/qFcnKIrIW4
lYLrh27YnBZ4Z0kdVJUcNygcQfZw4TAifjlg5bZwemr4B8vCPW07wenpIpqcbeO7
QFEJqQ/s7wXrAGS9VqhBdxyL9SVXB/627rv413rP5WXwWxCzW6ET6cNRraliQgj6
MUl5nxPogteOXPITtOMp2Nz5VJFsUxwm4vWL7Gc2GHROCSmHQvzKnTZH2Q==
-----END CERTIFICATE-----
''';
const _testPrivateKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC8a/ppD9i9Sd49
kGPnBRG1YXNMRcDOAynKMsXtmlVsDRJkOolANy6EGvwqwbwrX3TiUmKJ/DNG9YtV
hQZ+2FL78rASxpWVUlaxkaHCtsAoivOT9dql99lXUXP7eDcxeE6wu2sfT6zCVNLq
adhTqP3sU5LMxc96mQZ1NroPje+YkZjjK0dH15dGPRnuHgxNdw86Tn/opSvNB4Sv
AE7oTp5C0iFMJ5OEMzs8a8yV6FAWn3EJStijAvNukqIE+CZR7DnI49x8QoJPickS
pRwTEV5eWSOr1HwQQmBBjon+RMhOVafVDqpLew1RVI4kKai8OcfzjUts8iquxK3n
c0cymoH1AgMBAAECggEAC4r2igrOpXifKkNXCMHek1osdN7jEFvQ6rz7M3KcdWRE
R6qZr5A8g8WexBnJPBj6xptIbm6U+kMJmEwaw+40VeXzU7shp8ZQXvbDzki2yI+2
m05Y6N5K92vwgIEdVHpWdmziLka0bSqYHy8rxvhCfKtOrMfDeEhj77inY6jiJYT5
g9WZtuLvk5tZYd02MtalH/viTpbTWks7ijq7oxz7plMbuAYLA0Q/0RIE6dxwUDnA
EI/o+bR1aUgv7ZJba5mf5HaDLfLVk0N58o2fcBmKYYNi4CXp7Et8OOoZBwdgTi+v
q/bmBmJ5zUSlfScYJbTG2Qe+M1kfVV2gmDYa+F1jMwKBgQDw9flJbmwg4FXD+cab
9MsxlTIBwbvmW24UmliddFbxFvFyZsz/XiHgJADDFNUvoCnBf3Y2E2kecyAtRnP0
2qfExof1ztkuPjVreN+P5S4ZOzCbQ9qAx/oMdd9VE7PHU/trCa14zX1Rg9QVZ4FQ
Y/EJl20LaBF0gRC7vMldqA00lwKBgQDILoupSf7P0CYqMD3NSga951xt10MYt3Uf
26IPAQE5ZlJe7ZLAh5aKvP3dRUNn66nmcK1wdOuJm+bahrSBV9RBRShJOfd3aF/G
xtkXd5bUVhEuZB8hQvFfv0BYy+REsNrbi6IFMLhmbdasluo3B88MJHcaQS1wgcnM
UplNCRbTUwKBgQCv/GZibESKym25YV7eHq6c+wN35wAOIW7Hm2bnMMYi9QfI7y3/
wMdrBcCMulVtoEN+8FHs8sZOl/TDPHaKOXxYqks4iydxr7uiT7iwRskhYmqAq9EV
R3jnytsfLvGZvkudBIdu+F3zwB2QuHTouuWbhL3+m7ZL6cvH4f0L6yYh5wKBgCF7
t5yfZeG4vUl9PDkkUrBdDJbK1MxDk3G6uQatclj5hnmeX1eY1lNqfUQPm9C8GHUV
D82poOQpkZmnwnWIDVbFjJGDAqOUb8C97f4A4Nevdbw+vv4/RkRvpwGzSQE8W78x
Qe6AUbfAU5IWxCJkSfuL9egMUt9otipY/o9mH81FAoGBALKFqCOkzcj49pPignQd
frQ3/biPsuB7iQ1k5NWaH1ohYDWn6r4iu7NNHhtYam1BktbnS5ub9SI8miFdwmqj
5qqk2BI3qo5MbCzYF9LBQgH9+52GdHMS1vdxcHTGP8EyPZ482D5WGCbrpxvZXz23
l11hZJAF7KeI+G2I6bLEdXn1
-----END PRIVATE KEY-----
''';
