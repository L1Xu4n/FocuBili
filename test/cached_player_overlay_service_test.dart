import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/cached_player_overlay_service.dart';
import 'package:focubili/services/desktop_player_overlay_service.dart';

class _Cookies implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => '';
  @override
  Future<void> replaceCookies(String value) async {}
  @override
  Future<void> clearBilibiliCookies() async {}
}

DesktopOverlayHttpResponse _json(Object value) => DesktopOverlayHttpResponse(
  statusCode: 200,
  bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(value))),
);
DesktopOverlayHttpResponse _tracks(int version, {int cid = 1}) => _json({
  'code': 0,
  'data': {
    'bvid': 'BV1xx411c7mD',
    'cid': cid,
    'subtitle': {
      'subtitles': [
        {
          'id_str': '11',
          'lan': version == 1 ? 'zh' : 'en',
          'subtitle_url': 'https://aisubtitle.hdslb.com/$version.json',
        },
      ],
    },
  },
});
DesktopOverlayHttpResponse _cues(String text) => _json({
  'body': [
    {'from': 0, 'to': 1, 'content': text},
  ],
});

void main() {
  test(
    'expired subtitle URL cannot silently switch language under the same track ID',
    () async {
      var trackReads = 0, cueReads = 0;
      final service = DesktopPlayerOverlayService(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        request: (uri, headers, max) async {
          if (uri.path == '/x/player/v2') return _tracks(++trackReads);
          cueReads++;
          return DesktopOverlayHttpResponse(
            statusCode: 403,
            bodyBytes: Uint8List(0),
          );
        },
      );
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      final result = await service.loadSubtitleCues(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        trackId: '11',
      );
      expect(result.status, SubtitleLoadStatus.locked);
      expect(result.cues, isEmpty);
      expect(trackReads, 2);
      expect(cueReads, 1);
    },
  );

  test(
    'desktop rejects old cue response after successful same-CID track refresh',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      var version = 1;
      final service = DesktopPlayerOverlayService(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        request: (uri, headers, max) async {
          if (uri.path == '/x/player/v2') return _tracks(version);
          if (uri.path == '/1.json') {
            started.complete();
            await release.future;
          }
          return _cues(uri.path);
        },
      );
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      final old = service.loadSubtitleCues(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        trackId: '11',
      );
      await started.future;
      version = 2;
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      release.complete();
      expect((await old).status, SubtitleLoadStatus.unavailable);
      expect(
        (await service.loadSubtitleCues(
          bvid: 'BV1xx411c7mD',
          cid: 1,
          trackId: '11',
        )).cues.single.content,
        '/2.json',
      );
    },
  );

  for (final invalidation in ['refresh', 'clear', 'account', 'part']) {
    test('cached subtitles reject late cue on $invalidation', () async {
      final cache = SubtitleMemoryCache();
      final started = Completer<void>(), release = Completer<void>();
      var version = 1;
      final delegate = DesktopPlayerOverlayService(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        request: (uri, headers, max) async {
          if (uri.path == '/x/player/v2') {
            return _tracks(
              version,
              cid: int.parse(uri.queryParameters['cid']!),
            );
          }
          started.complete();
          await release.future;
          return _cues('old');
        },
      );
      final service = CachedPlayerOverlayService(delegate, cache: cache);
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      final old = service.loadSubtitleCues(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        trackId: '11',
      );
      await started.future;
      switch (invalidation) {
        case 'refresh':
          version = 2;
          await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
        case 'clear':
          CacheLifecycle.clearSubtitles();
        case 'account':
          CacheLifecycle.accountChanged();
        case 'part':
          await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 2);
      }
      release.complete();
      final result = await old;
      if (invalidation == 'part') {
        // Independent parts retain their own correctly bound result. The UI
        // generation gate decides whether that part is still on screen.
        expect(result.cues.single.content, 'old');
      } else {
        expect(result.status, SubtitleLoadStatus.unavailable);
        expect(cache.usage.value, 0);
      }
      service.dispose();
      cache.dispose();
    });
  }
  test(
    '20 duplicate cue reads coalesce; reuse expires after five minutes',
    () async {
      var now = DateTime.utc(2026), requests = 0;
      final cache = SubtitleMemoryCache();
      final service = CachedPlayerOverlayService(
        DesktopPlayerOverlayService(
          authService: BilibiliAuthService(cookieStore: _Cookies()),
          request: (uri, headers, max) async {
            if (uri.path == '/x/player/v2') return _tracks(1);
            requests++;
            return _cues('same');
          },
        ),
        cache: cache,
        clock: () => now,
      );
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      Future<SubtitleCueLoadResult> read() =>
          service.loadSubtitleCues(bvid: 'BV1xx411c7mD', cid: 1, trackId: '11');
      await Future.wait(List.generate(20, (_) => read()));
      await read();
      expect(requests, 1);
      now = now.add(const Duration(minutes: 6));
      await read();
      expect(requests, 2);
      service.dispose();
      cache.dispose();
    },
  );
  test(
    'subtitle payload budget uses LRU access, exact capacity and clear counts',
    () {
      final cache = SubtitleMemoryCache(capacityBytes: 34);
      final now = DateTime.utc(2026);
      const cue = SubtitleCueLoadResult(
        status: SubtitleLoadStatus.available,
        message: '',
        cues: [
          SubtitleCue(
            from: Duration.zero,
            to: Duration(seconds: 1),
            content: 'a',
          ),
        ],
      );
      cache.put('A', cue, now);
      cache.put('B', cue, now);
      expect(cache.usage.value, 34);
      cache.get('A', now);
      cache.put('C', cue, now);
      expect(cache.get('B', now), isNull);
      expect(cache.get('A', now), isNotNull);
      cache.clear();
      expect(cache.usage.value, 0);
      cache.dispose();
    },
  );
}
