import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';

/// Contains only a synthetic cookie, never the user's real session.
class ReviewCookieStore implements BilibiliCookieStore {
  /// Returns a dummy session marker for checking request-header handling.
  @override
  Future<String> readCookies() async => 'SESSDATA=review_dummy';

  /// Discards writes in this isolated fixture.
  @override
  Future<void> replaceCookies(String cookieHeader) async {}

  /// Has no persistent cookies to remove.
  @override
  Future<void> clearBilibiliCookies() async {}
}

/// Supplies a fake API response without making network requests.
BilibiliDesktopPlaybackSourceService reviewService(String url) {
  return BilibiliDesktopPlaybackSourceService(
    authService: BilibiliAuthService(cookieStore: ReviewCookieStore()),
    requestJson: (uri, headers) async => jsonEncode({
      'code': 0,
      'data': {
        'quality': 64,
        'dash': {
          'video': [
            {'id': 64, 'codecs': 'avc1.64001F', 'base_url': url},
          ],
          'audio': [
            {
              'id': 30280,
              'codecs': 'mp4a.40.2',
              'base_url': 'https://audio.bilivideo.com/audio.m4s',
            },
          ],
        },
      },
    }),
  );
}

/// Checks media credential isolation and IPv6 private-address rejection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A newly allowed plaintext source must not receive session credentials.
  test('plaintext untrusted CDN source is rejected before playback', () async {
    await expectLater(
      reviewService(
        'http://cdn.example/video.m4s',
      ).load(bvid: 'BV1GJ411x7h7', cid: 137649199, quality: 64),
      throwsA(isA<DesktopPlaybackSourceException>()),
    );
  });

  /// Even a trusted HTTPS media server must not receive the API session.
  test('trusted media request does not carry login cookies', () async {
    final sources = await reviewService(
      'https://cdn.bilivideo.com/video.m4s',
    ).load(bvid: 'BV1GJ411x7h7', cid: 137649199, quality: 64);
    expect(sources.mediaHeaders.containsKey('Cookie'), isFalse);
  });

  /// ULA is private IPv6 and must not pass a public-media-only validator.
  test('IPv6 ULA source is rejected', () async {
    await expectLater(
      reviewService(
        'https://[fd00::1234]/video.m4s',
      ).load(bvid: 'BV1GJ411x7h7', cid: 137649199, quality: 64),
      throwsA(isA<DesktopPlaybackSourceException>()),
    );
  });
}
