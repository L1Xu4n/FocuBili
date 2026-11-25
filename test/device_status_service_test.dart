import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/device_status_service.dart';

/// 注册原生设备状态服务的返回值校验、计量状态解析与缺失通道容错测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('com.focubili.app/device_status');
  const MethodChannel androidBgChannel = MethodChannel(
    'com.focubili.app/android_network_status',
  );

  /// 每个测试后移除模拟处理器，避免影响同一进程中的其他方法通道测试。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidBgChannel, null);
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

  /// 验证原生网络名称会转换为播放器使用的稳定枚举。
  test('读取 Wi-Fi 网络类型', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'getNetworkType');
          return 'wifi';
        });

    expect(
      await const NativeDeviceStatusService().loadNetworkType(),
      DeviceNetworkType.wifi,
    );
  });

  /// 验证未知平台返回不会被误判为 Wi-Fi 或移动网络。
  test('未知网络类型安全回退', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => 'vpn');

    expect(
      await const NativeDeviceStatusService().loadNetworkType(),
      DeviceNetworkType.other,
    );
  });

  test('读取完整网络计量状态与低数据模式', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'getNetworkStatus');
          return <String, Object?>{
            'type': 'wifi',
            'metered': 'metered',
            'lowDataMode': 'on',
          };
        });

    final DeviceNetworkStatus status = await const NativeDeviceStatusService()
        .loadNetworkStatus();
    expect(status.type, DeviceNetworkType.wifi);
    expect(status.metered, DeviceNetworkMeteredStatus.metered);
    expect(status.lowDataMode, DeviceLowDataModeStatus.on);
    expect(status.prefersDataSaving, isTrue);
    expect(status.allowsUnmeteredOnlyAction, isFalse);
  });

  test('前台通道缺失时回退到 Android 后台插件网络状态通道', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidBgChannel, (MethodCall call) async {
          expect(call.method, 'getNetworkStatus');
          return <String, Object?>{
            'type': 'wifi',
            'metered': 'unmetered',
            'lowDataMode': 'off',
          };
        });

    final DeviceNetworkStatus status = await const NativeDeviceStatusService()
        .loadNetworkStatus();
    expect(status.type, DeviceNetworkType.wifi);
    expect(status.isKnownUnmetered, isTrue);
    expect(status.prefersDataSaving, isFalse);
    expect(status.allowsUnmeteredOnlyAction, isTrue);
  });

  test('旧通道仅返回 wifi 时计量状态保持 unknown 且不放行仅未计量操作', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'getNetworkStatus') {
            throw MissingPluginException();
          }
          if (call.method == 'getNetworkType') {
            return 'wifi';
          }
          return null;
        });

    final DeviceNetworkStatus status = await const NativeDeviceStatusService()
        .loadNetworkStatus();
    expect(status.type, DeviceNetworkType.wifi);
    expect(status.metered, DeviceNetworkMeteredStatus.unknown);
    expect(status.allowsUnmeteredOnlyAction, isFalse);
    expect(status.prefersDataSaving, isFalse);
  });
}
