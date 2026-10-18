import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_subtitle_sheet.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/player_overlay_service.dart';
import 'classroom_access_test.dart' show course;
import 'classroom_page_test.dart' show ChapterPlayback;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

class _UnexpectedUgcOverlay implements PlayerOverlayService {
  int requests = 0;

  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async {
    requests++;
    return const SubtitleTrackLoadResult.empty();
  }

  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async {
    requests++;
    return const SubtitleCueLoadResult.unavailable();
  }

  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    requests++;
    return const DanmakuSegmentLoadResult.unavailable();
  }
}

void main() {
  testWidgets('course menu and subtitle browser retain course boundaries', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final overlay = _UnexpectedUgcOverlay();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: course,
          playbackService: ChapterPlayback(),
          playerOverlayService: overlay,
          offlineVideoService: ReviewOfflineLibrary(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('more-settings-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-block-video')), findsNothing);
    expect(find.byKey(const Key('player-manage-blocklist')), findsOneWidget);
    await tester.tap(find.text('字幕').last);
    await tester.pumpAndSettle();
    final sheet = tester.widget<PlayerSubtitleSheet>(
      find.byType(PlayerSubtitleSheet),
    );
    final result = await sheet.loadCues!(
      const SubtitleTrack(
        id: 'unexpected-track',
        language: 'zh',
        label: '合成字幕',
        isLocked: false,
      ),
    );
    expect(result.status, SubtitleLoadStatus.unavailable);
    expect(overlay.requests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
