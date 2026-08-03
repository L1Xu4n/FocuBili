import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/focus_notification_service.dart';

/// 注册专注通知方法通道的权限、安排和取消参数测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'com.focubili.app/test_focus_notifications',
  );
  final List<MethodCall> calls = <MethodCall>[];

  /// 每项测试记录 Flutter 发给原生层的方法，并返回可控结果。
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'hasPermission' => true,
            'requestPermission' => true,
            'hasExactAlarmPermission' => true,
            'hasDoNotDisturbAccess' => true,
            'setFocusDoNotDisturb' => true,
            'getPermissionOverview' => <String, Object?>{
              'notificationAllowed': true,
              'exactAlarmAllowed': true,
              'doNotDisturbAllowed': false,
              'batteryOptimizationIgnored': true,
              'backgroundRestricted': false,
              'requiresAutostartGuide': true,
              'manufacturer': 'Xiaomi',
              'apiLevel': 35,
            },
            'getReminderDiagnostics' => <String, Object?>{
              'pendingCount': 1,
              'lastScheduleMode': 'exact',
            },
            'scheduleReminder' => true,
            _ => null,
          };
        });
  });

  /// 验证设置提醒前可检查精确闹钟特殊权限，并能打开对应系统设置页。
  test('通知服务检查精确闹钟权限', () async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );

    expect(await service.hasExactAlarmPermission(), isTrue);
    await service.openExactAlarmSettings();

    expect(calls.map((MethodCall call) => call.method), <String>[
      'hasExactAlarmPermission',
      'openExactAlarmSettings',
    ]);
  });

  /// 每项测试结束后解除假通道，避免影响其他平台通道测试。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 验证权限检查和请求结果由原生返回值决定。
  test('通知服务检查并请求权限', () async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );

    expect(await service.hasPermission(), isTrue);
    expect(await service.requestPermission(), isTrue);
    expect(calls.map((MethodCall call) => call.method), <String>[
      'hasPermission',
      'requestPermission',
    ]);
  });

  /// 验证勿扰模式会先检查特殊访问权限，再把开启、恢复和设置跳转交给 Android。
  test('通知服务管理专注勿扰模式', () async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );

    expect(await service.hasDoNotDisturbAccess(), isTrue);
    expect(await service.setFocusDoNotDisturb(true), isTrue);
    await service.openDoNotDisturbSettings();
    expect(await service.setFocusDoNotDisturb(false), isTrue);

    expect(calls.map((MethodCall call) => call.method), <String>[
      'hasDoNotDisturbAccess',
      'setFocusDoNotDisturb',
      'openDoNotDisturbSettings',
      'setFocusDoNotDisturb',
    ]);
    expect(
      Map<Object?, Object?>.from(calls[1].arguments as Map)['enabled'],
      isTrue,
    );
    expect(
      Map<Object?, Object?>.from(calls.last.arguments as Map)['enabled'],
      isFalse,
    );
  });

  /// 验证提醒携带任务、原因和毫秒时间戳，并可按任务编号取消。
  test('通知服务安排并取消专注提醒', () async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );
    final DateTime reminderAt = DateTime(2026, 7, 19, 9, 30);

    expect(
      await service.scheduleReminder(
        sessionId: 'focus-1',
        goal: '继续看课程',
        reason: '临时接电话',
        reminderAt: reminderAt,
      ),
      isTrue,
    );
    await service.cancelReminder('focus-1');

    final Map<Object?, Object?> arguments = Map<Object?, Object?>.from(
      calls.first.arguments as Map,
    );
    expect(arguments['sessionId'], 'focus-1');
    expect(arguments['triggerAtMs'], reminderAt.millisecondsSinceEpoch);
    expect(calls.last.method, 'cancelReminder');
  });

  /// 验证完成弹窗会通过原生通道请求播放一次庆祝音效。
  test('通知服务请求播放庆祝音效', () async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );

    await service.playCelebrationSound();

    expect(calls.single.method, 'playCelebrationSound');
  });

  /// 验证统一权限页可以一次读取所有状态，并打开每个保留给用户控制的系统入口。
  test('通知服务汇总权限状态并打开后台保护设置', () async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );

    final AndroidPermissionOverview overview = await service
        .getPermissionOverview();
    expect(overview.notificationAllowed, isTrue);
    expect(overview.doNotDisturbAllowed, isFalse);
    expect(overview.requiresAutostartGuide, isTrue);
    expect(overview.manufacturer, 'Xiaomi');
    expect(overview.apiLevel, 35);

    await service.openBackgroundAutostartSettings();
    await service.openBatterySettings();
    await service.openSettings();
    expect(calls.map((MethodCall call) => call.method), <String>[
      'getPermissionOverview',
      'openBackgroundAutostartSettings',
      'openBatterySettings',
      'openSettings',
    ]);
  });

  /// 验证问题诊断页可以读取并清空原生闹钟历史，而不会走取消真实提醒的接口。
  test('通知服务读取并清空提醒诊断', () async {
    final FocusNotificationService service = FocusNotificationService(
      channel: channel,
    );

    final Map<Object?, Object?> diagnostics = await service
        .getReminderDiagnostics();
    expect(diagnostics['pendingCount'], 1);
    expect(diagnostics['lastScheduleMode'], 'exact');
    await service.clearReminderDiagnostics();

    expect(calls.map((MethodCall call) => call.method), <String>[
      'getReminderDiagnostics',
      'clearReminderDiagnostics',
    ]);
  });
}
