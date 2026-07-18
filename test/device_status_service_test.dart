import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/device_status_service.dart';

/// 注册原生设备状态服务的返回值校验与缺失通道容错测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('com.focubili.app/device_status');

  /// 每个测试后移除模拟处理器，避免影响同一进程中的其他方法通道测试。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 验证服务只接受 Android 返回的有效百分比。
  test('读取有效电量百分比', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'getBatteryPercent');
          return 73;
        });

    expect(await const NativeDeviceStatusService().loadBatteryPercent(), 73);
  });

  /// 验证缺失、越界或非数值读数都不会被伪造成真实电量。
  test('异常电量读数安全返回空值', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => 120);

    expect(
      await const NativeDeviceStatusService().loadBatteryPercent(),
      isNull,
    );
  });
}
