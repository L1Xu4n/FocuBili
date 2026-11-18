import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/playback_queue.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/focus_preferences_service.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/watch_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_ab_repeat_test.dart'
    show AbPlayback, AbOverlay, abVideo, unmountAb;
import 'player_playlist_test.dart' show nextVideo;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

class _LearningPlayback extends AbPlayback {
  @override
  Future<String?> captureCurrentFrame() async => null;
}

class _Lessons extends BilibiliVideoInfoService {
  final lookups = <String>[];

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookups.add(input);
    return switch (input) {
      'BV1GJ411x7h7' => abVideo,
      'BV1xx411c7mD' => nextVideo,
      _ => throw StateError('unrecognized test video: $input'),
    };
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget host({
    required VideoPreview video,
    required AbPlayback playback,
    required LearningListService learning,
    required _Lessons details,
    FocusTimerController? focus,
    List<LearningListEntry>? queue,
    Set<String>? learningScope,
  }) => MaterialApp(
    home: PlayerPage(
      video: video,
      playbackService: playback,
      learningListService: learning,
      bilibiliService: details,
      offlineVideoService: ReviewOfflineLibrary(),
      playerOverlayService: AbOverlay(),
      focusTimerController: focus,
      learningContinuationScope: learningScope,
      playbackQueue: queue == null
          ? null
          : PlaybackQueue(
              title: '学习清单',
              items: [
                for (final item in queue)
                  PlaybackQueueItem(
                    bvid: item.bvid,
                    title: item.title,
                    learningEntry: item,
                  ),
              ],
            ),
    ),
  );

