import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/windows_do_not_disturb_service.dart';

/// 验证 Windows 系统专注服务向 Runner 发送检查、切换和设置命令，并保守处理未授权能力。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'com.focubili.app/test_windows_do_not_disturb',
  );
  final List<MethodCall> calls = <MethodCall>[];

  /// 每项测试记录调用，并模拟当前安装包没有微软系统专注受限功能授权。
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return call.method == 'openSettings';
        });
  });

  /// 每项测试后解除方法通道，避免调用记录泄漏。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 未授权安装包必须报告自动切换失败，但仍可转发关闭清理和设置页入口。
  test('Windows 系统专注服务如实转发未授权结果', () async {
    const WindowsDoNotDisturbService service = WindowsDoNotDisturbService(
      channel: channel,
    );

    expect(await service.isSupported(), isFalse);
    expect(await service.setEnabled(true), isFalse);
    expect(await service.setEnabled(false), isFalse);
    await service.openSettings();

    expect(calls.map((MethodCall call) => call.method), <String>[
      'isSupported',
      'setEnabled',
      'setEnabled',
      'openSettings',
    ]);
    expect(
      Map<Object?, Object?>.from(calls[1].arguments as Map)['enabled'],
      isTrue,
    );
    expect(
      Map<Object?, Object?>.from(calls[2].arguments as Map)['enabled'],
      isFalse,
    );
  });
}
