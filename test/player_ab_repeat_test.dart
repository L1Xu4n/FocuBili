import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_ab_repeat_sheet.dart';
import 'package:focubili/features/player/widgets/player_subtitle_sheet.dart';
import 'package:focubili/models/ab_repeat_range.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/listening_playback_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/player_overlay_service.dart';
import 'package:focubili/services/player_route_session.dart';
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;
import 'classroom_access_test.dart' show course;

const abVideo = VideoPreview(
  bvid: 'BV1GJ411x7h7',
  cid: 101,
  title: 'Synthetic listening lesson',
  ownerName: 'Synthetic teacher',
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 101,
      title: 'Words',
      duration: Duration(minutes: 2),
    ),
    VideoPart(
      pageNumber: 2,
      cid: 102,
      title: 'Practice',
      duration: Duration(minutes: 2),
    ),
  ],
);

class AbOverlay implements PlayerOverlayService {
  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async => const SubtitleTrackLoadResult.empty();
  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async => const SubtitleCueLoadResult.unavailable();
  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async => const DanmakuSegmentLoadResult.unavailable();
}

class AbPlayback extends FeedbackPlayback implements ListeningPlaybackService {
  PlaybackSnapshot current = const PlaybackSnapshot(
    phase: PlaybackPhase.ready,
    isPlaying: true,
    playRequested: true,
    position: Duration(seconds: 20),
    duration: Duration(minutes: 2),
    availableQualities: [
      PlaybackQuality(id: 64, label: '720P'),
      PlaybackQuality(id: 80, label: '1080P'),
    ],
  );
  final seeks = <Duration>[];
  final completedSeekCids = <int>[];
  Completer<void>? seekGate;
  Completer<void>? modeGate;
  bool emitOnSeek = true;
  bool failSeek = false;
  int currentCid = 101;
  int plays = 0;
  int pauses = 0;
  int completions = 0;
  @override
  bool get ownsPlatformChannel => true;
  void emit(PlaybackSnapshot snapshot) {
    current = snapshot;
    controller.add(snapshot);
  }

  void at(
    int second, {
    bool playing = true,
    PlaybackPhase phase = PlaybackPhase.ready,
    double speed = 1,
    Duration? duration,
  }) => emit(
    current.copyWith(
      position: Duration(seconds: second),
      isPlaying: playing,
      playRequested: playing ? true : current.playRequested,
      phase: phase,
      speed: speed,
      duration: duration ?? const Duration(minutes: 2),
    ),
  );
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    onlineOpens++;
    currentCid = (part ?? video.initialPart).cid;
    emit(
      current.copyWith(
        phase: PlaybackPhase.ready,
        position: initialPosition ?? const Duration(seconds: 20),
        isPlaying: true,
        currentQuality: quality,
      ),
    );
  }

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    await seekGate?.future;
    if (failSeek) throw StateError('Synthetic seek failure');
    completedSeekCids.add(currentCid);
    if (emitOnSeek) {
      emit(current.copyWith(phase: PlaybackPhase.ready, position: position));
    }
  }

  @override
  Future<void> play() async {
    plays++;
    emit(
      current.copyWith(
        phase: PlaybackPhase.ready,
        isPlaying: true,
        playRequested: true,
      ),
    );
  }

  @override
  Future<void> pause() async {
    pauses++;
    emit(current.copyWith(isPlaying: false, playRequested: false));
  }

  Future<void> _mode({bool? audio, int? quality}) async {
    final before = current;
    emit(
      current.copyWith(
        phase: PlaybackPhase.loading,
        isPlaying: false,
        duration: Duration.zero,
      ),
    );
    await modeGate?.future;
    emit(before.copyWith(audioOnly: audio, currentQuality: quality));
  }

  @override
  Future<void> setAudioOnly(bool enabled) => _mode(audio: enabled);
  @override
  Future<void> selectQuality(int quality) => _mode(quality: quality);
  @override
  Future<void> setSleepTimer(Duration? duration) async {
    emit(current.copyWith(sleepTimerRemaining: duration ?? Duration.zero));
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    emit(current.copyWith(speed: speed));
  }
}

