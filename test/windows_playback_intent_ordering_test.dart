import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';

import 'listening_playback_test.dart' show ListeningPlayer, ListeningSources;
import 'classroom_access_test.dart' show course;
import 'windows_local_source_resume_test.dart' show QuietLocalStreams;

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

class _Streams extends QuietLocalStreams {
  final completions = StreamController<bool>.broadcast();
  @override
  Stream<bool> get completed => completions.stream;
}

// NativePlayer 1.2.6 serializes these operations through one lock. State is
// published before the mpv property command's Future completes.
class _OrderedPlayer extends ListeningPlayer {
  Future<void> _tail = Future<void>.value();
  _Gate? nextPlay;
  _Gate? nextPause;
  _Gate? nextSeek;
  bool resetNextAudioOpen = false;
  final streamEvents = _Streams();
  @override
  PlayerStream get stream => streamEvents;
  int pauseCalls = 0;
  final events = <String>[];

  Future<void> _ordered(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> play() {
    final gate = nextPlay;
    nextPlay = null;
    return _ordered(() async {
      events.add('play');
      await super.play();
      if (gate != null) {
        gate.entered.complete();
        await gate.release.future;
      }
    });
  }

  @override
  Future<void> pause() {
    pauseCalls++;
    final gate = nextPause;
    nextPause = null;
    return _ordered(() async {
      events.add('pause');
      await super.pause();
      if (gate != null) {
        gate.entered.complete();
        await gate.release.future;
      }
    });
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) => _ordered(
    () async {
      events.add('open');
      await super.open(playable, play: play);
      if (resetNextAudioOpen && (playable as Media).uri.contains('audio.m4s')) {
        resetNextAudioOpen = false;
        current = current.copyWith(position: Duration.zero);
      }
    },
  );

  @override
  Future<void> stop() => _ordered(() async {
    events.add('stop');
    await super.stop();
  });

  @override
  Future<void> seek(Duration position) {
    final gate = nextSeek;
    nextSeek = null;
    return _ordered(() async {
      events.add('seek');
      await super.seek(position);
      if (gate != null) {
        gate.entered.complete();
        await gate.release.future;
      }
    });
  }

  @override
  Future<void> dispose() async {
    await streamEvents.completions.close();
    await super.dispose();
  }
}

class _Sources extends ListeningSources {
  Completer<void>? loadEntered;

  @override
  Future<DesktopPlaybackSources> loadCourse({
    required VideoPreview video,
    required VideoPart part,
    required int quality,
  }) => load(bvid: video.bvid, cid: part.cid, quality: quality);

