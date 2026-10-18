import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';

import 'classroom_access_test.dart' show course;
import 'classroom_account_race_test.dart' show SyntheticCourseSources;
import 'listening_playback_test.dart' show ListeningPlayer, ListeningSources;
import 'windows_local_source_resume_test.dart' show QuietLocalStreams;

class _Streams extends QuietLocalStreams {
  final errors = StreamController<String>.broadcast();
  @override
  Stream<String> get error => errors.stream;
}

class _Player extends ListeningPlayer {
  final events = _Streams();
  Completer<void>? stopGate;
  Completer<void>? pauseGate;
  Completer<void>? openGate;
  Completer<void>? playGate;
  final openEntered = Completer<void>();
  final playEntered = Completer<void>();
  final stopEntered = Completer<void>();
  int stops = 0;
  @override
  PlayerStream get stream => events;
  @override
  Future<void> stop() async {
    stops++;
    if (stopGate != null) {
      if (!stopEntered.isCompleted) stopEntered.complete();
      await stopGate!.future;
    }
    await super.stop();
  }

  @override
  Future<void> pause() async {
    await pauseGate?.future;
    await super.pause();
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (openGate != null) {
      if (!openEntered.isCompleted) openEntered.complete();
      await openGate!.future;
    }
    await super.open(playable, play: play);
  }

  @override
  Future<void> play() async {
    if (playGate != null) {
      if (!playEntered.isCompleted) playEntered.complete();
      await playGate!.future;
    }
    await super.play();
  }
}

class _DelayedSources extends ListeningSources {
  final entered = Completer<void>();
  @override
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
  }) {
    if (gate != null && !entered.isCompleted) entered.complete();
    return super.load(bvid: bvid, cid: cid, quality: quality);
  }
}

Future<void> _until(bool Function() predicate) async {
  final timeout = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate() && DateTime.now().isBefore(timeout)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    predicate(),
    isTrue,
    reason: 'Synthetic playback event did not arrive',
  );
}

class _Harness {
  final player = _Player();
  final snapshots = <PlaybackSnapshot>[];
  late final WindowsPlaybackService service;
  late final StreamSubscription<PlaybackSnapshot> subscription;
  String raw = '{"seekable-ranges":[{"start":20,"end":45}]}';
  Completer<String>? nextRead;
  int reads = 0;
  _Harness({BilibiliDesktopPlaybackSourceService? source}) {
    service = WindowsPlaybackService(
      player: player,
      sourceService: source ?? SyntheticCourseSources(),
      bufferStateReader: () {
        reads++;
        return nextRead?.future ?? Future.value(raw);
      },
    );
    subscription = service.states.listen(snapshots.add);
  }
  PlaybackSnapshot get latest => snapshots.last;
  Future<void> open([VideoPreview? video]) async {
    await service.initialize();
    await service.openVideo(video ?? VideoPreview.placeholder());
    await _until(
      () => snapshots.isNotEmpty && latest.bufferedRanges.isNotEmpty,
    );
  }

  Future<Completer<String>> holdSample() async {
    final before = reads;
    final gate = nextRead = Completer<String>();
    await _until(() => reads > before);
    return gate;
  }

  Future<void> close() async {
    if (nextRead != null && !nextRead!.isCompleted) nextRead!.complete('{}');
    if (player.stopGate != null && !player.stopGate!.isCompleted) {
      player.stopGate!.complete();
    }
    if (player.pauseGate != null && !player.pauseGate!.isCompleted) {
      player.pauseGate!.complete();
    }
    if (player.openGate != null && !player.openGate!.isCompleted) {
      player.openGate!.complete();
    }
    if (player.playGate != null && !player.playGate!.isCompleted) {
      player.playGate!.complete();
    }
    await subscription.cancel();
    await service.dispose();
    await player.events.errors.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'sampler keeps disjoint ranges and real pause intent together',
    () async {
      final h = _Harness()
        ..raw =
            '{"seekable-ranges":[{"start":20,"end":45},{"start":80,"end":90}]}';
      try {
        await h.open();
        expect(h.latest.playRequested, isTrue);
        expect(h.latest.bufferedRanges.map((r) => r.start.inSeconds), [20, 80]);
        await h.service.pause();
        await _until(() => h.latest.playRequested == false);
        expect(h.latest.isPlaying, isFalse);
        expect(h.latest.bufferedRanges, hasLength(2));
        await h.service.play();
        await _until(() => h.latest.playRequested == true);
      } finally {
        await h.close();
      }
    },
  );

