import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'review_pr24_regression_test.dart'
    show ReviewLocalPlayback, ReviewOfflineLibrary;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'player menu blocks video and creator and opens cancellation list',
    (tester) async {
      final playback = ReviewLocalPlayback();
      final cached = ReviewOfflineLibrary.record.toPreview();
      final video = VideoPreview(
        bvid: cached.bvid,
        cid: cached.cid,
        title: cached.title,
        ownerName: cached.ownerName,
        ownerMid: 42,
        parts: cached.parts,
        duration: cached.duration,
        fromOfflineCache: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            video: video,
            playbackService: playback,
            forceOffline: true,
            offlineVideoService: ReviewOfflineLibrary(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('more-settings-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-block-video')));
      await tester.pumpAndSettle();
      expect((await const ContentBlocklistService().load()).videos.keys, [
        cached.bvid,
      ]);
      expect(playback.localOpenCount, 1);
      await tester.tap(find.byKey(const Key('more-settings-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-block-video')));
      await tester.pumpAndSettle();
      expect(find.text('已在黑名单中，可在管理页面取消屏蔽。'), findsOneWidget);
      expect(find.text('撤销'), findsNothing);
      await tester.tap(find.byKey(const Key('more-settings-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-block-creator')));
      await tester.pumpAndSettle();
      expect((await const ContentBlocklistService().load()).creators.keys, [
        42,
      ]);
      await tester.tap(find.byKey(const Key('more-settings-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-manage-blocklist')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('unblock-video-${cached.bvid}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unblock-creator-42')));
      await tester.pumpAndSettle();
      final restored = await const ContentBlocklistService().load();
      expect(restored.videos, isEmpty);
      expect(restored.creators, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
