// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';

void main() {
  test(
    'live public read-only API probe (no account credentials)',
    () async {
      final observations = <Map<String, Object?>>[];
      Future<String> request(Uri uri) async {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        try {
          final req = await client.getUrl(uri);
          req.headers.set(
            'User-Agent',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36',
          );
          req.headers.set(
            'Referer',
            'https://space.bilibili.com/517327498/video',
          );
          final response = await req.close().timeout(
            const Duration(seconds: 20),
          );
          final body = await utf8.decodeStream(response);
          int? code;
          try {
            code = (jsonDecode(body) as Map)['code'] as int?;
          } catch (_) {}
          observations.add({
            'path': uri.path,
            'page':
                uri.queryParameters['pn'] ?? uri.queryParameters['page_num'],
            'http': response.statusCode,
            'businessCode': code,
          });
          if (response.statusCode != 200) {
            throw HttpException('HTTP ${response.statusCode}');
          }
          return body;
        } finally {
          client.close(force: true);
        }
      }

      final service = BilibiliHttpPublicContentService(requestJson: request);
      final profile = await service.loadProfile(517327498);
      print('PROFILE: ${profile.name}');
      try {
        final videos = await service.loadVideos(517327498);
        print(
          'CREATOR: ${videos.items.length}, hasMore=${videos.hasMore}, total=${videos.totalCount}',
        );
      } catch (error) {
        print('CREATOR_UNAVAILABLE: ${error.runtimeType}');
      }
      final first = await service.loadCollectionVideos(517327498, 3993361);
      final second = await service.loadCollectionVideos(
        517327498,
        3993361,
        page: 2,
      );
      expect(first.items.length, 20);
      expect(first.hasMore, true);
      expect(second.items.length, 2);
      expect(second.hasMore, false);
      print(
        'COLLECTION: page1=${first.items.length}, page2=${second.items.length}, total=${first.totalCount}',
      );
      final evidence = {
        'testedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'authenticated': false,
        'profileName': profile.name,
        'collection': {
          'mid': 517327498,
          'seasonId': 3993361,
          'firstCount': first.items.length,
          'secondCount': second.items.length,
          'total': first.totalCount,
          'firstPagePublicationDates': first.items
              .map((e) => e.publishedAt?.toIso8601String())
              .toList(),
        },
        'requests': observations,
      };
      Directory('docs/beta').createSync(recursive: true);
      File(
        'docs/beta/api-verification.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
