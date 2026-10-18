import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/notes/video_note_composer.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/video_note_service.dart';

import 'player_ab_repeat_test.dart'
    show AbPlayback, AbOverlay, abVideo, mountAb, configureAb, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

class ReviewAbPlayback extends AbPlayback {
  int captures = 0;
  bool delayRestoreSnapshot = false;
  Completer<void>? captureGate;
  String? capturedPath;
  @override
  Future<void> seekTo(Duration position) async {
    if (delayRestoreSnapshot && position == const Duration(seconds: 20)) {
      seeks.add(position);
      completedSeekCids.add(currentCid);
      return;
    }
    await super.seekTo(position);
  }

  @override
  Future<String?> captureCurrentFrame() async {
    captures++;
    await captureGate?.future;
    return capturedPath;
  }
}

class ReviewNoteService extends VideoNoteService {
  final discarded = <String>[];
  @override
  Future<void> discardUnreferencedFrame(String path) async =>
      discarded.add(path);
}

class DelayedCaptureSeek extends ReviewAbPlayback {
  DelayedCaptureSeek(this.delayedPosition);
  final Duration delayedPosition;
  final gate = Completer<void>();
  @override
  Future<void> seekTo(Duration position) async {
    if (position == delayedPosition && !gate.isCompleted) {
      seeks.add(position);
      await gate.future;
      completedSeekCids.add(currentCid);
      emit(current.copyWith(phase: PlaybackPhase.ready, position: position));
      return;
    }
    await super.seekTo(position);
  }
}

