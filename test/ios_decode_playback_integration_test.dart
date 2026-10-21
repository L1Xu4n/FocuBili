import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/ios_decode_preferences.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/ios_decode_session.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'listening_playback_test.dart' show ListeningPlayer;
import 'windows_playback_session_boundary_test.dart' show SessionSources;

class _Cookies implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => '';
  @override
  Future<void> replaceCookies(String value) async {}
  @override
  Future<void> clearBilibiliCookies() async {}
}

class _OrderedPlayer extends ListeningPlayer {
  final events = <String>[];
  bool failHevc = false;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    events.add('open');
    if (failHevc) {
      failHevc = false;
      throw StateError('synthetic HEVC decode failure');
    }
    await super.open(playable, play: play);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'playback service applies persisted modes before every video/quality open and releases the session',
    () async {
      final player = _OrderedPlayer();
      var actual = '';
      final decode = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: const PlaybackPreferencesService().load,
        readProperty: (_) async => actual,
        writeProperty: (_, value) async {
          actual = value;
          player.events.add(value);
        },
        canReadVideo: () => false,
      );
      final service = WindowsPlaybackService(
        player: player,
        sourceService: SessionSources(),
        decodeSession: decode,
      );
      await service.openVideo(VideoPreview.placeholder());
      expect(player.events, ['auto-copy', 'open']);
      await const PlaybackPreferencesService().saveIosDecodeMode(
        IosDecodeMode.software,
      );
      await service.selectQuality(64);
      expect(player.events, ['auto-copy', 'open', 'no', 'open']);
      await const PlaybackPreferencesService().saveIosDecodeMode(
        IosDecodeMode.videoToolbox,
      );
      await service.openVideo(VideoPreview.placeholder());
      expect(player.events.sublist(4), ['videotoolbox-copy', 'open']);
      await service.dispose();
      expect(await decode.configure(isCurrent: () => true), isFalse);
    },
  );

  test(
    'session revocation during preference loading cannot open or play media',
    () async {
      final gate = Completer<PlaybackPreferences>();
      final entered = Completer<void>();
      final sources = SessionSources();
      final player = _OrderedPlayer();
      final decode = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () {
          entered.complete();
          return gate.future;
        },
        readProperty: (_) async => 'auto-copy',
        writeProperty: (_, value) async => player.events.add(value),
        canReadVideo: () => false,
      );
      final service = WindowsPlaybackService(
        player: player,
        sourceService: sources,
        decodeSession: decode,
      );
      final pending = service.openVideo(VideoPreview.placeholder());
      final rejected = expectLater(
        pending,
        throwsA(isA<BilibiliPlaybackSessionException>()),
      );
      await entered.future;
      sources.current = false;
      gate.complete(const PlaybackPreferences());
      await rejected;
      expect(player.events, ['auto-copy']);
      expect(player.opened, isEmpty);
      expect(player.plays, 0);
      await service.dispose();
    },
  );

  test(
    'a failed preferred media attempt reaches the compatible source through existing recovery',
    () async {
      final player = _OrderedPlayer()..failHevc = true;
      await const PlaybackPreferencesService().saveIosVideoCodec(
        IosVideoCodecPreference.hevc,
      );
      final sources = BilibiliDesktopPlaybackSourceService(
        platform: AppPlatform.ios,
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        requestJson: (_, _) async => jsonEncode({
          'code': 0,
          'data': {
            'quality': 64,
            'dash': {
              'video': [
                {
                  'id': 64,
                  'codecs': 'hev1.1.6.L120',
                  'base_url': 'https://video.bilivideo.com/preferred-hevc.m4s',
                },
                {
                  'id': 64,
                  'codecs': 'avc1.64001F',
                  'base_url': 'https://video.bilivideo.com/fallback-avc.m4s',
                },
              ],
              'audio': [
                {
                  'id': 30280,
                  'codecs': 'mp4a.40.2',
                  'base_url': 'https://audio.bilivideo.com/a.m4s',
                },
              ],
            },
          },
        }),
      );
      final service = WindowsPlaybackService(
        player: player,
        sourceService: sources,
      );
      await service.openVideo(VideoPreview.placeholder());
      expect(player.events, ['open', 'open']);
      expect(player.opened.single.uri, contains('fallback-avc.m4s'));
      await service.dispose();
    },
  );
}