  test(
    'pause intent is published before a delayed no-op backend pause completes',
    () async {
      final h = _Harness();
      try {
        await h.open();
        final sample = await h.holdSample();
        h.player.current = h.player.current.copyWith(
          playing: false,
          buffering: true,
        );
        h.player.pauseGate = Completer<void>();
        final paused = h.service.pause();
        await Future<void>.delayed(Duration.zero);
        expect(h.latest.playRequested, isFalse);
        expect(h.latest.isPlaying, isFalse);
        h.player.pauseGate!.complete();
        await paused;
        sample.complete('{}');
      } finally {
        await h.close();
      }
    },
  );

  for (final requested in [false, true]) {
    test(
      'buffering source/quality switches preserve play intent=$requested',
      () async {
        final h = _Harness(source: ListeningSources());
        try {
          await h.open();
          if (!requested) await h.service.pause();
          h.player.current = h.player.current.copyWith(
            playing: false,
            buffering: true,
          );
          await h.service.selectQuality(80);
          await Future<void>.delayed(Duration.zero);
          expect(h.latest.playRequested, requested);
          expect(h.player.state.playing, requested);
          h.player.current = h.player.current.copyWith(
            playing: false,
            buffering: true,
          );
          await h.service.setAudioOnly(true);
          await Future<void>.delayed(Duration.zero);
          expect(h.latest.audioOnly, isTrue);
          expect(h.latest.playRequested, requested);
          expect(h.player.state.playing, requested);
        } finally {
          await h.close();
        }
      },
    );
  }

  for (final audioOnly in [false, true]) {
    for (final stage in ['source load', 'media open', 'media play']) {
      test(
        'explicit pause wins during ${audioOnly ? 'audio' : 'quality'} $stage',
        () async {
          final sources = _DelayedSources();
          final h = _Harness(source: sources);
          try {
            await h.open();
            final playsBefore = h.player.plays;
            final gate = Completer<void>();
            if (stage == 'media open') {
              h.player.openGate = gate;
            } else if (stage == 'media play') {
              h.player.playGate = gate;
            } else {
              sources.gate = gate;
            }
            final switching = audioOnly
                ? h.service.setAudioOnly(true)
                : h.service.selectQuality(80);
            await (stage == 'media open'
                ? h.player.openEntered.future
                : stage == 'media play'
                ? h.player.playEntered.future
                : sources.entered.future);
            await h.service.pause();
            await Future<void>.delayed(Duration.zero);
            expect(h.latest.playRequested, isFalse);
            gate.complete();
            await switching;
            await Future<void>.delayed(Duration.zero);
            expect(h.latest.audioOnly, audioOnly);
            expect(h.latest.playRequested, isFalse);
            expect(h.player.state.playing, isFalse);
            expect(
              h.player.plays,
              playsBefore + (stage == 'media play' ? 1 : 0),
              reason: 'Captured pre-pause intent cannot restart playback',
            );
          } finally {
            if (sources.gate != null && !sources.gate!.isCompleted) {
              sources.gate!.complete();
            }
            await h.close();
          }
        },
      );
    }
  }