Future<void> startOldNoteCapture(
  WidgetTester tester,
  ReviewAbPlayback p,
  VideoNoteService notes, {
  int initialPartCid = 101,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final now = DateTime(2026, 10, 18);
  await notes.saveNote(
    VideoNote(
      id: 'synthetic-old-note',
      bvid: abVideo.bvid,
      videoTitle: abVideo.title,
      ownerName: abVideo.ownerName,
      partCid: 101,
      partPageNumber: 1,
      partTitle: 'Words',
      title: 'Old note outside AB',
      body: 'Synthetic text',
      createdAt: now,
      updatedAt: now,
      position: const Duration(seconds: 5),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: abVideo,
        playbackService: p,
        playerOverlayService: AbOverlay(),
        offlineVideoService: ReviewOfflineLibrary(),
        videoNoteService: notes,
        initialPosition: const Duration(seconds: 20),
        initialPartCid: initialPartCid,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await configureAb(tester);
  if (initialPartCid == 101) {
    await tester.tap(find.byKey(const ValueKey('player-note-flag-hit-0')));
  } else {
    await tester.tap(find.text('记笔记').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('portrait-video-note-synthetic-old-note')),
    );
  }
  await tester.pumpAndSettle();
  expect(p.seeks, isEmpty);
  expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
  final composer = tester.widget<VideoNoteComposer>(
    find.byType(VideoNoteComposer),
  );
  composer.onIncludeFrameChanged(true);
  await tester.pump();
  composer.onSave();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final delayed in [
    const Duration(seconds: 5),
    const Duration(seconds: 20),
  ]) {
    testWidgets(
      'manual seek drains in-flight capture command at ${delayed.inSeconds}s before seeking 90',
      (tester) async {
        final p = DelayedCaptureSeek(delayed);
        await startOldNoteCapture(tester, p, VideoNoteService());
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(p.seeks.last, delayed);
        final commandsBeforeManual = p.seeks.toList();
        tester.widget<Slider>(find.byType(Slider).first).onChangeEnd!(0.75);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          p.seeks,
          commandsBeforeManual,
          reason: 'new command waits for the already-issued capture seek',
        );
        p.gate.complete();
        await tester.pumpAndSettle();
        expect(p.current.position, const Duration(seconds: 90));
        expect(p.seeks.last, const Duration(seconds: 90));
        expect(p.completedSeekCids.every((cid) => cid == 101), isTrue);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        await unmountAb(tester);
      },
    );
    testWidgets(
      'part change drains in-flight capture command at ${delayed.inSeconds}s before opening new CID',
      (tester) async {
        final p = DelayedCaptureSeek(delayed);
        await startOldNoteCapture(tester, p, VideoNoteService());
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(p.seeks.last, delayed);
        tester
            .widget<VideoNoteComposer>(find.byType(VideoNoteComposer))
            .onClose();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.ensureVisible(find.byKey(const Key('part-2')).first);
        await tester.tap(find.byKey(const Key('part-2')).first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(p.onlineOpens, 1);
        p.gate.complete();
        await tester.pumpAndSettle();
        expect(p.currentCid, 102);
        expect(p.completedSeekCids.every((cid) => cid == 101), isTrue);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        await unmountAb(tester);
      },
    );
  }

  testWidgets(
    'capture can visit another CID and return without waiting on its own whole operation',
    (tester) async {
      final p = ReviewAbPlayback();
      await startOldNoteCapture(
        tester,
        p,
        VideoNoteService(),
        initialPartCid: 102,
      );
      await tester.pumpAndSettle();
      expect(p.captures, 1);
      expect(p.onlineOpens, 3);
      expect(p.completedSeekCids, [101, 102]);
      expect(p.currentCid, 102);
      expect(p.current.position, const Duration(seconds: 20));
      expect(
        find.byKey(const Key('ab-repeat-marker-A')),
        findsNothing,
        reason: 'cross-CID capture retains the existing chapter-isolation rule',
      );
      await unmountAb(tester);
    },
  );

  testWidgets(
    'sleep expiry while capture is internally paused cancels capture resume',
    (tester) async {
      final p = ReviewAbPlayback()..captureGate = Completer<void>();
      p.current = p.current.copyWith(
        sleepTimerRemaining: const Duration(seconds: 10),
      );
      await startOldNoteCapture(tester, p, VideoNoteService());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(p.captures, 1);
      expect(p.current.isPlaying, isFalse);
      p.emit(p.current.copyWith(sleepTimerRemaining: Duration.zero));
      await tester.pump();
      p.captureGate!.complete();
      await tester.pumpAndSettle();
      expect(p.seeks, [
        const Duration(seconds: 5),
        const Duration(seconds: 20),
      ]);
      expect(p.plays, 0);
      expect(p.current.isPlaying, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await unmountAb(tester);
    },
  );

  testWidgets('review: native pause during delayed end seek must stay paused', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester, b: '02:00');
    p.seekGate = Completer<void>();
    p.at(120, playing: false, phase: PlaybackPhase.ended);
    await tester.pump();
    expect(p.seeks, hasLength(1));
    // An external/native pause updates playback state without _setPlaybackActive.
    // The media has reached A while the original seek Future is still pending.
    p.at(10, playing: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await p.pause();
    await tester.pump();
    p.seekGate!.complete();
    await tester.pumpAndSettle();
    final plays = p.plays;
    final playing = p.current.isPlaying;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await unmountAb(tester);
    expect(plays, 0);
    expect(playing, isFalse);
  });

  testWidgets('review: internal old-note capture preserves AB range', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notes = VideoNoteService();
    final now = DateTime(2026, 10, 18);
    await notes.saveNote(
      VideoNote(
        id: 'synthetic-old-note',
        bvid: abVideo.bvid,
        videoTitle: abVideo.title,
        ownerName: abVideo.ownerName,
        partCid: 101,
        partPageNumber: 1,
        partTitle: 'Words',
        title: 'Old note outside AB',
        body: 'Synthetic text',
        createdAt: now,
        updatedAt: now,
        position: const Duration(seconds: 5),
      ),
    );
    final p = ReviewAbPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: abVideo,
          playbackService: p,
          playerOverlayService: AbOverlay(),
          offlineVideoService: ReviewOfflineLibrary(),
          videoNoteService: notes,
          initialPosition: const Duration(seconds: 20),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await configureAb(tester);
    await tester.tap(find.byKey(const ValueKey('player-note-flag-hit-0')));
    await tester.pumpAndSettle();
    expect(p.seeks, isEmpty, reason: 'Selecting a note must not seek');
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
    final composer = tester.widget<VideoNoteComposer>(
      find.byType(VideoNoteComposer),
    );
    composer.onIncludeFrameChanged(true);
    await tester.pump();
    composer.onSave();
    await tester.pumpAndSettle();
    final hasRange = find
        .byKey(const Key('ab-repeat-marker-A'))
        .evaluate()
        .isNotEmpty;
    final captured = p.captures;
    final seeks = p.seeks.toList();
    await unmountAb(tester);
    expect(captured, 1);
    expect(seeks, [const Duration(seconds: 5), const Duration(seconds: 20)]);
    expect(
      hasRange,
      isTrue,
      reason: 'Temporary screenshot seek is not user navigation',
    );
  });
  for (final scenario in [(false, true), (true, true), (true, false)]) {
    testWidgets(
      'backend pause=${scenario.$2} during ended seek, audio background=${scenario.$1}',
      (tester) async {
        final p = AbPlayback();
        await mountAb(tester, p);
        if (scenario.$1) {
          await p.setAudioOnly(true);
          await tester.pumpAndSettle();
        }
        await configureAb(tester, b: '02:00');
        if (scenario.$1) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        p.seekGate = Completer<void>();
        p.at(120, playing: false, phase: PlaybackPhase.ended);
        await tester.pump();
        expect(p.seeks, hasLength(1));
        if (scenario.$2) {
          await p.pause();
          await tester.pump();
        }
        p.seekGate!.complete();
        await tester.pumpAndSettle();
        final plays = p.plays;
        final playing = p.current.isPlaying;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await unmountAb(tester);
        expect(plays, scenario.$2 ? 0 : 1);
        expect(playing, !scenario.$2);
      },
    );
  }
  testWidgets(
    'capture restoration waits for a new return-position snapshot before resuming AB',
    (tester) async {
      final p = ReviewAbPlayback()..delayRestoreSnapshot = true;
      await startOldNoteCapture(tester, p, VideoNoteService());
      await tester.pumpAndSettle();
      expect(p.captures, 1);
      expect(p.seeks, [
        const Duration(seconds: 5),
        const Duration(seconds: 20),
      ]);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(
        p.seeks,
        hasLength(2),
        reason: 'stale capture position 5 must not trigger an A=10 seek',
      );
      p.at(20);
      await tester.pump();
      p.at(30);
      await tester.pumpAndSettle();
      expect(p.seeks.last, const Duration(seconds: 10));
      await unmountAb(tester);
    },
  );
  testWidgets(
    'legacy null-intent audio backend can repeat while backgrounded',
    (tester) async {
      final p = AbPlayback()
        ..current = const PlaybackSnapshot(
          phase: PlaybackPhase.ready,
          isPlaying: true,
          audioOnly: true,
          position: Duration(seconds: 20),
          duration: Duration(minutes: 2),
        );
      await mountAb(tester, p);
      expect(p.current.playRequested, isNull);
      await configureAb(tester, b: '02:00');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      final plays = p.plays;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await unmountAb(tester);
      expect(plays, 1);
    },
  );
  testWidgets(
    'manual seek during capture cancels restore and discards the orphan frame',
    (tester) async {
      final notes = ReviewNoteService();
      final p = ReviewAbPlayback()
        ..captureGate = Completer<void>()
        ..capturedPath = 'synthetic-orphan.png';
      await startOldNoteCapture(tester, p, notes);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(p.captures, 1);
      final slider = tester.widget<Slider>(find.byType(Slider).first);
      slider.onChangeEnd!(0.75);
      await tester.pump();
      p.captureGate!.complete();
      await tester.pumpAndSettle();
      expect(p.seeks, [
        const Duration(seconds: 5),
        const Duration(seconds: 90),
      ]);
      expect(notes.discarded, ['synthetic-orphan.png']);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
      await unmountAb(tester);
    },
  );
}
