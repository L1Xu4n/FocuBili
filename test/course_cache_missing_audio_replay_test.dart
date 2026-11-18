import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/offline_media_plan.dart';
import 'package:focubili/services/resumable_media_download.dart';
import 'course_cache_library_test.dart' show Access, video, part;

/// Real-container negative: a silent, video-only MP4 cannot finish a lesson.
void main() {
  test(
    'video-only lecture response cannot become a complete offline lesson',
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
        '-c:v',
        'mpeg4',
        '-an',
        '-shortest',
        sample.path,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());
      final bytes = await sample.readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/lesson.mp4');
      var count = 0;
      server.listen((r) async {
        count++;
        expect(r.headers.value('cookie'), isNull);
        r.response.contentLength = bytes.length;
        r.response.headers.contentType = ContentType('video', 'mp4');
        r.response.add(bytes);
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
        downloader: ResumableMediaDownload(acceptUri: (u) => u == url),
      );
      addTearDown(store.dispose);
      await store.start(video, part);
      expect(count, 1);
      expect(
        (await store.entries()).where((e) => e.complete),
        isEmpty,
        reason:
            'A real MP4 with a picture but no audio must not be published as complete',
      );
    },
    skip: !const bool.fromEnvironment('COURSE_MEDIA_REPLAY')
        ? 'Opt-in; host ffmpeg required.'
        : false,
  );
}
