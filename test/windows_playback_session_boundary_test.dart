import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'listening_playback_test.dart' show ListeningPlayer;
import 'windows_local_source_resume_test.dart' show QuietLocalStreams;

class ErrorStreams extends QuietLocalStreams {
  final errors = StreamController<String>.broadcast();
  @override
  Stream<String> get error => errors.stream;
}

class SessionSources extends BilibiliDesktopPlaybackSourceService {
  bool current = true;
  int validations = 0;
  Future<void> Function()? validateHook;
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
      await validateHook?.call();
      if (!current) throw const BilibiliPlaybackSessionException('changing');
    },
  );
}

class HeldPlayer extends ListeningPlayer {
  final events = ErrorStreams();
  @override
  PlayerStream get stream => events;
  @override
  Future<void> dispose() async => events.errors.close();
  Completer<void>? pauseGate, openGate, stopGate, playGate;
  final paused = Completer<void>();
  final opening = Completer<void>();
  final stopping = Completer<void>();
  final playing = Completer<void>();
  int pauses = 0;
  bool failFirstOpen = false;
  @override
  Future<void> play() async {
    if (playGate != null) {
      if (!playing.isCompleted) playing.complete();
      await playGate!.future;
    }
    await super.play();
  }

  @override
  Future<void> stop() async {
    if (stopGate != null) {
      if (!stopping.isCompleted) stopping.complete();
      await stopGate!.future;
    }
    await super.stop();
  }

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
  for (final error in [
    TimeoutException('synthetic timeout'),
    PlatformException(code: 'synthetic'),
  ]) {
    test(
      'post-play ${error.runtimeType} stops media without fallback',
      () async {
        final player = HeldPlayer();
        final sources = SessionSources()
          ..validateHook = () async {
            if (player.plays > 0) throw error;
          };
        final service = WindowsPlaybackService(
          player: player,
          sourceService: sources,
        );
        await expectLater(
          service.openVideo(VideoPreview.placeholder()),
          throwsA(isA<BilibiliPlaybackSessionException>()),
        );
        expect(player.opened, hasLength(1));
        expect(player.plays, 1);
        expect(player.state.playing, isFalse);
        await service.dispose();
      },
    );
  }
  test(
    'new media waits for revocation stop and survives its completion',
    () async {
      final player = HeldPlayer();
      final sources = SessionSources()
        ..validateHook = () async {
          if (player.plays > 0) {
            player.stopGate ??= Completer<void>();
            throw TimeoutException('synthetic timeout');
          }
        };
      final service = WindowsPlaybackService(
        player: player,
        sourceService: sources,
      );
      final old = service.openVideo(VideoPreview.placeholder());
      await player.stopping.future;
      sources.validateHook = null;
      final replacement = service.openVideo(VideoPreview.placeholder());
      await Future<void>.delayed(Duration.zero);
      expect(player.opened, hasLength(1));
      player.stopGate!.complete();
      await old;
      await replacement;
      expect(player.opened, hasLength(2));
      expect(player.state.playing, isTrue);
      await service.dispose();
    },
  );
  test(
    'late fallback rejection cannot overwrite the replacement video',
    () async {
      final player = HeldPlayer();
      final sources = SessionSources();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: sources,
      );
      await service.openVideo(VideoPreview.placeholder());
      final entered = Completer<void>();
      final release = Completer<void>();
      final states = <PlaybackSnapshot>[];
      final subscription = service.states.listen(states.add);
      sources.validateHook = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        throw const BilibiliPlaybackSessionException('changing');
      };
      player.current = const PlayerState(buffering: true);
      player.events.errors.add('synthetic');
      await entered.future.timeout(const Duration(seconds: 5));
      sources.validateHook = null;
      await service.openVideo(VideoPreview.placeholder());
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.opened, hasLength(2));
      expect(player.state.playing, isTrue);
      expect(states.last.phase, PlaybackPhase.ready);
      await subscription.cancel();
      await service.dispose();
    },
  );
  test(
    'pause during session validation prevents a later play command',
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
      final entered = Completer<void>();
      final release = Completer<void>();
      sources.validateHook = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final pending = service.play();
      await entered.future;
      await service.pause();
      release.complete();
      await pending;
      expect(player.plays, before);
      expect(player.state.playing, isFalse);
      await service.dispose();
    },
  );
  test('pause wins when an issued native play completes later', () async {
    final player = HeldPlayer();
    final sources = SessionSources();
    final service = WindowsPlaybackService(
      player: player,
      sourceService: sources,
    );
    await service.openVideo(VideoPreview.placeholder());
    await service.pause();
    player.playGate = Completer<void>();
    final pending = service.play();
    await player.playing.future;
    await service.pause();
    player.playGate!.complete();
    await pending;
    expect(player.state.playing, isFalse);
    await service.dispose();
  });
}
