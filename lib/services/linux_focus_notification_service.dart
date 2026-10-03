import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'windows_focus_notification_service.dart';

/// Linux uses the desktop notification server and app-owned reminder timers.
/// Deadlines survive restart, but a closed app cannot wake itself to notify.
class LinuxNotificationClient implements WindowsNotificationClient {
  LinuxNotificationClient({
    FlutterLocalNotificationsPlugin? plugin,
    this.persistReminders = true,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final bool persistReminders;
  final Map<int, Timer> _timers = {};
  final Map<int, Map<String, Object>> _pending = {};
  Future<void> _writes = Future<void>.value();
  static const _key = 'linux_notification_deadlines_v1';

  @override
  bool get hasPackageIdentity => false;

  @override
  Future<bool> initialize() async {
    final ready = await _plugin.initialize(
      settings: const InitializationSettings(
        linux: LinuxInitializationSettings(defaultActionName: '打开焦点哔哩'),
      ),
    );
    if (ready != true) return false;
    if (!persistReminders) return true;
    final preferences = await SharedPreferences.getInstance();
    try {
      final data = jsonDecode(preferences.getString(_key) ?? '[]');
      if (data is List) {
        for (final item in data.take(100)) {
          if (item is! Map ||
              item['id'] is! int ||
              item['at'] is! int ||
              item['title'] is! String ||
              item['body'] is! String) {
            continue;
          }
          final at = DateTime.fromMillisecondsSinceEpoch(item['at'] as int);
          // Do not flood the user with old reminders after days away.
          if (at.isBefore(DateTime.now().subtract(const Duration(hours: 1)))) {
            continue;
          }
          _arm(
            item['id'] as int,
            item['title'] as String,
            item['body'] as String,
            at,
          );
        }
      }
    } on FormatException {
      // A damaged reminder list never blocks app startup or focus history.
    }
    await _persist();
    return true;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) => _plugin.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      linux: LinuxNotificationDetails(),
    ),
  );

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  }) async {
    _arm(id, title, body, scheduledAt);
    await _persist();
  }

  void _arm(int id, String title, String body, DateTime at) {
    _timers.remove(id)?.cancel();
    _pending[id] = {
      'id': id,
      'title': title,
      'body': body,
      'at': at.millisecondsSinceEpoch,
    };
    final delay = at.difference(DateTime.now());
    _timers[id] = Timer(delay.isNegative ? Duration.zero : delay, () async {
      _timers.remove(id);
      _pending.remove(id);
      await _persist();
      try {
        await show(id: id, title: title, body: body);
      } catch (_) {
        // A stopped notification server must not crash playback or focus.
      }
    });
  }

  Future<void> _persist() {
    if (!persistReminders) return Future<void>.value();
    final snapshot = jsonEncode(_pending.values.toList());
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_key, snapshot);
    });
    return _writes;
  }

  @override
  Future<void> cancel(int id) async {
    _timers.remove(id)?.cancel();
    _pending.remove(id);
    await _persist();
    await _plugin.cancel(id: id);
  }

  // GNOME/KDE/other desktops have no universal settings URI.
  @override
  Future<void> openSettings() async {}
}

/// Reuses platform-neutral text/ID handling with a Linux-only notification client.
class LinuxFocusNotificationBackend extends WindowsFocusNotificationBackend {
  LinuxFocusNotificationBackend({WindowsNotificationClient? client})
    : super(client: client ?? LinuxNotificationClient());
  static final instance = LinuxFocusNotificationBackend();

  @override
  Future<Map<Object?, Object?>> getDiagnostics() async => {
    ...await super.getDiagnostics(),
    'platform': 'linux',
    'manufacturer': 'Linux',
    'lastTriggerResult': 'application_timer',
    'lastScheduleMode': 'in_process_persisted_deadline',
    'exactAlarmAllowed': false,
    'reminderMode': 'in_process_persisted_deadline',
    'requiresRunningApplication': true,
  };
}