  @override
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
  }) {
    final entered = loadEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    return super.load(bvid: bvid, cid: cid, quality: quality);
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('latest resume wins while helper corrective pause is pending', () async {
    final player = _OrderedPlayer();
    final service = WindowsPlaybackService(
      player: player,
      sourceService: _Sources(),
    );
    final heldPlay = _Gate();
    final heldCorrection = _Gate();
    final snapshots = <PlaybackSnapshot>[];
    final subscription = service.states.listen(snapshots.add);
    try {
      await service.openVideo(VideoPreview.placeholder());
      await service.pause();
      player.nextPlay = heldPlay;
      final oldPlay = service.play();
      await heldPlay.entered.future;
      final explicitPause = service.pause();
      player.nextPause = heldCorrection;
      heldPlay.release.complete();
      await heldCorrection.entered.future;
      final latestResume = service.play();
      await Future<void>.delayed(Duration.zero);
      heldCorrection.release.complete();
      await Future.wait([oldPlay, explicitPause, latestResume]);
      await Future<void>.delayed(Duration.zero);
      expect(player.state.playing, isTrue);
      expect(snapshots.last.playRequested, isTrue);
    } finally {
      if (!heldPlay.release.isCompleted) heldPlay.release.complete();
      if (!heldCorrection.release.isCompleted) {
        heldCorrection.release.complete();
      }
      await subscription.cancel();
      await service.dispose();
    }
  });

  for (final newBvid in [false, true]) {
    test(
      'queued old play cannot unpause a new ${newBvid ? 'BV' : 'CID'}',
      () async {
        final player = _OrderedPlayer();
        final sources = _Sources();
        final service = WindowsPlaybackService(
          player: player,
          sourceService: sources,
        );
        final heldPlay = _Gate();
        try {
          await service.openVideo(VideoPreview.placeholder());
          await service.pause();
          player.nextPlay = heldPlay;
          final oldPlay = service.play();
          await heldPlay.entered.future;
          sources.gate = Completer<void>();
          sources.loadEntered = Completer<void>();
          final pauses = player.pauseCalls;
          final opening = service.openVideo(
            newBvid
                ? const VideoPreview(
                    bvid: 'BV1Q541167Qg',
                    cid: 987,
                    title: 'new',
                    ownerName: 'synthetic',
                    parts: [],
                  )
                : VideoPreview.placeholder(),
            part: const VideoPart(
              cid: 987,
              pageNumber: 2,
              title: 'new',
              duration: Duration(minutes: 3),
            ),
          );
          await _until(() => player.pauseCalls > pauses);
          heldPlay.release.complete();
          await sources.loadEntered!.future;
          await service.pause();
          sources.gate!.complete();
          await Future.wait([oldPlay, opening]);
          expect(player.state.playing, isFalse);
          expect(
            player.events.lastIndexOf('open'),
            greaterThan(player.events.indexOf('play')),
          );
        } finally {
          if (!heldPlay.release.isCompleted) heldPlay.release.complete();
          if (sources.gate != null && !sources.gate!.isCompleted) {
            sources.gate!.complete();
          }
          await service.dispose();
        }
      },
    );
  }

  for (final audio in [false, true]) {
    test(
      'resume during paused ${audio ? 'audio' : 'quality'} source load stays playing',
      () async {
        final player = _OrderedPlayer();
        final sources = _Sources();
        final service = WindowsPlaybackService(
          player: player,
          sourceService: sources,
        );
        final snapshots = <PlaybackSnapshot>[];
        final subscription = service.states.listen(snapshots.add);
        try {
          await service.openVideo(VideoPreview.placeholder());
          await service.pause();
          sources.gate = Completer<void>();
          sources.loadEntered = Completer<void>();
          final switching = audio
              ? service.setAudioOnly(true)
              : service.selectQuality(80);
          await sources.loadEntered!.future;
          await service.play();
          expect(player.state.playing, isTrue);
          sources.gate!.complete();
          await switching;
          await Future<void>.delayed(Duration.zero);
          expect(snapshots.last.playRequested, isTrue);
          expect(
            player.state.playing,
            isTrue,
            reason:
                'Newest explicit resume must survive the pending source switch',
          );
        } finally {
          if (sources.gate != null && !sources.gate!.isCompleted) {
            sources.gate!.complete();
          }
          await subscription.cancel();
          await service.dispose();
        }
      },
    );
  }

  for (final audio in [false, true]) {
    test(
      'ended ${audio ? 'audio' : 'quality'} switch stays paused without explicit resume',
      () async {
        final player = _OrderedPlayer();
        final service = WindowsPlaybackService(
          player: player,
          sourceService: _Sources(),
        );
        final snapshots = <PlaybackSnapshot>[];
        final subscription = service.states.listen(snapshots.add);
        try {
          await service.openVideo(VideoPreview.placeholder());
          player.current = player.current.copyWith(
            playing: false,
            position: player.state.duration,
          );
          player.streamEvents.completions.add(true);
          await _until(() => snapshots.last.phase == PlaybackPhase.ended);
          final playsBefore = player.plays;
          if (audio) {
            await service.setAudioOnly(true);
          } else {
            await service.selectQuality(80);
          }
          await Future<void>.delayed(Duration.zero);
          expect(player.state.playing, isFalse);
          expect(snapshots.last.playRequested, isFalse);
          expect(player.plays, playsBefore);
        } finally {
          await subscription.cancel();
          await service.dispose();
        }
      },
    );
  }

  test(
    'audio preparation restorePlayback false never starts before target seek drains',
    () async {
      final player = _OrderedPlayer();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: _Sources(),
      );
      final target = _Gate();
      try {
        await service.openVideo(
          VideoPreview.placeholder(),
          initialPosition: const Duration(seconds: 42),
        );
        final playsBefore = player.plays;
        player.resetNextAudioOpen = true;
        player.nextSeek = target;
        final switching = service.setAudioOnly(true);
        await target.entered.future;
        expect(player.state.position, const Duration(seconds: 42));
        expect(player.state.playing, isFalse);
        expect(
          player.plays,
          playsBefore,
          reason: 'Internal restore must not activate partially prepared media',
        );
        target.release.complete();
        await switching;
        expect(player.state.playing, isTrue);
        expect(player.plays, playsBefore + 1);
      } finally {
        if (!target.release.isCompleted) target.release.complete();
        await service.dispose();
      }
    },
  );

  for (final invalidation in ['account', 'BV', 'CID']) {
    test(
      'resume during quality load cannot cross $invalidation invalidation',
      () async {
        final player = _OrderedPlayer();
        final sources = _Sources();
        final service = WindowsPlaybackService(
          player: player,
          sourceService: sources,
        );
        final gate = Completer<void>();
        try {
          await service.openVideo(
            invalidation == 'account' ? course : VideoPreview.placeholder(),
          );
          await service.pause();
          sources.gate = gate;
          sources.loadEntered = Completer<void>();
          final switching = service.selectQuality(80);
          await sources.loadEntered!.future;
          await service.play();
          final opensBefore = player.opened.length;
          if (invalidation == 'account') {
            CacheLifecycle.accountChanged();
            await _until(() => player.state.duration == Duration.zero);
          } else {
            sources.gate = null;
            await service.openVideo(
              invalidation == 'BV'
                  ? const VideoPreview(
                      bvid: 'BV1Q541167Qg',
                      cid: 987,
                      title: 'Synthetic next',
                      ownerName: 'Synthetic',
                      parts: [],
                    )
                  : VideoPreview.placeholder(),
              part: const VideoPart(
                cid: 987,
                pageNumber: 2,
                title: 'Synthetic next',
                duration: Duration(minutes: 3),
              ),
            );
            await service.pause();
          }
          gate.complete();
          await switching;
          expect(player.state.playing, isFalse);
          expect(
            player.opened.length,
            opensBefore + (invalidation == 'account' ? 0 : 1),
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          await service.dispose();
        }
      },
    );
  }
}
