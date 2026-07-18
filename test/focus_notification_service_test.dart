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
            'scheduleReminder' => true,
            _ => null,
          };
        });
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
}
