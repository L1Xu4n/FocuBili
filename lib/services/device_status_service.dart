import 'package:flutter/services.dart';

/// 抽象设备状态读取能力，方便播放器页面在测试时替换为固定电量。
abstract interface class DeviceStatusService {
  /// 返回当前设备电量百分比；系统不支持或调用失败时返回空值。
  Future<int?> loadBatteryPercent();
}

/// 通过 Android 方法通道读取无权限的当前设备电量百分比。
class NativeDeviceStatusService implements DeviceStatusService {
  const NativeDeviceStatusService();

  static const MethodChannel _channel = MethodChannel(
    'com.focubili.app/device_status',
  );

  /// 读取并校验原生返回的电量，测试或非 Android 平台没有通道时安全返回空值。
  @override
  Future<int?> loadBatteryPercent() async {
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        'getBatteryPercent',
      );
      final int? value = (result as num?)?.toInt();
      return value != null && value >= 0 && value <= 100 ? value : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