  testWidgets('collection card opens the shared P and folder picker', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final learning = LearningListService();
    final folder = (await learning.createFolder('数学')).folders.single;
    final details = _Lessons();
    final playback = _LearningPlayback();
    await WatchHistoryService().record(
      WatchHistoryEntry(
        bvid: nextVideo.bvid,
        title: nextVideo.title,
        ownerName: nextVideo.ownerName,
        lastPartTitle: nextVideo.parts[1].title,
        lastPartPageNumber: 2,
        watchedAt: DateTime(2026, 11, 18),
        lastPosition: const Duration(seconds: 34),
      ),
    );
    final video = VideoPreview(
      bvid: abVideo.bvid,
      cid: abVideo.cid,
      title: abVideo.title,
      ownerName: abVideo.ownerName,
      parts: abVideo.parts,
      collection: VideoCollection(
        id: 1,
        title: '练习合集',
        entries: [
          VideoCollectionEntry(
            bvid: nextVideo.bvid,
            cid: nextVideo.cid,
            title: nextVideo.title,
            thumbnailUrl: '',
            duration: nextVideo.duration,
          ),
        ],
        totalCount: 1,
      ),
    );
    await tester.pumpWidget(
      host(
        video: video,
        playback: playback,
        learning: learning,
        details: details,
      ),
    );
    await tester.pumpAndSettle();
    final add = find.byKey(
      Key('add-learning-player-collection-${nextVideo.bvid}'),
    );
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    Future<void> settlePicker() async {
      // The button in the underlying route keeps animating until the form is
      // closed. Pump the bounded transitions instead of waiting on that ticker.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    await tester.tap(add);
    await settlePicker();
    expect(find.text('全部 P'), findsOneWidget);
    expect(find.text('上次观看的 P'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'P2 Two'),
          )
          .value,
      isTrue,
    );
    expect(await learning.loadEntries(), isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await learning.loadEntries(), isEmpty);

    await tester.tap(add);
    await settlePicker();
    await tester.tap(find.text('全部 P'));
    await tester.tap(find.byKey(const Key('add-learning-folder')));
    await settlePicker();
    await tester.tap(find.text('数学').last);
    await settlePicker();
    await tester.tap(find.text('确认加入'));
    await tester.pumpAndSettle();
    final saved = await learning.loadEntries();
    expect(saved.map((entry) => entry.partCid), [201, 202]);
    expect(saved.last.position, const Duration(seconds: 34));
    expect(saved.every((entry) => entry.folderId == folder.id), isTrue);
    expect(playback.currentCid, 101);
    expect(details.lookups, [nextVideo.bvid, nextVideo.bvid]);
    expect(tester.takeException(), isNull);
    await unmountAb(tester);
  });

  testWidgets('focus session survives actual player P and video switches', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await FocusPreferencesService().markPlayerDoNotDisturbGuideSeen();
    var now = DateTime(2026, 11, 18, 9);
    final focus = FocusTimerController(
      clock: () => now,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focus.dispose);
    await focus.initialize();
    final learning = LearningListService();
    final result = await learning.addBatch([
      for (final part in abVideo.parts) LearningPartSelection(abVideo, part),
      LearningPartSelection(nextVideo, nextVideo.parts[1]),
    ]);
    final playback = _LearningPlayback();
    await tester.pumpWidget(
      host(
        video: abVideo,
        playback: playback,
        learning: learning,
        details: _Lessons(),
        focus: focus,
        queue: result.entries,
      ),
    );
    await tester.pumpAndSettle();
    final focusButton = find.byKey(const Key('player-focus-button'));
    Future<void> openFocus() async {
      if (focusButton.hitTestable().evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('player-surface')).first);
        await tester.pumpAndSettle();
      }
      await tester.tap(focusButton);
      await tester.pumpAndSettle();
    }

    await openFocus();
    await tester.tap(find.byKey(const Key('start-player-focus')));
    await tester.pumpAndSettle();
    final id = focus.activeSession!.id;
    expect(focus.activeSession!.sourcePartCid, 101);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    now = now.add(const Duration(minutes: 2));
    await playback.pause();
    await tester.pumpAndSettle();
    expect(focus.activeSession!.id, id);
    expect(focus.elapsedDuration, const Duration(minutes: 2));
    await playback.play();
    playback.at(120, phase: PlaybackPhase.ended, playing: false);
    await tester.pumpAndSettle();
    expect(playback.currentCid, 102);
    expect(focus.activeSession!.sourcePartCid, 102);
    now = now.add(const Duration(minutes: 3));
    playback.at(120, phase: PlaybackPhase.ended, playing: false);
    await tester.pumpAndSettle();
    expect(playback.currentCid, 202);
    expect(focus.activeSession!.id, id);
    expect(focus.activeSession!.sourceBvid, nextVideo.bvid);
    expect(focus.elapsedDuration, const Duration(minutes: 5));
    expect(focus.history, isEmpty);

    await openFocus();
    expect(find.byKey(const Key('player-focus-active')), findsOneWidget);
    await tester.tap(find.byKey(const Key('end-player-focus')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认终止'));
    await tester.pumpAndSettle();
    expect(focus.activeSession, isNull);
    expect(focus.history.single.id, id);
    expect(focus.history.single.status, FocusSessionStatus.endedEarly);
    expect(
      focus.history.single.accumulatedFocusDuration,
      const Duration(minutes: 5),
    );
    expect(tester.takeException(), isNull);
    await unmountAb(tester);
  });

  testWidgets('completion cannot jump to a different folder', (tester) async {
    SharedPreferences.setMockInitialValues({
      'playback_preferences.mode': 'pause',
    });
    await tester.binding.setSurfaceSize(const Size(430, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final learning = LearningListService();
    final math = (await learning.createFolder('数学')).folders.single;
    final english = (await learning.createFolder('英语')).folders.last;
    final a = (await learning.addBatch([
      LearningPartSelection(abVideo, abVideo.initialPart),
    ], folderId: math.id)).entries.single;
    await learning.addBatch([
      LearningPartSelection(nextVideo, nextVideo.initialPart),
    ], folderId: english.id);
    final details = _Lessons();
    final playback = _LearningPlayback();
    await tester.pumpWidget(
      host(
        video: abVideo,
        playback: playback,
        learning: learning,
        details: details,
        queue: [a],
        learningScope: {a.stableId},
      ),
    );
    await tester.pumpAndSettle();
    playback.at(120, phase: PlaybackPhase.ended, playing: false);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('continue-learning-after-completion')),
    );
    await tester.pumpAndSettle();
    expect(playback.currentCid, 101);
    expect(details.lookups, isEmpty);
    expect(find.text('当前学习范围没有后续未完成的任务。'), findsOneWidget);
    final restored = await learning.loadEntries();
    expect(
      restored.singleWhere((e) => e.folderId == math.id).status,
      LearningListStatus.completed,
    );
    expect(
      restored.singleWhere((e) => e.folderId == english.id).status,
      LearningListStatus.notStarted,
    );
    expect(tester.takeException(), isNull);
    await unmountAb(tester);
  });
}
