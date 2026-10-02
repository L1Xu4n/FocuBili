import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/download_control.dart';
import 'package:focubili/services/resumable_media_download.dart';

/// Verifies byte-level resume behavior against a real local HTTP server.
void main() {
  late Directory root;
  late HttpServer server;
  late Uri uri;
  late ResumableMediaDownload transport;

  /// Gives every test its own disk root and loopback transport exception.
  setUp(() async {
    root = await Directory.systemTemp.createTemp('focubili-resume-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/video');
    transport = ResumableMediaDownload(
      acceptUri: (value) =>
          value.host == '127.0.0.1' && value.port == server.port,
    );
  });

  /// Closes only the server and temporary directory created by this test.
  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'pause aborts stalled request and resumes exact bytes with If-Range',
    () async {
      final firstChunkSent = Completer<void>();
      final releaseFirst = Completer<void>();
      final requests = <String?>[];
      final bytes = List<int>.generate(200000, (i) => i % 251);
      final handlers = <Future<void>>[];
      server.listen((request) {
        handlers.add(() async {
          requests.add(request.headers.value(HttpHeaders.rangeHeader));
          expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
          request.response.headers.set(
            HttpHeaders.etagHeader,
            '"stable-media"',
          );
          request.response.headers.contentType = ContentType('video', 'mp4');
          if (requests.length == 1) {
            request.response.contentLength = bytes.length;
            request.response.add(bytes.sublist(0, 100000));
            await request.response.flush();
            firstChunkSent.complete();
            await releaseFirst.future;
            try {
              await request.response.close();
            } catch (_) {
              /* Client cancelled. */
            }
          } else {
            expect(request.headers.value('if-range'), '"stable-media"');
            final start = int.parse(
              RegExp(r'bytes=(\d+)-').firstMatch(requests.last!)![1]!,
            );
            request.response.statusCode = 206;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${bytes.length - 1}/${bytes.length}',
            );
            request.response.contentLength = bytes.length - start;
            request.response.add(bytes.sublist(start));
            await request.response.close();
          }
        }());
      });
      final file = File('${root.path}/video.part');
      final control = DownloadControl();
      final gotBytes = Completer<void>();
      final transfer = transport.download(
        uri,
        {'Cookie': 'must-not-leak'},
        file,
        (received, total) {
          if (received > 0 && !gotBytes.isCompleted) gotBytes.complete();
        },
        control: control,
      );
      final cancelled = expectLater(
        transfer,
        throwsA(isA<DownloadInterrupted>()),
      );
      await firstChunkSent.future;
      await gotBytes.future;
      control.interrupt();
      await cancelled.timeout(const Duration(seconds: 3));
      final offset = await file.length();
      expect(offset, greaterThan(0));
      releaseFirst.complete();
      final received = await transport.download(
        uri,
        {},
        file,
        (received, total) {},
      );
      expect(received, bytes.length);
      expect(requests.last, 'bytes=$offset-');
      expect(await file.readAsBytes(), bytes);
      await Future.wait(handlers);
    },
  );

  test(
    'server ignoring range replaces old bytes instead of appending',
    () async {
      final file = File('${root.path}/video.part');
      await file.writeAsBytes([9, 9]);
      await ResumableMediaDownload.validatorFile(
        file,
      ).writeAsString('{"validator":"old"}');
      final done = Completer<void>();
      server.listen((request) async {
        expect(request.headers.value('range'), 'bytes=2-');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = 3;
        request.response.add([1, 2, 3]);
        await request.response.close();
        done.complete();
      });
      await transport.download(uri, {}, file, (received, total) {});
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(
        await ResumableMediaDownload.validatorFile(file).exists(),
        isFalse,
      );
      await done.future;
    },
  );

  /// A new track must restart even if its server reuses the old validator.
  test('changed media identity discards previous track bytes', () async {
    final file = File('${root.path}/video.part');
    await file.writeAsBytes([9, 9]);
    await ResumableMediaDownload.validatorFile(file).writeAsString(
      '{"validator":"same-etag","mediaIdentity":"old-track-digest"}',
    );
    final done = Completer<void>();
    server.listen((request) async {
      expect(request.headers.value('range'), isNull);
      expect(request.headers.value('if-range'), isNull);
      request.response.headers.set(HttpHeaders.etagHeader, 'same-etag');
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.contentLength = 3;
      request.response.add([1, 2, 3]);
      await request.response.close();
      done.complete();
    });
    await transport.download(
      uri,
      {},
      file,
      (received, total) {},
      mediaIdentity: 'new-track-digest',
    );
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(
      await ResumableMediaDownload.validatorFile(file).readAsString(),
      contains('new-track-digest'),
    );
    await done.future;
  });

  test('mismatched Content-Range never appends corrupt bytes', () async {
    final file = File('${root.path}/video.part');
    await file.writeAsBytes([1, 2]);
    await ResumableMediaDownload.validatorFile(
      file,
    ).writeAsString('{"validator":"old"}');
    server.listen((request) async {
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 1-3/4');
      request.response.add([2, 3, 4]);
      await request.response.close();
    });
    await expectLater(
      transport.download(uri, {}, file, (received, total) {}),
      throwsFormatException,
    );
    expect(await file.readAsBytes(), [1, 2]);
  });

  test('redirect cannot escape validated download hosts', () async {
    server.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set('location', 'http://127.0.0.1:1/private');
      await request.response.close();
    });
    await expectLater(
      transport.download(
        uri,
        {},
        File('${root.path}/video.part'),
        (received, total) {},
      ),
      throwsFormatException,
    );
  });
}
