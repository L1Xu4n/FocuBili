import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/offline_download_task.dart';
import '../platform/app_platform.dart';
import 'focus_notification_service.dart';
import 'windows_focus_notification_service.dart';
import 'linux_focus_notification_service.dart';

/// Publishes one quiet, continuously updated OS notification for the queue.
class DownloadNotificationService {
  /// Keeps the platform bridge injectable without requiring native code in tests.
  DownloadNotificationService({
    MethodChannel? channel,
    AppPlatform? platform,
    FlutterLocalNotificationsWindows? windowsPlugin,
    Future<bool> Function()? windowsAvailable,
  }) : _channel = channel ?? const MethodChannel('com.focubili.app/downloads'),
       _platform = platform,
       _windowsPlugin = windowsPlugin,
       _windowsAvailable = windowsAvailable {
    if (channel != null || !AppPlatformDetector.isFlutterTest) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'pauseAll') await onPauseRequested?.call();
      });
    }
  }

  static final instance = DownloadNotificationService();
  static const _notificationId = 15119;
  final MethodChannel _channel;
  final AppPlatform? _platform;
  final FlutterLocalNotificationsWindows? _windowsPlugin;
  final Future<bool> Function()? _windowsAvailable;
  String? _windowsTask;
  final LinuxNotificationClient _linuxNotifications = LinuxNotificationClient(
    persistReminders: false,
  );
  Future<bool>? _linuxReady;
  String? _linuxLastStatus;
  String? _dismissedWindowsTask;
  Future<void> Function()? onPauseRequested;

  /// Requests notification permission only after a user initiates downloading.
  Future<bool> requestPermission() =>
      const FocusNotificationService().requestPermission();

  /// Uses Android foreground progress and Windows data-binding updates.
  Future<void> publish(List<OfflineDownloadTask> tasks) async {
    if (_platform == null && AppPlatformDetector.isFlutterTest) return;
    final platform = _platform ?? AppPlatformDetector.current;
    final active = tasks.where(
      (e) => e.status == DownloadTaskStatus.downloading,
    );
    final queued = tasks.where((e) => e.status == DownloadTaskStatus.queued);
    final running = active.isNotEmpty ? active.first : queued.firstOrNull;
    final previous = tasks.where((item) => item.id == _windowsTask).firstOrNull;
    final task = running ?? previous;
    final waiting = queued.length;
    final paused = tasks
        .where((e) => e.status == DownloadTaskStatus.paused)
        .length;
    final status = running != null
        ? active.isEmpty
              ? '等待下载 · 共 $waiting 项'
              : '正在下载 · ${running.speedLabel} · 等待 $waiting 项'
        : task?.status == DownloadTaskStatus.failed
        ? '下载失败，可在队列重试'
        : task?.status == DownloadTaskStatus.completed
        ? paused > 0
              ? '下载完成 · 另有 $paused 项已暂停'
              : '下载完成'
        : task?.status == DownloadTaskStatus.paused || paused > 0
        ? '已暂停 $paused 项'
        : '任务已移除';
    if (platform == AppPlatform.android) {
      await _channel.invokeMethod<void>('update', {
        'active': running != null,
        'title': running?.video.title ?? '离线缓存',
        'status': status,
        'progress': running?.progress == null
            ? -1
            : (running!.progress! * 100).round(),
      });
    } else if (platform == AppPlatform.linux) {
      final label = '${running?.video.title ?? '离线缓存'} · $status';
      if (_linuxLastStatus == label) return;
      _linuxReady ??= _linuxNotifications.initialize().catchError(
        (Object _) => false,
      );
      if (!await _linuxReady!) return;
      _linuxLastStatus = label;
      try {
        if (running == null && task == null) {
          await _linuxNotifications.cancel(_notificationId);
        } else {
          await _linuxNotifications.show(
            id: _notificationId,
            title: running?.video.title ?? '离线缓存',
            body: status,
          );
        }
        _windowsTask = running?.id;
      } catch (_) {
        // Notifications are optional; the download queue keeps running.
      }
    } else if (platform == AppPlatform.windows) {
      if (running == null) _dismissedWindowsTask = null;
      if (running?.id == _dismissedWindowsTask && running != null) return;
      if (running == null && _windowsTask == null) return;
      if (!await (_windowsAvailable?.call() ??
          WindowsFocusNotificationBackend.instance.isAvailable())) {
        return;
      }
      final plugin =
          _windowsPlugin ??
          FlutterLocalNotificationsPlugin()
              .resolvePlatformSpecificImplementation<
                FlutterLocalNotificationsWindows
              >();
      if (plugin == null) return;
      final progress = task?.status == DownloadTaskStatus.completed
          ? 1.0
          : task?.progress;
      final label = progress == null ? '' : '${(progress * 100).round()}%';
      final bindings = <String, String>{
        'downloadTitle': task?.video.title ?? '离线缓存',
        'downloadStatus': status,
        'download-progressValue': progress?.toString() ?? 'indeterminate',
        'download-progressString': label,
      };
      final bar = WindowsProgressBar(
        id: 'download',
        status: '{downloadStatus}',
        value: progress,
        label: label,
      );
      if (running != null && _windowsTask != running.id) {
        await plugin.show(
          id: _notificationId,
          title: '离线缓存',
          body: '{downloadTitle}',
          notificationDetails: WindowsNotificationDetails(
            audio: WindowsNotificationAudio.silent(),
            progressBars: [bar],
            bindings: bindings,
          ),
        );
        _windowsTask = running.id;
      } else if (_windowsTask != null) {
        final result = await plugin.updateBindings(
          id: _notificationId,
          bindings: bindings,
        );
        if (result == NotificationUpdateResult.notFound) {
          // Do not recreate a notification the user dismissed on every byte update.
          _dismissedWindowsTask = running?.id;
          _windowsTask = null;
        } else if (result == NotificationUpdateResult.error) {
          throw StateError('Windows download notification update failed');
        }
        if (running == null) _windowsTask = null;
      }
    }
  }
}
