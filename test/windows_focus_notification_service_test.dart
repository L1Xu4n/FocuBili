import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/services/windows_focus_notification_service.dart';

/// 保存假 Windows 通知客户端收到的最后一条通知，便于断言内容和稳定编号。
class _RecordedNotification {
  /// 创建一条内存通知记录。
  const _RecordedNotification({
    required this.id,
    required this.title,
    required this.body,
    this.scheduledAt,
  });

  final int id;
  final String title;
  final String body;
  final DateTime? scheduledAt;
}

/// 在内存中模拟 Windows Toast，保证自动化测试不会访问真实系统通知中心。
class _FakeWindowsNotificationClient implements WindowsNotificationClient {
  bool initializeResult = true;
  bool packageIdentity = false;
  int initializeCalls = 0;
  int openSettingsCalls = 0;
  final List<_RecordedNotification> shown = <_RecordedNotification>[];
  final List<_RecordedNotification> scheduled = <_RecordedNotification>[];
  final List<int> cancelledIds = <int>[];

  /// 返回测试指定的 MSIX 包身份状态。
  @override
  bool get hasPackageIdentity => packageIdentity;

  /// 返回测试指定的初始化结果并记录调用次数。
  @override
  Future<bool> initialize() async {
    initializeCalls += 1;
    return initializeResult;
  }

  /// 记录一次立即显示请求。
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add(_RecordedNotification(id: id, title: title, body: body));
  }

  /// 记录一次未来通知安排请求。
  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  }) async {
    scheduled.add(
      _RecordedNotification(
        id: id,
        title: title,
        body: body,
        scheduledAt: scheduledAt,
      ),
    );
  }

  /// 记录待取消的稳定通知编号。
  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
  }

  /// 记录打开 Windows 通知设置的次数。
  @override
  Future<void> openSettings() async {
    openSettingsCalls += 1;
  }
}

/// 验证 Windows 专注完成通知、未来提醒、取消和平台服务路由。
void main() {
  test('未来提醒会裁剪换行并用同一稳定编号取消', () async {
    final _FakeWindowsNotificationClient client =
        _FakeWindowsNotificationClient();
    final WindowsFocusNotificationBackend backend =
        WindowsFocusNotificationBackend(client: client);
    final DateTime reminderAt = DateTime.now().add(const Duration(hours: 1));

    final bool scheduled = await backend.scheduleReminder(
      sessionId: 'session-2026-08-09',
      goal: '复习 Flutter\nWindows',
      reason: '先休息\r\n十分钟',
      reminderAt: reminderAt,
    );
    await backend.cancelReminder('session-2026-08-09');

    expect(scheduled, isTrue);
    expect(client.initializeCalls, 1);
    expect(client.scheduled, hasLength(1));
    expect(client.scheduled.single.title, '该继续专注了');
    expect(client.scheduled.single.body, isNot(contains('\n')));
    expect(client.scheduled.single.scheduledAt, reminderAt);
    expect(client.cancelledIds.single, client.scheduled.single.id);
  });

  test('完成通知不包含会话编号且诊断不保存目标和原因', () async {
    final _FakeWindowsNotificationClient client =
        _FakeWindowsNotificationClient();
    final WindowsFocusNotificationBackend backend =
        WindowsFocusNotificationBackend(client: client);

    await backend.showFocusCompleted(
      sessionId: 'private-session-id',
      goal: '完成桌面客户端',
      focusedMinutes: 45,
    );
    await backend.scheduleReminder(
      sessionId: 'private-session-id',
      goal: '不会进入诊断的目标',
      reason: '不会进入诊断的原因',
      reminderAt: DateTime.now().add(const Duration(hours: 2)),
    );
    final Map<Object?, Object?> diagnostics = await backend.getDiagnostics();

    expect(client.shown.single.body, contains('45 分钟'));
    expect(client.shown.single.body, isNot(contains('private-session-id')));
    expect(diagnostics['pendingCount'], 1);
    expect(diagnostics.toString(), isNot(contains('不会进入诊断')));
    expect(diagnostics['lastScheduleMode'], 'windows_toast');
  });

  test('FocusNotificationService 注入 Windows 后端后跳过 Android 通道', () async {
    final _FakeWindowsNotificationClient client =
        _FakeWindowsNotificationClient();
    final WindowsFocusNotificationBackend backend =
        WindowsFocusNotificationBackend(client: client);
    final FocusNotificationService service = FocusNotificationService(
      windowsBackend: backend,
    );

    final bool notificationAllowed = await service.hasPermission();
    final bool exactReminderAllowed = await service.hasExactAlarmPermission();
    await service.openSettings();

    expect(notificationAllowed, isTrue);
    expect(exactReminderAllowed, isTrue);
    expect(client.initializeCalls, 1);
    expect(client.openSettingsCalls, 1);
  });
}
