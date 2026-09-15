import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/offline_video_download.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/offline_video_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用内存字符串模拟平台 Cookie 容器，确保测试不会接触真实账号会话。
class _MemoryCookieStore implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => '';

  @override
  Future<void> replaceCookies(String cookieHeader) async {}

  @override
  Future<void> clearBilibiliCookies() async {}
}

/// 生成固定 BV 号的视频详情，下载测试始终使用同一分P。
VideoPreview _preview() {
  return const VideoPreview(
    bvid: 'BV1GJ411x7h7',
    cid: 137649199,
    title: '离线下载测试视频',
    ownerName: '焦点哔哩',
    duration: Duration(minutes: 3, seconds: 32),
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 137649199,
        title: '离线下载测试视频',
        duration: Duration(minutes: 3, seconds: 32),
      ),
    ],
  );
}

/// 构造只包含指定播放地址的 playurl 响应文本。
String _playResponse(String url, {int quality = 64}) {
  return jsonEncode(<String, Object?>{
    'code': 0,
    'message': '0',
    'data': <String, Object?>{
      'quality': quality,
      'durl': <Map<String, Object?>>[
        <String, Object?>{
          'url': url,
          'backup_url': <String>[],
        },
      ],
    },
  });
}

/// 验证离线下载的地址安全校验、失败重试与记录写入。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('公开新 CDN 域名可以正常下载并写入离线记录', () async {
    late Uri requestedPlayUrl;
    Uri? downloadedUri;
    final Directory root = await Directory.systemTemp.createTemp(
      'offline_video_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final OfflineVideoService service = OfflineVideoService(
      preferencesLoader: SharedPreferences.getInstance,
      directoryLoader: () async => root,
      cookieStore: _MemoryCookieStore(),
      requestText: (Uri uri, Map<String, String> _) async {
        requestedPlayUrl = uri;
        return _playResponse(
          'https://cdn-01.new-bilibili-cdn.example:4483/video.mp4',
        );
      },
      downloadFile: (
        Uri uri,
        Map<String, String> headers,
        File output,
        void Function(int received, int? total) onProgress,
      ) async {
        downloadedUri = uri;
        await output.writeAsBytes(List<int>.filled(1024, 1));
        onProgress(1024, 1024);
        return 1024;
      },
    );

    final OfflineVideoDownload download = await service.download(_preview());

    expect(requestedPlayUrl.host, 'api.bilibili.com');
    expect(downloadedUri, isNotNull);
    expect(downloadedUri!.host, 'cdn-01.new-bilibili-cdn.example');
    expect(download.filePath, contains('video.mp4'));
    expect(File(download.filePath).existsSync(), isTrue);
    expect(download.sizeBytes, 1024);
    expect(download.qualityLabel, '高清 720P');
    expect(download.status, OfflineDownloadStatus.ready);
  });

  test('B 站返回 http 地址时仍可下载（与 Seal 一致）', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'offline_video_test',
    );
    addTearDown(() => root.delete(recursive: true));
    Uri? downloadedUri;
    final OfflineVideoService service = OfflineVideoService(
      preferencesLoader: SharedPreferences.getInstance,
      directoryLoader: () async => root,
      cookieStore: _MemoryCookieStore(),
      requestText: (Uri _, Map<String, String> _) async {
        return _playResponse('http://node-http.bilivideo.com/video.mp4');
      },
      downloadFile: (
        Uri uri,
        Map<String, String> headers,
        File output,
        void Function(int received, int? total) onProgress,
      ) async {
        downloadedUri = uri;
        await output.writeAsBytes(List<int>.filled(64, 1));
        return 64;
      },
    );

    final OfflineVideoDownload download = await service.download(_preview());

    expect(downloadedUri, isNotNull);
    expect(downloadedUri!.scheme, 'http');
    expect(download.sizeBytes, 64);
    expect(download.status, OfflineDownloadStatus.ready);
  });

  test('主备地址全部失败时重新拉取播放地址并成功', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'offline_video_test',
    );
    addTearDown(() => root.delete(recursive: true));
    int requestCount = 0;
    final List<Uri> downloadedUris = <Uri>[];
    final OfflineVideoService service = OfflineVideoService(
      preferencesLoader: SharedPreferences.getInstance,
      directoryLoader: () async => root,
      cookieStore: _MemoryCookieStore(),
      requestText: (Uri _, Map<String, String> _) async {
        requestCount += 1;
        if (requestCount == 1) {
          return _playResponse(
            'https://node-a.bilivideo.com/video.mp4',
          );
        }
        return _playResponse(
          'https://node-b.bilivideo.com/video.mp4',
        );
      },
      downloadFile: (
        Uri uri,
        Map<String, String> headers,
        File output,
        void Function(int received, int? total) onProgress,
      ) async {
        if (downloadedUris.isEmpty) {
          downloadedUris.add(uri);
          throw const OfflineVideoException('下载连接中断，请检查网络后重试。');
        }
        downloadedUris.add(uri);
        await output.writeAsBytes(List<int>.filled(512, 1));
        return 512;
      },
    );

    final OfflineVideoDownload download = await service.download(_preview());

    expect(requestCount, 2);
    expect(downloadedUris, hasLength(2));
    expect(downloadedUris.first.host, 'node-a.bilivideo.com');
    expect(downloadedUris.last.host, 'node-b.bilivideo.com');
    expect(download.sizeBytes, 512);
  });

  test('两次尝试都失败时抛出明确错误', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'offline_video_test',
    );
    addTearDown(() => root.delete(recursive: true));
    int requestCount = 0;
    final OfflineVideoService service = OfflineVideoService(
      preferencesLoader: SharedPreferences.getInstance,
      directoryLoader: () async => root,
      cookieStore: _MemoryCookieStore(),
      requestText: (Uri _, Map<String, String> _) async {
        requestCount += 1;
        return _playResponse('https://node-a.bilivideo.com/video.mp4');
      },
      downloadFile: (
        Uri uri,
        Map<String, String> headers,
        File output,
        void Function(int received, int? total) onProgress,
      ) async {
        throw const OfflineVideoException('视频下载超时，请稍后重试。');
      },
    );

    await expectLater(
      service.download(_preview()),
      throwsA(
        isA<OfflineVideoException>().having(
          (OfflineVideoException error) => error.message,
          'message',
          contains('视频下载超时'),
        ),
      ),
    );
    expect(requestCount, 2);
  });

  test('只返回内网字面 IP 地址时拒绝下载', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'offline_video_test',
    );
    addTearDown(() => root.delete(recursive: true));
    final OfflineVideoService service = OfflineVideoService(
      preferencesLoader: SharedPreferences.getInstance,
      directoryLoader: () async => root,
      cookieStore: _MemoryCookieStore(),
      requestText: (Uri _, Map<String, String> _) async {
        return _playResponse('https://192.168.0.3/video.mp4');
      },
      downloadFile: (
        Uri uri,
        Map<String, String> headers,
        File output,
        void Function(int received, int? total) onProgress,
      ) async {
        fail('内网地址不应被下载');
      },
    );

    await expectLater(
      service.download(_preview()),
      throwsA(
        isA<OfflineVideoException>().having(
          (OfflineVideoException error) => error.message,
          'message',
          contains('不可用的下载地址'),
        ),
      ),
    );
  });
}
