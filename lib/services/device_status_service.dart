import 'package:flutter/services.dart';

/// 表示播放器关心的当前网络连接类型，不读取网络名称或地址。
enum DeviceNetworkType {
  wifi('Wi-Fi'),
  mobile('移动网络'),
  ethernet('有线网络'),
  offline('离线'),
  other('网络未知');

  /// 创建只用于播放器展示的短标签。
  const DeviceNetworkType(this.label);

  final String label;

  /// 从 Android 返回的稳定名称恢复网络类型，未知值安全归为其他网络。
  static DeviceNetworkType fromPlatformName(Object? name) {
    return DeviceNetworkType.values.firstWhere(
      (DeviceNetworkType type) => type.name == name,
      orElse: () => DeviceNetworkType.other,
    );
  }
}

/// 抽象设备状态读取能力，方便播放器页面在测试时替换为固定电量和网络。
abstract interface class DeviceStatusService {
  /// 返回当前设备电量百分比；系统不支持或调用失败时返回空值。
  Future<int?> loadBatteryPercent();

  /// 返回当前网络连接类型；读取失败时返回“网络未知”。
  Future<DeviceNetworkType> loadNetworkType();
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

  /// 读取 Android 当前活动网络，只区分连接类型，不读取 SSID、运营商或 IP。
  @override
  Future<DeviceNetworkType> loadNetworkType() async {
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        'getNetworkType',
      );
      return DeviceNetworkType.fromPlatformName(result);
    } on MissingPluginException {
      return DeviceNetworkType.other;
    } on PlatformException {
      return DeviceNetworkType.other;
    }
  }
}
