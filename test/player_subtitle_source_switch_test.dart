import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cached_player_overlay_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';

import 'player_ab_repeat_test.dart' show AbOverlay;
import 'review_pr24_regression_test.dart'
    show ReviewLocalPlayback, ReviewOfflineLibrary;

class _SwitchablePlayback extends ReviewLocalPlayback {
  int onlineOpenCount = 0;

  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
    PlaybackCodecPreference? codecPreference,
    bool preferDataSaving = false,
  }) async {
    onlineOpenCount++;
    controller.add(
      const PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        isPlaying: true,
        duration: Duration(minutes: 2),
      ),
    );
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {}
}

class _SourceSwitchOverlay extends AbOverlay {
  _SourceSwitchOverlay({this.firstTracks, this.firstCues, this.manualCues});

  final Future<SubtitleTrackLoadResult>? firstTracks;
  final Future<SubtitleCueLoadResult>? firstCues;
  final Future<SubtitleCueLoadResult>? manualCues;
  int trackLoads = 0;
  final cueTrackIds = <String>[];

  static const tracks = SubtitleTrackLoadResult(
    status: SubtitleLoadStatus.available,
    message: '',
    tracks: [
      SubtitleTrack(
        id: 'zh',
        language: 'zh',
        label: '中文',
        isLocked: false,
        documentId: 'same-chinese-document',
      ),
      SubtitleTrack(
        id: 'en',
        language: 'en',
        label: 'English',
        isLocked: false,
        documentId: 'english-document',
      ),
    ],
  );

  static SubtitleCueLoadResult cues(String content) => SubtitleCueLoadResult(
    status: SubtitleLoadStatus.available,
    message: '',
    cues: [
      SubtitleCue(
        from: Duration.zero,
        to: const Duration(minutes: 1),
        content: content,
      ),
    ],
  );

  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async {
    if (++trackLoads == 1 && firstTracks != null) return firstTracks!;
    return tracks;
  }

  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async {
    cueTrackIds.add(trackId);
    if (trackId == 'en' && manualCues != null) return manualCues!;
    if (cueTrackIds.length == 1 && firstCues != null) return firstCues!;
    return cues('caption $trackId');
  }
}

Future<_SwitchablePlayback> _openPlayer(
  WidgetTester tester,
  _SourceSwitchOverlay overlay,
) async {
  final playback = _SwitchablePlayback();
  final memory = SubtitleMemoryCache();
  final cache = CachedPlayerOverlayService(overlay, cache: memory);
  addTearDown(() {
    cache.dispose();
    memory.dispose();
  });
  final record = ReviewOfflineLibrary.record;
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: VideoPreview(
          bvid: record.bvid,
          cid: record.cid,
          title: 'Source switching',
          ownerName: 'Example',
          parts: record.toPreview().parts,
        ),
        playbackService: playback,
        offlineVideoService: ReviewOfflineLibrary(),
        playerOverlayService: cache,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return playback;
}

Future<void> _switchSource(WidgetTester tester, int quality) async {
  final menu = tester.widget<PopupMenuButton<int>>(
    find.byKey(const Key('quality-menu')),
  );
  menu.onSelected!(quality);
  await tester.pumpAndSettle();
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      PlaybackPreferencesService.autoEnableSubtitlesKey: true,
    }),
  );

  testWidgets('switching to local cancels automatic track discovery', (
    tester,
  ) async {
    final tracks = Completer<SubtitleTrackLoadResult>();
    final overlay = _SourceSwitchOverlay(firstTracks: tracks.future);
    final playback = await _openPlayer(tester, overlay);
    expect(overlay.trackLoads, 1);
    await _switchSource(tester, -1);
    expect(playback.localOpened, isTrue);
    tracks.complete(_SourceSwitchOverlay.tracks);
    await tester.pumpAndSettle();
    expect(overlay.cueTrackIds, isEmpty);
    expect(find.byKey(const Key('active-subtitle')), findsNothing);
    await _switchSource(tester, 64);
    expect(playback.onlineOpenCount, 2);
    expect(overlay.trackLoads, 2);
    expect(find.text('caption zh'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'returning online starts a fresh track request before the old response',
    (tester) async {
      final previous = Completer<SubtitleTrackLoadResult>();
      final overlay = _SourceSwitchOverlay(firstTracks: previous.future);
      await _openPlayer(tester, overlay);
      await _switchSource(tester, -1);
      await _switchSource(tester, 64);
      expect(overlay.trackLoads, 2);
      expect(overlay.cueTrackIds, ['zh']);
      expect(find.text('caption zh'), findsOneWidget);
      previous.complete(const SubtitleTrackLoadResult.empty());
      await tester.pumpAndSettle();
      expect(overlay.cueTrackIds, ['zh']);
      expect(find.text('caption zh'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a same-CID source round trip cannot reuse an old automatic cue request',
    (tester) async {
      final previous = Completer<SubtitleCueLoadResult>();
      final overlay = _SourceSwitchOverlay(firstCues: previous.future);
      await _openPlayer(tester, overlay);
      expect(overlay.cueTrackIds, ['zh']);
      await _switchSource(tester, -1);
      expect(find.byKey(const Key('active-subtitle')), findsNothing);
      await _switchSource(tester, 64);
      expect(overlay.trackLoads, 2);
      expect(overlay.cueTrackIds, ['zh', 'zh']);
      expect(find.text('caption zh'), findsOneWidget);
      previous.complete(_SourceSwitchOverlay.cues('stale automatic cue'));
      await tester.pumpAndSettle();
      expect(find.text('caption zh'), findsOneWidget);
      expect(find.text('stale automatic cue'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final selection in ['keep', 'English', '关闭字幕']) {
    testWidgets('source switching preserves subtitle choice $selection', (
      tester,
    ) async {
      final manual = Completer<SubtitleCueLoadResult>();
      final overlay = _SourceSwitchOverlay(manualCues: manual.future);
      await _openPlayer(tester, overlay);
      expect(find.text('caption zh'), findsOneWidget);
      if (selection != 'keep') {
        final more = find.byKey(const Key('more-settings-menu'));
        if (more.hitTestable().evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('player-surface')).first);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
        }
        await tester.tap(more);
        await tester.pumpAndSettle();
        final subtitle = find.byKey(const Key('player-subtitle-menu-item'));
        await tester.ensureVisible(subtitle);
        await tester.tap(subtitle);
        await tester.pumpAndSettle();
        await tester.tap(find.text(selection));
        await tester.pumpAndSettle();
      }
      await _switchSource(tester, -1);
      manual.complete(_SourceSwitchOverlay.cues('manual caption en'));
      await tester.pumpAndSettle();
      await _switchSource(tester, 64);
      expect(overlay.trackLoads, 1);
      expect(
        find.text('caption zh'),
        selection == 'keep' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('manual caption en'),
        selection == 'English' ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
