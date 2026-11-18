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
      Future<void> chooseMenuItem(String key) async {
        final more = find.byKey(const Key('more-settings-menu'));
        if (more.hitTestable().evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('player-surface')).first);
          // 单击需等双击判断结束，之后才能再次点“更多”。
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
        }
        expect(more.hitTestable(), findsOneWidget);
        await tester.tap(more);
        await tester.pumpAndSettle();
        final item = find.byKey(Key(key));
        // 屏蔽管理在观看工具之后，短窗口要先滚动到它才能点击。
        if (item.hitTestable().evaluate().isEmpty) {
          await tester.drag(find.text('字幕').last, const Offset(0, -350));
          await tester.pumpAndSettle();
        }
        expect(item.hitTestable(), findsOneWidget);
        await tester.tap(item);
        await tester.pumpAndSettle();
      }

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
      await chooseMenuItem('player-block-video');
      expect((await const ContentBlocklistService().load()).videos.keys, [
        cached.bvid,
      ]);
      expect(playback.localOpenCount, 1);
      await chooseMenuItem('player-block-video');
      expect(find.text('已在黑名单中，可在管理页面取消屏蔽。'), findsOneWidget);
      expect(find.text('撤销'), findsNothing);
      await chooseMenuItem('player-block-creator');
      expect((await const ContentBlocklistService().load()).creators.keys, [
        42,
      ]);
      await chooseMenuItem('player-manage-blocklist');
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
