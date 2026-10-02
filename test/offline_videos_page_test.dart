import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/offline_videos_page.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'offline_download_queue_test.dart' show QueueLibrary, fixture;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

/// Checks cache search, queue navigation and control states using real widgets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 验证矮窗口给列表保留空间，宽窗口将队列卡片按两列排列。
  for (final size in [const Size(800, 280), const Size(1280, 720)]) {
    testWidgets('队列在 ${size.width} × ${size.height} 保留搜索和操作空间', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final library = QueueLibrary();
      final tasks = [2, 3].map((number) {
        final video = fixture(number);
        return OfflineDownloadTask(
          video: video,
          part: video.initialPart,
          quality: 32,
          createdAt: DateTime(2026),
          status: DownloadTaskStatus.paused,
          receivedBytes: 10,
          totalBytes: 100,
        );
      }).toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode(tasks.map((task) => task.toJson()).toList()),
      );
      final queue = OfflineDownloadQueue(library: library);
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineVideosPage(
            offlineVideoService: library,
            downloadQueue: queue,
            initialQueue: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(Key('download-task-${tasks.first.id}'));
      expect(first, findsOneWidget);
      final toolbar = find.byKey(const Key('offline-toolbar-scroll'));
      expect(tester.getSize(toolbar).height, lessThan(size.height / 2));
      if (size.width > 840) {
        final second = find.byKey(Key('download-task-${tasks.last.id}'));
        expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
        expect(
          tester.getTopLeft(second).dx,
          greaterThan(tester.getTopLeft(first).dx),
        );
        expect(find.byTooltip('继续下载'), findsNWidgets(2));
        expect(find.byTooltip('删除任务'), findsNWidgets(2));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await queue.close();
    });
  }

  testWidgets(
    'offline page searches cached videos and queued tasks independently',
    (tester) async {
      final library = QueueLibrary();
      library.ready.add(ReviewOfflineLibrary.record);
      final video = fixture(2);
      final task = OfflineDownloadTask(
        video: video,
        part: video.initialPart,
        quality: 32,
        createdAt: DateTime(2026),
        status: DownloadTaskStatus.paused,
        receivedBytes: 10,
        totalBytes: 100,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        OfflineDownloadQueue.storageKey,
        jsonEncode([task.toJson()]),
      );
      final queue = OfflineDownloadQueue(library: library);
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineVideosPage(
            offlineVideoService: library,
            downloadQueue: queue,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Review'), findsWidgets);
      await tester.enterText(
        find.byKey(const Key('offline-search')),
        'missing',
      );
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的离线视频'), findsOneWidget);
      await tester.tap(find.text('下载队列'));
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的下载任务'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('offline-search')), '学习视频');
      await tester.pumpAndSettle();
      expect(find.text('学习视频 2'), findsOneWidget);
      expect(find.byTooltip('继续下载'), findsOneWidget);
      expect(find.byTooltip('删除任务'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await queue.close();
    },
  );

  testWidgets('queue shortcut initially selects the queue tab', (tester) async {
    final library = QueueLibrary();
    final queue = OfflineDownloadQueue(library: library);
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineVideosPage(
          offlineVideoService: library,
          downloadQueue: queue,
          initialQueue: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无下载任务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await queue.close();
  });
}
