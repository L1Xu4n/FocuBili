import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_media_plan.dart';
import 'package:focubili/services/resumable_media_download.dart';
import 'course_cache_library_test.dart' show Access, video, part;

/// Optional real-container smoke: owned synthetic audiovisual signal, a loopback
/// HTTP server, production transport/receipts, disconnection, then actual decode.
void main() {
  test(
    'generated MP4 renews with no media bytes and decodes with the server stopped',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'classroom_media_replay',
      );
      addTearDown(() => root.delete(recursive: true));
      final sample = File.fromUri(root.uri.resolve('sample.mp4'));
      final gen = await Process.run('ffmpeg', [
        '-nostdin',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=blue:s=112x64:d=1',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=330:duration=1',
        '-c:v',
        'mpeg4',
        '-c:a',
        'aac',
        '-shortest',
        sample.path,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());
      final bytes = await sample.readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/lesson.mp4');
      final requests = <String>[];
      var bodyBytes = 0;
      server.listen((r) async {
        requests.add(r.method);
        expect(r.headers.value('cookie'), isNull);
        r.response.contentLength = bytes.length;
        r.response.headers
          ..contentType = ContentType('video', 'mp4')
          ..set('etag', '"owned-test-media-v1"');
        if (r.method == 'GET') {
          bodyBytes += bytes.length;
          r.response.add(bytes);
        }
        await r.response.close();
      });
      final a = Access()
        ..now = DateTime.now()
        ..media = OfflineMediaPlan(
          video: OfflineMediaTrack(
            id: 64,
            urls: [url.toString()],
            expectedBytes: bytes.length,
          ),
        );
      final store = CourseCacheLibrary(
        access: a,
        root: () async => root,
        clock: () => a.now,
        downloader: ResumableMediaDownload(acceptUri: (u) => u == url),
      );
      addTearDown(store.dispose);
      await store.start(video, part);
      expect(store.error, isNull);
      expect(requests, ['GET']);
      expect(bodyBytes, bytes.length);
      final original = (await store.entries()).single;
      a.now = original.until!;
      bodyBytes = 0;
      await store.start(video, part);
      expect(store.error, isNull);
      expect(requests, ['GET', 'HEAD']);
      expect(bodyBytes, 0);
      await server.close(force: true);
      final opened = await store.open((await store.entries()).single);
      final dec = await Process.run('ffmpeg', [
        '-nostdin',
        '-loglevel',
        'error',
        '-i',
        opened.video,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0',
        '-f',
        'null',
        '-',
      ]);
      expect(dec.exitCode, 0, reason: dec.stderr.toString());
      expect(a.calls, 2);
    },
    skip: !const bool.fromEnvironment('COURSE_MEDIA_REPLAY')
        ? 'Opt-in; host ffmpeg required.'
        : false,
  );
}
