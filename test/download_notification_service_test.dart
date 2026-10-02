import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/download_notification_service.dart';

/// Captures the real plugin contract without showing notifications on the host desktop.
class RecordingDownloadNotifications extends Fake
    implements FlutterLocalNotificationsWindows {
  final shown = <WindowsNotificationDetails>[];
  final bodies = <String?>[];
  final updated = <Map<String, String>>[];
  NotificationUpdateResult result = NotificationUpdateResult.success;

  /// Records the XML-bound template used when starting or explicitly resuming a task.
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    String? payload,
    WindowsNotificationDetails? notificationDetails,
  }) async {
    shown.add(notificationDetails!);
    bodies.add(body);
  }

  /// Records every dynamic field, including status text the progress-only API omits.
  @override
  Future<NotificationUpdateResult> updateBindings({
    required int id,
    required Map<String, String> bindings,
  }) async {
    updated.add(Map.of(bindings));
    return result;
  }
}

/// Creates immutable progress snapshots using only synthetic video metadata.
OfflineDownloadTask task(
  DownloadTaskStatus status, {
  int received = 30,
  int cid = 1,
}) {
  final part = VideoPart(
    pageNumber: cid,
    cid: cid,
    title: 'Part $cid',
    duration: const Duration(seconds: 20),
  );
  return OfflineDownloadTask(
    video: VideoPreview(
      bvid: 'BV1GJ411x7h7',
      cid: cid,
      title: 'Video $cid',
      ownerName: 'Review',
      parts: [part],
    ),
    part: part,
    quality: 32,
    createdAt: DateTime(2026),
    status: status,
    receivedBytes: received,
    totalBytes: 100,
  );
}

/// Verifies actual Windows bindings and Android active/stopped notification requests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecordingDownloadNotifications plugin;
  late DownloadNotificationService service;

  /// Gives each test a fresh native-notification identity and in-memory recorder.
  setUp(() {
    plugin = RecordingDownloadNotifications();
    service = DownloadNotificationService(
      platform: AppPlatform.windows,
      windowsPlugin: plugin,
      windowsAvailable: () async => true,
    );
  });

  test(
    'finished current task is not mislabeled paused because a different task is paused',
    () async {
      await service.publish([
        task(DownloadTaskStatus.downloading),
        task(DownloadTaskStatus.paused, cid: 2),
      ]);
      await service.publish([
        task(DownloadTaskStatus.completed, received: 100),
        task(DownloadTaskStatus.paused, cid: 2),
      ]);
      expect(plugin.updated.last['downloadStatus'], '下载完成 · 另有 1 项已暂停');
      expect(plugin.updated.last['download-progressString'], '100%');
    },
  );

  test(
    'Windows progress template binds status and title as well as the percentage',
    () async {
      await service.publish([task(DownloadTaskStatus.downloading)]);
      expect(
        plugin.shown.single.progressBars.single.status,
        '{downloadStatus}',
      );
      expect(plugin.bodies.single, '{downloadTitle}');
      expect(plugin.shown.single.bindings['downloadStatus'], contains('正在下载'));
      await service.publish([
        task(DownloadTaskStatus.downloading, received: 60),
      ]);
      expect(plugin.updated.single['download-progressValue'], '0.6');
      expect(plugin.updated.single['download-progressString'], '60%');
      expect(plugin.updated.single['downloadStatus'], contains('正在下载'));
    },
  );

  test(
    'Windows paused and failed tasks retain their byte progress rather than becoming 100 percent',
    () async {
      await service.publish([task(DownloadTaskStatus.downloading)]);
      await service.publish([task(DownloadTaskStatus.paused)]);
      expect(plugin.updated.last['download-progressValue'], '0.3');
      expect(plugin.updated.last['download-progressString'], '30%');
      expect(plugin.updated.last['downloadStatus'], '已暂停 1 项');
      await service.publish([task(DownloadTaskStatus.downloading)]);
      await service.publish([task(DownloadTaskStatus.failed, received: 40)]);
      expect(plugin.updated.last['download-progressValue'], '0.4');
      expect(plugin.updated.last['downloadStatus'], contains('下载失败'));
    },
  );

  test(
    'only a completed task is shown as complete and removal does not claim completion',
    () async {
      await service.publish([task(DownloadTaskStatus.downloading)]);
      await service.publish([
        task(DownloadTaskStatus.completed, received: 100),
      ]);
      expect(plugin.updated.last['download-progressString'], '100%');
      expect(plugin.updated.last['downloadStatus'], '下载完成');
      await service.publish([task(DownloadTaskStatus.downloading, cid: 2)]);
      await service.publish([]);
      expect(plugin.updated.last['downloadStatus'], '任务已移除');
      expect(plugin.updated.last['download-progressString'], isNot('100%'));
    },
  );

  test(
    'dismissed Windows notification is not recreated until explicit resume or another task',
    () async {
      await service.publish([task(DownloadTaskStatus.downloading)]);
      plugin.result = NotificationUpdateResult.notFound;
      await service.publish([
        task(DownloadTaskStatus.downloading, received: 40),
      ]);
      await service.publish([
        task(DownloadTaskStatus.downloading, received: 60),
      ]);
      expect(plugin.shown, hasLength(1));
      expect(plugin.updated, hasLength(1));
      await service.publish([task(DownloadTaskStatus.paused, received: 60)]);
      plugin.result = NotificationUpdateResult.success;
      await service.publish([
        task(DownloadTaskStatus.downloading, received: 60),
      ]);
      expect(plugin.shown, hasLength(2));
      expect(plugin.shown.last.progressBars.single.value, 0.6);
    },
  );

  test(
    'Windows platform errors are surfaced without inventing a successful update',
    () async {
      await service.publish([task(DownloadTaskStatus.downloading)]);
      plugin.result = NotificationUpdateResult.error;
      await expectLater(
        service.publish([task(DownloadTaskStatus.downloading, received: 40)]),
        throwsStateError,
      );
    },
  );

  test(
    'Android pauses stop foreground notification instead of sending a completed percentage',
    () async {
      const channel = MethodChannel('test/download-progress');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final android = DownloadNotificationService(
        channel: channel,
        platform: AppPlatform.android,
      );
      await android.publish([task(DownloadTaskStatus.downloading)]);
      expect((calls.last.arguments as Map)['progress'], 30);
      expect((calls.last.arguments as Map)['active'], isTrue);
      await android.publish([task(DownloadTaskStatus.paused)]);
      expect((calls.last.arguments as Map)['active'], isFalse);
      expect((calls.last.arguments as Map)['progress'], -1);
    },
  );
}
