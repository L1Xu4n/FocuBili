import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/offline_video_service.dart';
import 'package:focubili/services/media_url_policy.dart';
import 'package:focubili/services/download_control.dart';

/// Keeps all credentials synthetic and entirely in memory.
class TestCookieStore implements BilibiliCookieStore {
  /// Returns a recognizable dummy API session.
  @override
  Future<String> readCookies() async => 'SESSDATA=synthetic';

  /// Discards account updates in tests.
  @override
  Future<void> replaceCookies(String cookieHeader) async {}

  /// Does not touch the real login store.
  @override
  Future<void> clearBilibiliCookies() async {}
}

/// Simulates a disk that rejects writes rather than throwing.
class RejectedPreferences extends Fake implements SharedPreferences {
  /// Starts without metadata, just like a fresh install.
  @override
  String? getString(String key) => null;

  /// Reports a failed persistent write.
  @override
  Future<bool> setString(String key, String value) async => false;
}

/// Creates a stable two-part fixture for part-scoped downloads.
VideoPreview fixture() => const VideoPreview(
  bvid: 'BV1GJ411x7h7',
  cid: 11,
  title: 'Review',
  ownerName: 'Review',
  duration: Duration(seconds: 30),
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 11,
      title: 'One',
      duration: Duration(seconds: 10),
    ),
    VideoPart(
      pageNumber: 2,
      cid: 22,
      title: 'Two',
      duration: Duration(seconds: 20),
    ),
  ],
);

/// Supplies a progressive response without using any real service.
String response({int segments = 1, int size = 3}) => jsonEncode({
  'code': 0,
  'data': {
    'quality': 32,
    'durl': List.generate(
      segments,
      (_) => {'url': 'https://cdn.bilivideo.com/video.mp4', 'size': size},
    ),
  },
});

/// Covers the new persistence and media trust boundaries end to end in isolation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  /// Creates a dedicated owned temporary root and an empty preferences store.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('focubili-v151-integrity-');
  });

  /// Deletes only the temporary root created by this test.
  tearDown(() async {
    await root.delete(recursive: true);
  });

  /// Builds a service that records media headers and writes tiny deterministic files.
  OfflineVideoService service({
    SharedPreferences? preferences,
    String? payload,
    int written = 3,
  }) => OfflineVideoService(
    directoryLoader: () async => root,
    cookieStore: TestCookieStore(),
    preferencesLoader: () async =>
        preferences ?? await SharedPreferences.getInstance(),
    requestText: (uri, headers) async {
      expect(headers['Cookie'], 'SESSDATA=synthetic');
      return payload ?? response();
    },
    downloadFile: (uri, headers, file, progress) async {
      expect(headers.containsKey('Cookie'), isFalse);
      expect(uri.scheme, 'https');
      await file.writeAsBytes(List.filled(written, 1));
      return written;
    },
  );

  test(
    'two parts persist separately and deleting one preserves the other',
    () async {
      final api = service();
      final video = fixture();
      await api.download(video);
      await api.download(video, part: video.parts.last);
      expect((await api.loadDownloads()).map((e) => e.cid).toSet(), {11, 22});
      expect(await api.delete(video.bvid, cid: 11), isTrue);
      expect(await api.isDownloaded(video.bvid, cid: 11), isFalse);
      expect(await api.isDownloaded(video.bvid, cid: 22), isTrue);
    },
  );

  test(
    'pause cancels a stalled playurl lookup without waiting for its response',
    () async {
      final requested = Completer<void>();
      final responsePending = Completer<String>();
      final api = OfflineVideoService(
        directoryLoader: () async => root,
        cookieStore: TestCookieStore(),
        requestText: (_, _) {
          requested.complete();
          return responsePending.future;
        },
        downloadFile: (_, _, _, _) async =>
            fail('Paused task started media transfer'),
      );
      final control = DownloadControl();
      final running = api.download(fixture(), control: control);
      final cancelled = expectLater(
        running,
        throwsA(isA<DownloadInterrupted>()),
      );
      await requested.future;
      control.interrupt();
      await cancelled.timeout(const Duration(seconds: 1));
      responsePending.complete(response());
      await Future<void>.delayed(Duration.zero);
      expect(await api.loadDownloads(), isEmpty);
    },
  );

  test(
    'rejected storage write removes unpublished file and reports failure',
    () async {
      await expectLater(
        service(preferences: RejectedPreferences()).download(fixture()),
        throwsA(isA<OfflineVideoException>()),
      );
      expect(
        await root.list(recursive: true).where((e) => e is File).toList(),
        isEmpty,
      );
    },
  );

  test('truncated media is not published', () async {
    await expectLater(
      service(written: 2).download(fixture()),
      throwsA(isA<OfflineVideoException>()),
    );
    expect(await service().loadDownloads(), isEmpty);
    expect(
      await root.list(recursive: true).where((e) => e is File).toList(),
      isEmpty,
    );
  });

  test('multi-segment response is explicitly unsupported', () async {
    await expectLater(
      service(payload: response(segments: 2)).download(fixture()),
      throwsA(
        isA<OfflineVideoException>().having(
          (e) => e.message,
          'message',
          contains('多段'),
        ),
      ),
    );
  });

  test('damaged metadata is retained and new downloads fail safely', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('focubili_offline_videos_v1', 'broken');
    await expectLater(
      service().download(fixture()),
      throwsA(isA<OfflineVideoException>()),
    );
    expect(prefs.getString('focubili_offline_videos_v1'), 'broken');
    expect(
      await root.list(recursive: true).where((e) => e is File).toList(),
      isEmpty,
    );
  });

  test(
    'media policy blocks IPs, lookalikes, credentials and insecure hops',
    () {
      for (final url in [
        'https://[fd00::1]/x',
        'https://127.0.0.1/x',
        'https://localhost/x',
        'https://bilivideo.com.evil.example/x',
        'https://user@cdn.bilivideo.com/x',
        'http://cdn.bilivideo.com/x',
      ]) {
        expect(MediaUrlPolicy.isSafe(url), isFalse, reason: url);
      }
      expect(
        MediaUrlPolicy.normalize('http://cdn.bilivideo.com/x'),
        startsWith('https:'),
      );
      expect(MediaUrlPolicy.normalize('http://127.0.0.1/x'), isNull);
      expect(MediaUrlPolicy.isSafe('https://new.bilivideo.cn:4483/x'), isTrue);
    },
  );
}
