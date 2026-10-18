import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'listening_playback_test.dart' show ListeningPlayer;

class SessionSources extends BilibiliDesktopPlaybackSourceService {
  bool current = true;
  int validations = 0;
  @override
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
  }) async => DesktopPlaybackSources(
    videoUrls: const [
      'https://video.bilivideo.com/synthetic.m4s',
      'https://backup.bilivideo.com/synthetic.m4s',
    ],
    audioUrls: const ['https://audio.bilivideo.com/synthetic.m4s'],
    referer: '',
    cookieHeader: '',
    actualQuality: 64,
    qualities: const [],
    videoCodec: 'avc1',
    audioCodec: 'mp4a',
    validateSession: () async {
      validations++;
      if (!current) throw const BilibiliPlaybackSessionException('changing');
    },
  );
}

class HeldPlayer extends ListeningPlayer {
  Completer<void>? pauseGate, openGate;
  final paused = Completer<void>();
  final opening = Completer<void>();
  int pauses = 0;
  bool failFirstOpen = false;
  @override
  Future<void> pause() async {
    pauses++;
    await super.pause();
    // openVideo pauses once before load and once after session publication.
    if (pauses == 2 && pauseGate != null) {
      paused.complete();
      await pauseGate!.future;
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    await super.open(playable, play: play);
    if (openGate != null && !opening.isCompleted) {
      opening.complete();
      await openGate!.future;
    }
    if (failFirstOpen) {
      failFirstOpen = false;
      throw StateError('synthetic media failure');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('session change during pause never opens old media or backup', () async {
    final player = HeldPlayer()..pauseGate = Completer<void>();
    final sources = SessionSources();
    final service = WindowsPlaybackService(
      player: player,
      sourceService: sources,
    );
    final pending = service.openVideo(VideoPreview.placeholder());
    final rejected = expectLater(
      pending,
      throwsA(isA<BilibiliPlaybackSessionException>()),
    );
    await player.paused.future;
    sources.current = false;
    player.pauseGate!.complete();
    await rejected;
    expect(player.opened, isEmpty);
    expect(player.plays, 0);
    await service.dispose();
  });
  test(
    'session change during native open stops without playing or fallback',
    () async {
      final player = HeldPlayer()..openGate = Completer<void>();
      final sources = SessionSources();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: sources,
      );
      final pending = service.openVideo(VideoPreview.placeholder());
      final rejected = expectLater(
        pending,
        throwsA(isA<BilibiliPlaybackSessionException>()),
      );
      await player.opening.future;
      sources.current = false;
      player.openGate!.complete();
      await rejected;
      expect(player.opened, hasLength(1));
      expect(player.plays, 0);
      expect(player.state.playing, isFalse);
      await service.dispose();
    },
  );
  test(
    'resuming after session revocation cannot play previously authorized media',
    () async {
      final player = HeldPlayer();
      final sources = SessionSources();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: sources,
      );
      await service.openVideo(VideoPreview.placeholder());
      await service.pause();
      final before = player.plays;
      sources.current = false;
      await expectLater(
        service.play(),
        throwsA(isA<BilibiliPlaybackSessionException>()),
      );
      expect(player.plays, before);
      expect(player.state.playing, isFalse);
      await service.dispose();
    },
  );
}
