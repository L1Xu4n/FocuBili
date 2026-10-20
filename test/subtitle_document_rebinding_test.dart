import 'dart:async';
import 'dart:convert';

import 'fixtures/subtitle_wbi_navigation.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/cached_player_overlay_service.dart';
import 'package:focubili/services/desktop_player_overlay_service.dart';
import 'package:focubili/services/player_overlay_service.dart';

const _bv = 'BV1GJ411x7h7';

class _Cookies implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => '';
  @override
  Future<void> replaceCookies(String value) async {}
  @override
  Future<void> clearBilibiliCookies() async {}
}

class _Channel implements PlayerOverlayPlatformChannel {
  _Channel({this.sameResource = false});
  final bool sameResource;
  var metadataReads = 0;
  var documentReads = 0;

  @override
  Future<Object?> invokeMethod(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (method == 'loadSubtitleTracks') {
      return {
        'status': 'available',
        'tracks': [
          {
            'id': '11',
            'language': 'zh',
            'documentId': ++metadataReads == 1 || sameResource
                ? 'original-document'
                : 'other-document',
            'isLocked': false,
          },
        ],
      };
    }
    if (++documentReads == 1) {
      throw PlatformException(code: 'subtitle_document_expired');
    }
    return {
      'status': 'available',
      'cues': [
        {'fromMs': 0, 'toMs': 1000, 'content': 'unrelated synthetic document'},
      ],
    };
  }
}

DesktopOverlayHttpResponse _json(Object value) => DesktopOverlayHttpResponse(
  statusCode: 200,
  bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(value))),
);

void main() {
  test(
    'Android signature renewal keeps the original document binding',
    () async {
      final channel = _Channel(sameResource: true);
      final service = NativePlayerOverlayService(platformChannel: channel);
      await service.loadSubtitleTracks(bvid: _bv, cid: 1);
      final result = await service.loadSubtitleCues(
        bvid: _bv,
        cid: 1,
        trackId: '11',
      );
      expect(result.status, SubtitleLoadStatus.available);
      expect(channel.documentReads, 2);
    },
  );

  for (final expire in [false, true]) {
    test(
      'Android late ${expire ? 'expiry' : 'document'} cannot survive a successful same-CID refresh',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final channel = _DelayedChannel(started, release, expire: expire);
        final service = NativePlayerOverlayService(platformChannel: channel);
        await service.loadSubtitleTracks(bvid: _bv, cid: 1);
        final old = service.loadSubtitleCues(bvid: _bv, cid: 1, trackId: '11');
        await started.future;
        await service.loadSubtitleTracks(bvid: _bv, cid: 1);
        release.complete();
        expect((await old).status, SubtitleLoadStatus.unavailable);
        expect(channel.version, 2);
      },
    );
  }

  test(
    'Android expired retry rejects a different document with the same ID and language',
    () async {
      final channel = _Channel();
      final cache = SubtitleMemoryCache();
      final service = CachedPlayerOverlayService(
        NativePlayerOverlayService(platformChannel: channel),
        cache: cache,
      );
      addTearDown(service.dispose);
      addTearDown(cache.dispose);
      await service.loadSubtitleTracks(bvid: _bv, cid: 1);
      final result = await service.loadSubtitleCues(
        bvid: _bv,
        cid: 1,
        trackId: '11',
      );
      expect(result.status, SubtitleLoadStatus.locked);
      expect(result.cues, isEmpty);
      expect(channel.documentReads, 1);
      expect(cache.usage.value, 0);
    },
  );

  for (final sameResource in [false, true]) {
    test(
      'desktop expired retry ${sameResource ? 'allows renewed signature' : 'rejects document rebinding'}',
      () async {
        var metadataReads = 0;
        var documentReads = 0;
        final cache = SubtitleMemoryCache();
        final service = CachedPlayerOverlayService(
          DesktopPlayerOverlayService(
            authService: BilibiliAuthService(cookieStore: _Cookies()),
            request: (uri, headers, maximumBytes) async {
              if (uri.path == '/x/web-interface/nav') {
                return subtitleWbiNavigation();
              }
              if (uri.path == '/x/player/wbi/v2') {
                final version = ++metadataReads;
                return _json({
                  'code': 0,
                  'data': {
                    'bvid': _bv,
                    'cid': 1,
                    'subtitle': {
                      'subtitles': [
                        {
                          'id_str': '11',
                          'lan': 'zh',
                          'subtitle_url':
                              'https://aisubtitle.hdslb.com/${sameResource || version == 1 ? 'original' : 'other'}.json?signature=$version',
                        },
                      ],
                    },
                  },
                });
              }
              if (++documentReads == 1) {
                return DesktopOverlayHttpResponse(
                  statusCode: 403,
                  bodyBytes: Uint8List(0),
                );
              }
              return _json({
                'body': [
                  {'from': 0, 'to': 1, 'content': 'synthetic document'},
                ],
              });
            },
          ),
          cache: cache,
        );
        addTearDown(service.dispose);
        addTearDown(cache.dispose);
        await service.loadSubtitleTracks(bvid: _bv, cid: 1);
        final result = await service.loadSubtitleCues(
          bvid: _bv,
          cid: 1,
          trackId: '11',
        );
        expect(
          result.status,
          sameResource
              ? SubtitleLoadStatus.available
              : SubtitleLoadStatus.locked,
        );
        expect(documentReads, sameResource ? 2 : 1);
        if (!sameResource) {
          expect(result.cues, isEmpty);
          expect(cache.usage.value, 0);
        }
      },
    );
  }
}

class _DelayedChannel implements PlayerOverlayPlatformChannel {
  _DelayedChannel(this.started, this.release, {required this.expire});
  final Completer<void> started;
  final Completer<void> release;
  final bool expire;
  var version = 0;

  @override
  Future<Object?> invokeMethod(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (method == 'loadSubtitleTracks') {
      return {
        'status': 'available',
        'tracks': [
          {
            'id': '11',
            'language': 'zh',
            'documentId': 'document-${++version}',
            'isLocked': false,
          },
        ],
      };
    }
    expect(args?['documentId'], 'document-1');
    started.complete();
    await release.future;
    if (expire) throw PlatformException(code: 'subtitle_document_expired');
    return {
      'status': 'available',
      'cues': [
        {'fromMs': 0, 'toMs': 1000, 'content': 'old synthetic document'},
      ],
    };
  }
}
