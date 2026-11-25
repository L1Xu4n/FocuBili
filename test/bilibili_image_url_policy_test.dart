import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_image_url_policy.dart';

void main() {
  test(
    'resolves trusted hdslb/biliimg raw image URLs into four WebP variants',
    () {
      const String raw = 'http://i0.hdslb.com/bfs/archive/abcdef123456.jpg';
      expect(
        BilibiliImageUrlPolicy.resolve(
          raw,
          variant: BilibiliImageVariant.cover16x10,
        ),
        'https://i0.hdslb.com/bfs/archive/abcdef123456.jpg@320w_200h_1c.webp',
      );
      expect(
        BilibiliImageUrlPolicy.resolve(
          raw,
          variant: BilibiliImageVariant.cover16x9,
        ),
        'https://i0.hdslb.com/bfs/archive/abcdef123456.jpg@480w_270h_1c.webp',
      );
      expect(
        BilibiliImageUrlPolicy.resolve(
          raw,
          variant: BilibiliImageVariant.chapter,
        ),
        'https://i0.hdslb.com/bfs/archive/abcdef123456.jpg@320w_180h_1c.webp',
      );
      expect(
        BilibiliImageUrlPolicy.resolve(
          '//i1.biliimg.com/bfs/face/user.png',
          variant: BilibiliImageVariant.avatar,
        ),
        'https://i1.biliimg.com/bfs/face/user.png@160w_160h_1c.webp',
      );
    },
  );

  test(
    'preserves signed, transformed, gif, untrusted, port, or userinfo URLs untouched',
    () {
      const List<String> untouched = <String>[
        'https://i0.hdslb.com/bfs/archive/a.jpg@320w_200h_1c.webp',
        'https://i0.hdslb.com/bfs/face/avatar.gif',
        'https://i0.hdslb.com/bfs/archive/a.jpg?sign=keep',
        'https://i0.hdslb.com/bfs/archive/a.jpg#frag',
        'https://i0.hdslb.com:8443/bfs/archive/a.jpg',
        'https://user@i0.hdslb.com/bfs/archive/a.jpg',
        'https://evil-hdslb.com/bfs/archive/a.jpg',
        'https://example.com/cover.png',
        'http://127.0.0.1:8080/test.png',
      ];
      for (final String url in untouched) {
        expect(
          BilibiliImageUrlPolicy.resolve(
            url,
            variant: BilibiliImageVariant.cover16x9,
          ),
          url,
          reason: 'URL must remain unchanged: $url',
        );
      }
    },
  );

  test('identifies proven content-addressed archive and videoshot URLs only', () {
    expect(
      BilibiliImageUrlPolicy.isProvenImmutableContentUrl(
        Uri.parse(
          'https://i0.hdslb.com/bfs/archive/0123456789abcdef0123456789abcdef01234567.jpg@480w_270h_1c.webp',
        ),
      ),
      isTrue,
    );
    expect(
      BilibiliImageUrlPolicy.isProvenImmutableContentUrl(
        Uri.parse(
          'https://bimp.hdslb.com/videoshotpvhdboss/12345_abc12-0001.jpg@1600w.webp',
        ),
      ),
      isTrue,
    );
    expect(
      BilibiliImageUrlPolicy.isProvenImmutableContentUrl(
        Uri.parse(
          'https://i0.hdslb.com/bfs/face/0123456789abcdef0123456789abcdef01234567.jpg',
        ),
      ),
      isFalse,
    );
    expect(
      BilibiliImageUrlPolicy.isProvenImmutableContentUrl(
        Uri.parse('https://i0.hdslb.com/bfs/archive/short-name.jpg'),
      ),
      isFalse,
    );
  });
}