Future<void> mountAb(
  WidgetTester tester,
  AbPlayback playback, {
  VideoPreview video = abVideo,
  FocusTimerController? focus,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: video,
        playbackService: playback,
        focusTimerController: focus,
        initialPosition: const Duration(seconds: 20),
        offlineVideoService: ReviewOfflineLibrary(),
        playerOverlayService: AbOverlay(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> menu(WidgetTester tester, String key, {bool settle = true}) async {
  if (find
      .byKey(const Key('more-settings-menu'))
      .hitTestable()
      .evaluate()
      .isEmpty) {
    await tester.tap(
      find.byKey(const Key('player-surface')).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const Key('more-settings-menu')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> configureAb(
  WidgetTester tester, {
  String a = '00:10',
  String b = '00:30',
}) async {
  await menu(tester, 'ab-repeat-menu-item');
  await tester.enterText(find.byKey(const Key('ab-repeat-A-input')), a);
  await tester.enterText(find.byKey(const Key('ab-repeat-B-input')), b);
  await tester.tap(find.byKey(const Key('ab-repeat-apply')));
  await tester.pumpAndSettle();
}

Future<void> clearAb(WidgetTester tester) async {
  await menu(tester, 'ab-repeat-menu-item');
  await tester.tap(find.byKey(const Key('ab-repeat-clear')));
  await tester.pumpAndSettle();
}

Future<void> unmountAb(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('real player validates fields and marks current A/B points', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await menu(tester, 'ab-repeat-menu-item');
    await tester.tap(find.byKey(const Key('ab-repeat-set-A')));
    p.at(21);
    await tester.pump();
    await tester.tap(find.byKey(const Key('ab-repeat-set-B')));
    await tester.tap(find.byKey(const Key('ab-repeat-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
    expect(find.byKey(const Key('ab-repeat-marker-B')), findsOneWidget);
    await clearAb(tester);
    final beforeInvalid = p.seeks.length;
    await configureAb(tester, a: '00:30', b: '00:30.500');
    expect(find.byKey(const Key('ab-repeat-error')), findsOneWidget);
    expect(p.seeks.length, beforeInvalid);
    await unmountAb(tester);
  });
  testWidgets(
    'repeats at B with speed timing and waits for actual A snapshot',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      await configureAb(tester);
      p.emitOnSeek = false;
      p.at(29, speed: 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(p.seeks, [const Duration(seconds: 10)]);
      await tester.pump(const Duration(seconds: 2));
      p.at(31);
      await tester.pump();
      expect(
        p.seeks,
        hasLength(1),
        reason: 'seek completion without new position cannot issue more seeks',
      );
      p.at(10);
      await tester.pump();
      p.at(30);
      await tester.pump();
      expect(p.seeks, hasLength(2));
      p.at(10);
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(p.seeks, hasLength(3));
      await tester.pump(const Duration(seconds: 20));
      expect(
        p.seeks,
        hasLength(3),
        reason: 'old A snapshot is also not a new seek confirmation',
      );
      await unmountAb(tester);
    },
  );
  testWidgets(
    'pause and loading cancel timer, resume recalculates at actual position',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      await configureAb(tester);
      await tester.tap(find.byKey(const Key('play-pause-button')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 15));
      expect(p.seeks, isEmpty);
      p.at(29, playing: false, phase: PlaybackPhase.loading);
      await tester.pump(const Duration(seconds: 2));
      expect(p.seeks, isEmpty);
      p.at(29);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(p.seeks, [const Duration(seconds: 10)]);
      await unmountAb(tester);
    },
  );
  testWidgets('outside manual timeline seek exits AB and never snaps back', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester);
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    slider.onChangeEnd!(0.75);
    await tester.pumpAndSettle();
    expect(p.seeks.last, const Duration(seconds: 90));
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
    p.at(95);
    await tester.pump(const Duration(seconds: 2));
    expect(p.seeks, hasLength(1));
    await unmountAb(tester);
  });
  testWidgets(
    'course audio-only and quality switches retain range despite zero duration',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p, video: course);
      await configureAb(tester);
      p.modeGate = Completer<void>();
      await menu(tester, 'listening-menu-item', settle: false);
      await tester.pump(const Duration(seconds: 15));
      expect(p.seeks, isEmpty);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
      p.modeGate!.complete();
      await tester.pumpAndSettle();
      expect(p.current.audioOnly, isTrue);
      p.at(30);
      await tester.pump();
      expect(p.seeks.last, const Duration(seconds: 10));
      await menu(tester, 'listening-menu-item');
      expect(p.current.audioOnly, isFalse);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
      p.modeGate = Completer<void>();
      await tester.tap(find.byKey(const Key('quality-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quality-80')));
      await tester.pump(const Duration(milliseconds: 200));
      final seeksBeforeQuality = p.seeks.length;
      await tester.pump(const Duration(seconds: 15));
      expect(p.seeks, hasLength(seeksBeforeQuality));
      p.modeGate!.complete();
      await tester.pumpAndSettle();
      expect(p.current.currentQuality, 80);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
      p.at(31, duration: const Duration(seconds: 25));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
      await unmountAb(tester);
    },
  );
  testWidgets(
    'part navigation drains a late AB seek before media identity changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final p = AbPlayback();
      await mountAb(tester, p);
      await configureAb(tester);
      p.seekGate = Completer<void>();
      p.at(30);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('part-2')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('part-2')).first);
      await tester.pump();
      expect(p.onlineOpens, 1);
      p.seekGate!.complete();
      await tester.pumpAndSettle();
      expect(p.completedSeekCids, [101]);
      expect(p.currentCid, 102);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
      p.at(50);
      await tester.pump();
      expect(p.seeks, hasLength(1));
      await unmountAb(tester);
    },
  );
  testWidgets(
    'B at media end consumes ready(false) then ended without focus or learning completion',
    (tester) async {
      final p = AbPlayback();
      final focus = FocusTimerController();
      await focus.initialize();
      await focus.startFocus(
        goal: 'Repeat words',
        duration: const Duration(minutes: 10),
      );
      final session = focus.activeSession!.id;
      final learning = LearningListService();
      await learning.addVideo(abVideo, part: abVideo.parts.first);
      await mountAb(tester, p, focus: focus);
      await configureAb(tester, b: '02:00');
      p.at(119);
      await tester.pump();
      p.at(120, playing: false);
      await tester.pump();
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(p.seeks.last, const Duration(seconds: 10));
      expect(p.plays, 1);
      expect(focus.activeSession!.id, session);
      expect(focus.history, isEmpty);
      expect(
        (await learning.loadEntries()).single.status.name,
        isNot('completed'),
      );
      await clearAb(tester);
      final seeks = p.seeks.length;
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(
        p.seeks,
        hasLength(seeks),
        reason: 'normal end no longer repeats after clearing',
      );
      await unmountAb(tester);
      focus.dispose();
    },
  );
  for (final originalLoop in [false, true]) {
    testWidgets('clearing AB restores original whole-part loop=$originalLoop', (
      tester,
    ) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      if (originalLoop) await menu(tester, 'playback-loop-menu-item');
      await configureAb(tester);
      await clearAb(tester);
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(p.seeks.length, originalLoop ? 1 : 0);
      if (originalLoop) expect(p.seeks.single, Duration.zero);
      await unmountAb(tester);
    });
  }
  testWidgets('clear and pause during late ended seek cannot resume media', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester, b: '02:00');
    p.seekGate = Completer<void>();
    p.at(120, playing: false, phase: PlaybackPhase.ended);
    await tester.pump();
    expect(p.seeks, hasLength(1));
    await clearAb(tester);
    p.seekGate!.complete();
    await tester.pumpAndSettle();
    expect(p.plays, 0);
    expect(p.current.isPlaying, isFalse);
    await unmountAb(tester);
  });
  testWidgets(
    'external route drains late seek and returns to ordinary paused playback',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      await configureAb(tester);
      p.seekGate = Completer<void>();
      p.at(30);
      await tester.pump();
      final suspension = PlayerRouteSession.suspendCurrent();
      await tester.pump();
      p.seekGate!.complete();
      await suspension;
      await tester.pump();
      expect(p.current.isPlaying, isFalse);
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
      await unmountAb(tester);
    },
  );
  testWidgets('seek failure exits loop', (tester) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester);
    p.failSeek = true;
    p.at(30);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
    expect(p.seeks, hasLength(1));
    await unmountAb(tester);
  });
  testWidgets('manual subtitle seek inside retains AB, outside exits', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester);
    await tester.tap(find.byKey(const Key('more-settings-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('字幕').last);
    await tester.pumpAndSettle();
    final sheet = tester.widget<PlayerSubtitleSheet>(
      find.byType(PlayerSubtitleSheet),
    );
    await sheet.onSeek!(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
    await sheet.onSeek!(const Duration(seconds: 90));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
    expect(p.seeks, [const Duration(seconds: 15), const Duration(seconds: 90)]);
    await unmountAb(tester);
  });
  testWidgets('stale AB sheet callbacks cannot alter a newer range', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester);
    await menu(tester, 'ab-repeat-menu-item');
    final sheetFinder = find.byType(PlayerAbRepeatSheet);
    final sheet = tester.widget<PlayerAbRepeatSheet>(sheetFinder);
    Navigator.of(tester.element(sheetFinder)).pop();
    await tester.pumpAndSettle();
    await clearAb(tester);
    await configureAb(tester, a: '00:05', b: '00:40');
    sheet.onClear();
    sheet.onApply(
      const AbRepeatRange(
        bvid: 'BV1GJ411x7h7',
        cid: 101,
        a: Duration.zero,
        b: Duration(seconds: 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
    await menu(tester, 'ab-repeat-menu-item');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('ab-repeat-A-input')))
          .controller!
          .text,
      '00:05',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('ab-repeat-B-input')))
          .controller!
          .text,
      '00:40',
    );
    await unmountAb(tester);
  });
  testWidgets('explicit pause during delayed ended seek never plays', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester, b: '02:00');
    p.seekGate = Completer<void>();
    p.at(120, playing: false, phase: PlaybackPhase.ended);
    await tester.pump();
    p.at(10);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('play-pause-button')));
    await tester.pump();
    p.seekGate!.complete();
    await tester.pumpAndSettle();
    expect(p.plays, 0);
    expect(p.current.isPlaying, isFalse);
    expect(find.byKey(const Key('ab-repeat-marker-A')), findsOneWidget);
    await unmountAb(tester);
  });
  testWidgets('backend sleep expiry during delayed ended seek never plays', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester, b: '02:00');
    await p.setSleepTimer(const Duration(seconds: 1));
    await tester.pump();
    p.seekGate = Completer<void>();
    p.at(120, playing: false, phase: PlaybackPhase.ended);
    await tester.pump();
    p.emit(
      p.current.copyWith(isPlaying: false, sleepTimerRemaining: Duration.zero),
    );
    await tester.pump();
    p.seekGate!.complete();
    await tester.pumpAndSettle();
    expect(p.plays, 0);
    expect(p.current.isPlaying, isFalse);
    await unmountAb(tester);
  });
  testWidgets('ended arriving during timer seek resumes exactly once', (
    tester,
  ) async {
    final p = AbPlayback();
    await mountAb(tester, p);
    await configureAb(tester, b: '02:00');
    p.seekGate = Completer<void>();
    p.at(119);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(p.seeks, hasLength(1));
    p.at(120, playing: false, phase: PlaybackPhase.ended);
    await tester.pump();
    p.seekGate!.complete();
    await tester.pumpAndSettle();
    expect(p.seeks, hasLength(1));
    expect(p.plays, 1);
    expect(p.current.isPlaying, isTrue);
    await unmountAb(tester);
  });
  testWidgets(
    'AB does not consume the original full-play count and explicit loop edits win',
    (tester) async {
      final p = AbPlayback();
      await mountAb(tester, p);
      await menu(tester, 'sleep-timer-menu-item');
      await tester.tap(find.byKey(const Key('sleep-timer-2-plays')));
      await tester.pumpAndSettle();
      await configureAb(tester, b: '02:00');
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(p.seeks, [const Duration(seconds: 10)]);
      await clearAb(tester);
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(p.seeks, [const Duration(seconds: 10), Duration.zero]);
      final pauses = p.pauses;
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(p.pauses, pauses + 1);
      expect(p.seeks, hasLength(2));
      await configureAb(tester);
      await menu(tester, 'playback-loop-menu-item');
      expect(find.byKey(const Key('ab-repeat-marker-A')), findsNothing);
      p.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(
        p.seeks.last,
        Duration.zero,
        reason:
            'explicit enable whole-part loop after AB applies the new choice',
      );
      await unmountAb(tester);
    },
  );
  testWidgets('leaving player waits for delayed AB seek before popping route', (
    tester,
  ) async {
    final p = AbPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => PlayerPage(
                    video: abVideo,
                    playbackService: p,
                    playerOverlayService: AbOverlay(),
                    offlineVideoService: ReviewOfflineLibrary(),
                    initialPosition: const Duration(seconds: 20),
                  ),
                ),
              ),
              child: const Text('Open synthetic player'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open synthetic player'));
    await tester.pumpAndSettle();
    await configureAb(tester);
    p.seekGate = Completer<void>();
    p.at(30);
    await tester.pump();
    await tester.tap(find.byTooltip('返回').first);
    await tester.pump();
    expect(find.byType(PlayerPage), findsOneWidget);
    p.seekGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    expect(p.plays, 0);
    expect(p.completedSeekCids, [101]);
    await unmountAb(tester);
  });
}
