import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/app_http_client.dart';

void main() {
  late HttpServer server;
  late AppHttpTransport transport;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    transport = AppHttpTransport();
  });

  tearDown(() async {
    transport.closePools(force: true);
    await server.close(force: true);
  });

  Uri serverUri(String path) =>
      Uri.http(server.address.address, path).replace(port: server.port);

  test(
    'supports GET/POST, multi-value headers, 304, and transparent gzip within limit',
    () async {
      server.listen((HttpRequest request) async {
        if (request.uri.path == '/post') {
          final String body = await utf8.decoder.bind(request).join();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.add(
            HttpHeaders.setCookieHeader,
            'a=1; Path=/',
          );
          request.response.headers.add(
            HttpHeaders.setCookieHeader,
            'b=2; Path=/',
          );
          request.response.write('echo:$body');
          await request.response.close();
          return;
        }
        if (request.uri.path == '/etag') {
          request.response.statusCode = HttpStatus.notModified;
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          await request.response.close();
          return;
        }
        if (request.uri.path == '/gzip') {
          final List<int> payload = gzip.encode(
            utf8.encode('hello-gzip-world' * 8),
          );
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(
            HttpHeaders.contentEncodingHeader,
            'gzip',
          );
          request.response.add(payload);
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final AppHttpResponse post = await transport.send(
        uri: serverUri('/post'),
        method: 'POST',
        bodyBytes: utf8.encode('k=v'),
        headers: const <String, String>{
          HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
        },
      );
      expect(post.statusCode, HttpStatus.ok);
      expect(post.bodyUtf8, 'echo:k=v');
      expect(post.headerValues('set-cookie'), <String>[
        'a=1; Path=/',
        'b=2; Path=/',
      ]);

      final AppHttpResponse notModified = await transport.send(
        uri: serverUri('/etag'),
      );
      expect(notModified.statusCode, HttpStatus.notModified);
      expect(notModified.header('etag'), '"v1"');
      expect(notModified.bytes, isEmpty);

      final AppHttpResponse gzipped = await transport.send(
        uri: serverUri('/gzip'),
        maxResponseBytes: 1024,
      );
      expect(gzipped.statusCode, HttpStatus.ok);
      expect(gzipped.bodyUtf8, 'hello-gzip-world' * 8);

      await expectLater(
        transport.send(uri: serverUri('/gzip'), maxResponseBytes: 32),
        throwsA(isA<AppHttpResponseTooLargeException>()),
      );
    },
  );

  test(
    'followRedirects false captures Location without fetching redirect target',
    () async {
      int targetHits = 0;
      server.listen((HttpRequest request) async {
        if (request.uri.path == '/short') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/final-target',
          );
          await request.response.close();
          return;
        }
        targetHits += 1;
        request.response.statusCode = HttpStatus.ok;
        request.response.write('big-html');
        await request.response.close();
      });

      final AppHttpResponse response = await transport.send(
        uri: serverUri('/short'),
        followRedirects: false,
      );
      expect(response.statusCode, HttpStatus.found);
      expect(response.redirectLocation, '/final-target');
      expect(targetHits, 0);
    },
  );

  test(
    'single request timeout or cancel does not break concurrent requests on shared pool',
    () async {
      final Completer<void> releaseSlow = Completer<void>();
      server.listen((HttpRequest request) async {
        if (request.uri.path == '/slow') {
          await releaseSlow.future.timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
          try {
            request.response.statusCode = HttpStatus.ok;
            request.response.write('slow-done');
            await request.response.close();
          } catch (_) {}
          return;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.write('fast-ok');
        await request.response.close();
      });

      final AppHttpCancelToken cancelToken = AppHttpCancelToken();
      final Future<AppHttpResponse> cancelledFuture = transport.send(
        uri: serverUri('/slow'),
        timeout: const Duration(seconds: 5),
        cancelToken: cancelToken,
      );
      final Future<AppHttpResponse> timedOutFuture = transport.send(
        uri: serverUri('/slow'),
        timeout: const Duration(milliseconds: 80),
      );

      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 40),
          cancelToken.cancel,
        ),
      );

      await expectLater(
        cancelledFuture,
        throwsA(isA<AppHttpCancelledException>()),
      );
      await expectLater(timedOutFuture, throwsA(isA<TimeoutException>()));

      final AppHttpResponse healthy = await transport.send(
        uri: serverUri('/fast'),
      );
      expect(healthy.statusCode, HttpStatus.ok);
      expect(healthy.bodyUtf8, 'fast-ok');
      releaseSlow.complete();
    },
  );

  test(
    'oversized Content-Length rejects immediately without draining body and frees shared pool slots',
    () async {
      final List<Completer<void>> serverDisconnects = <Completer<void>>[];

      server.listen((HttpRequest request) async {
        if (request.uri.path.startsWith('/huge')) {
          final Completer<void> disconnected = Completer<void>();
          serverDisconnects.add(disconnected);
          request.response.statusCode = HttpStatus.ok;
          request.response.contentLength = 32 * 1024 * 1024;
          request.response.bufferOutput = false;
          // Flush headers + first 1 KiB, then stall without ever finishing the 32 MiB body.
          try {
            request.response.add(List<int>.filled(1024, 65));
            await request.response.flush();
            await request.response.done.timeout(const Duration(seconds: 2));
          } catch (_) {
            // Expected when client aborts/cancels the socket.
          } finally {
            if (!disconnected.isCompleted) {
              disconnected.complete();
            }
          }
          return;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.write('still-healthy');
        await request.response.close();
      });

      // Exceed maxConnectionsPerHost (6) with 8 oversized responses; none may wedge the pool.
      for (int i = 0; i < 8; i++) {
        await expectLater(
          transport.send(
            uri: serverUri('/huge-$i'),
            maxResponseBytes: 512,
            timeout: const Duration(seconds: 2),
          ),
          throwsA(isA<AppHttpResponseTooLargeException>()),
        );
      }

      // Immediately after 8 oversized rejections (>6 per-host pool slots), a normal request succeeds.
      final AppHttpResponse ok = await transport.send(
        uri: serverUri('/ok'),
        timeout: const Duration(seconds: 2),
      );
      expect(ok.statusCode, HttpStatus.ok);
      expect(ok.bodyUtf8, 'still-healthy');
      expect(serverDisconnects, hasLength(8));
    },
  );
}