  for (final switchVideo in [false, true]) {
    test(
      'late sample cannot cross ${switchVideo ? 'BV' : 'CID'} source change',
      () async {
        final h = _Harness();
        try {
          await h.open();
          final old = await h.holdSample();
          final replacement = switchVideo
              ? const VideoPreview(
                  bvid: 'BV1xx411c7mD',
                  cid: 987,
                  title: 'Synthetic next video',
                  ownerName: 'Synthetic author',
                  parts: [],
                )
              : VideoPreview.placeholder();
          await h.service.openVideo(
            replacement,
            part: const VideoPart(
              cid: 987,
              pageNumber: 2,
              title: 'Synthetic next chapter',
              duration: Duration(minutes: 3),
            ),
          );
          expect(h.latest.bufferedRanges, isEmpty);
          old.complete('{"seekable-ranges":[{"start":100,"end":150}]}');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(h.latest.bufferedRanges, isEmpty);
          h.nextRead = null;
          h.raw = '{"seekable-ranges":[{"start":5,"end":10}]}';
          await _until(() => h.latest.bufferedRanges.isNotEmpty);
          expect(
            h.latest.bufferedRanges.single.start,
            const Duration(seconds: 5),
          );
        } finally {
          await h.close();
        }
      },
    );
  }

  test(
    'course logout clears published buffer before stop and rejects pending sample',
    () async {
      final h = _Harness();
      try {
        await h.open(course);
        final old = await h.holdSample();
        h.player.stopGate = Completer<void>();
        CacheLifecycle.accountChanged();
        await h.player.stopEntered.future;
        await Future<void>.delayed(Duration.zero);
        expect(h.latest.bufferedRanges, isEmpty);
        expect(h.latest.playRequested, isFalse);
        old.complete('{"seekable-ranges":[{"start":90,"end":150}]}');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.latest.bufferedRanges, isEmpty);
        h.player.stopGate!.complete();
        await _until(() => h.player.state.duration == Duration.zero);
        expect(h.latest.bufferedRanges, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  test(
    'course logout stops after an already-issued late play command',
    () async {
      final h = _Harness();
      try {
        await h.open(course);
        await h.service.pause();
        h.player.playGate = Completer<void>();
        final stopsBefore = h.player.stops;
        final playing = h.service.play();
        await h.player.playEntered.future;
        CacheLifecycle.accountChanged();
        await Future<void>.delayed(Duration.zero);
        expect(
          h.player.stops,
          stopsBefore,
          reason: 'Stop must follow the pending play',
        );
        expect(h.latest.playRequested, isFalse);
        h.player.playGate!.complete();
        await playing;
        await _until(() => h.player.stops > stopsBefore);
        expect(h.player.state.playing, isFalse);
        expect(h.player.state.duration, Duration.zero);
        expect(h.latest.bufferedRanges, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  test('backup discards primary ranges and late primary sample', () async {
    final h = _Harness();
    try {
      await h.open();
      final old = await h.holdSample();
      h.player.current = const PlayerState(buffering: true);
      h.player.events.errors.add('Synthetic media failure');
      await _until(() => h.player.opened.length == 2);
      await _until(() => h.latest.phase == PlaybackPhase.ready);
      expect(h.player.opened.last.uri, contains('backup.mp4'));
      expect(h.latest.bufferedRanges, isEmpty);
      old.complete('{"seekable-ranges":[{"start":90,"end":150}]}');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.latest.bufferedRanges, isEmpty);
      h.nextRead = null;
      h.raw = '{"seekable-ranges":[{"start":7,"end":12}]}';
      await _until(() => h.latest.bufferedRanges.isNotEmpty);
      expect(h.latest.bufferedRanges.single.start, const Duration(seconds: 7));
    } finally {
      await h.close();
    }
  });

  test(
    'late sampler error cannot clear new source and disposal emits no late event',
    () async {
      final h = _Harness();
      try {
        await h.open();
        final old = await h.holdSample();
        await h.service.openVideo(VideoPreview.placeholder());
        await Future<void>.delayed(Duration.zero);
        final count = h.snapshots.length;
        old.completeError(StateError('Synthetic sampler failure'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.snapshots.length, count);
        h.nextRead = null;
        await _until(() => h.latest.bufferedRanges.isNotEmpty);
        final disposed = await h.holdSample();
        await h.service.dispose();
        final finalCount = h.snapshots.length;
        disposed.complete('{}');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.snapshots.length, finalCount);
      } finally {
        await h.close();
      }
    },
  );
}
