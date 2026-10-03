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
    this.saveDeadlines,
    this.cancelNotification,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final bool persistReminders;
  final Future<bool> Function(String)? saveDeadlines;
  final Future<void> Function(int)? cancelNotification;
  final Map<int, int> _generations = {};
  int _serial = 0;
  int _lastRestoredAt = 0;
  int _lastTriggeredAt = 0;
  String _lastTriggerResult = 'none';
  Map<Object?, Object?> get diagnostics => {
    'pendingCount': _pending.length,
    'lastRestoredAtMs': _lastRestoredAt,
    'lastTriggeredAtMs': _lastTriggeredAt,
    'lastTriggerResult': _lastTriggerResult,
  };
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
              item['body'] is! String ||
              (item['at'] as int).abs() > 8640000000000000) {
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
    if (_pending.isNotEmpty) {
      _lastRestoredAt = DateTime.now().millisecondsSinceEpoch;
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
    final generation = _arm(id, title, body, scheduledAt);
    try {
      await _persist();
    } catch (_) {
      if (_generations[id] == generation) {
        _generations.remove(id);
        _timers.remove(id)?.cancel();
        _pending.remove(id);
      }
      rethrow;
    }
  }

  int _arm(int id, String title, String body, DateTime at) {
    final generation = ++_serial;
    _generations[id] = generation;
    _timers.remove(id)?.cancel();
    _pending[id] = {
      'id': id,
      'title': title,
      'body': body,
      'at': at.millisecondsSinceEpoch,
    };
    final delay = at.difference(DateTime.now());
    _timers[id] = Timer(delay.isNegative ? Duration.zero : delay, () async {
      if (_generations[id] != generation) return;
      _timers.remove(id);
      _pending.remove(id);
      try {
        await _persist();
      } catch (_) {
        /* Delivery still works without storage. */
      }
      if (_generations[id] != generation) return;
      try {
        await show(id: id, title: title, body: body);
        _lastTriggeredAt = DateTime.now().millisecondsSinceEpoch;
        _lastTriggerResult = 'delivered';
      } catch (_) {
        _lastTriggerResult = 'notification_unavailable';
        // A stopped notification server must not crash playback or focus.
      } finally {
        if (_generations[id] == generation) _generations.remove(id);
      }
    });
    return generation;
  }

  Future<void> _persist() {
    if (!persistReminders) return Future<void>.value();
    final snapshot = jsonEncode(_pending.values.toList());
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final saved = saveDeadlines != null
          ? await saveDeadlines!(snapshot)
          : await (await SharedPreferences.getInstance()).setString(
              _key,
              snapshot,
            );
      if (!saved) throw StateError('Reminder persistence failed');
    });
    return _writes;
  }

  @override
  Future<void> cancel(int id) async {
    _generations.remove(id);
    _timers.remove(id)?.cancel();
    _pending.remove(id);
    await _persist();
    await (cancelNotification?.call(id) ?? _plugin.cancel(id: id));
  }

  // GNOME/KDE/other desktops have no universal settings URI.
  @override
  Future<void> openSettings() async {}
}

/// Reuses platform-neutral text/ID handling with a Linux-only notification client.
class LinuxFocusNotificationBackend extends WindowsFocusNotificationBackend {
  factory LinuxFocusNotificationBackend({WindowsNotificationClient? client}) =>
      LinuxFocusNotificationBackend._(client ?? LinuxNotificationClient());
  LinuxFocusNotificationBackend._(this._linuxClient)
    : super(client: _linuxClient);
  final WindowsNotificationClient _linuxClient;
  static final instance = LinuxFocusNotificationBackend();

  @override
  Future<Map<Object?, Object?>> getDiagnostics() async {
    final base = await super.getDiagnostics();
    return {
      ...base,
      if (_linuxClient is LinuxNotificationClient) ..._linuxClient.diagnostics,
      'events': [
        for (final event in (base['events'] as List? ?? []))
          if (event is Map)
            {
              ...event,
              if (event['mode'] == 'windows_toast')
                'mode': 'in_process_persisted_deadline',
            },
      ],
      'platform': 'linux',
      'manufacturer': 'Linux',
      'lastScheduleMode': 'in_process_persisted_deadline',
      'exactAlarmAllowed': false,
      'reminderMode': 'in_process_persisted_deadline',
      'requiresRunningApplication': true,
    };
  }
}
