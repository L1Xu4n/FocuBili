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

  /// 从平台返回的稳定名称恢复网络类型，未知值安全归为其他网络。
  static DeviceNetworkType fromPlatformName(Object? name) {
    return DeviceNetworkType.values.firstWhere(
      (DeviceNetworkType type) => type.name == name,
      orElse: () => DeviceNetworkType.other,
    );
  }
}

/// 表示当前活动网络是否按流量计费；无法确认时保持未知。
enum DeviceNetworkMeteredStatus {
  unknown,
  unmetered,
  metered;

  static DeviceNetworkMeteredStatus fromPlatformName(Object? name) {
    return DeviceNetworkMeteredStatus.values.firstWhere(
      (DeviceNetworkMeteredStatus status) => status.name == name,
      orElse: () => DeviceNetworkMeteredStatus.unknown,
    );
  }
}

/// 表示系统低数据模式 / Android 后台流量节省限制状态；不支持时保持未知。
enum DeviceLowDataModeStatus {
  unknown,
  off,
  on;

  static DeviceLowDataModeStatus fromPlatformName(Object? name) {
    return DeviceLowDataModeStatus.values.firstWhere(
      (DeviceLowDataModeStatus status) => status.name == name,
      orElse: () => DeviceLowDataModeStatus.unknown,
    );
  }
}

/// 聚合网络传输类型、计量成本与系统低数据模式；三项均独立可表达未知。
class DeviceNetworkStatus {
  const DeviceNetworkStatus({
    required this.type,
    this.metered = DeviceNetworkMeteredStatus.unknown,
    this.lowDataMode = DeviceLowDataModeStatus.unknown,
  });

  /// 兼容旧通道仅返回传输类型的回退构造；旧通道读到 `wifi` 时计量状态仍保持未知。
  factory DeviceNetworkStatus.fromLegacyType(DeviceNetworkType type) {
    return DeviceNetworkStatus(
      type: type,
      metered: type == DeviceNetworkType.mobile
          ? DeviceNetworkMeteredStatus.metered
          : DeviceNetworkMeteredStatus.unknown,
      lowDataMode: DeviceLowDataModeStatus.unknown,
    );
  }

  /// 从原生 Map 构造网络状态；缺失或非法字段均保守回退为未知。
  factory DeviceNetworkStatus.fromPlatformMap(Map<Object?, Object?> values) {
    final DeviceNetworkType type = DeviceNetworkType.fromPlatformName(
      values['type'],
    );
    final DeviceNetworkMeteredStatus rawMetered =
        DeviceNetworkMeteredStatus.fromPlatformName(values['metered']);
    final DeviceNetworkMeteredStatus metered =
        type == DeviceNetworkType.offline
        ? DeviceNetworkMeteredStatus.unknown
        : rawMetered;
    final DeviceLowDataModeStatus lowDataMode =
        DeviceLowDataModeStatus.fromPlatformName(values['lowDataMode']);
    return DeviceNetworkStatus(
      type: type,
      metered: metered,
      lowDataMode: lowDataMode,
    );
  }

  final DeviceNetworkType type;
  final DeviceNetworkMeteredStatus metered;
  final DeviceLowDataModeStatus lowDataMode;

  bool get isOffline => type == DeviceNetworkType.offline;

  bool get isKnownMetered =>
      !isOffline &&
      (metered == DeviceNetworkMeteredStatus.metered ||
          type == DeviceNetworkType.mobile);

  bool get isKnownUnmetered =>
      !isOffline && metered == DeviceNetworkMeteredStatus.unmetered;

  bool get isLowDataActive => lowDataMode == DeviceLowDataModeStatus.on;

  /// 用于媒体缓冲与省流音质判断：明确计量网络或系统低数据模式开启时返回 true。
  bool get prefersDataSaving => isKnownMetered || isLowDataActive;

  /// 严格用于“仅未计量网络”门控：必须明确读到 `unmetered`、非离线且未处于低数据模式。
  bool get allowsUnmeteredOnlyAction => isKnownUnmetered && !isLowDataActive;

  @override
  bool operator ==(Object other) {
    return other is DeviceNetworkStatus &&
        other.type == type &&
        other.metered == metered &&
        other.lowDataMode == lowDataMode;
  }

  @override
  int get hashCode => Object.hash(type, metered, lowDataMode);
}

/// 抽象设备状态读取能力，方便播放器与后台任务测试替换为固定电量和网络。
abstract interface class DeviceStatusService {
  /// 返回当前设备电量百分比；系统不支持或调用失败时返回空值。
  Future<int?> loadBatteryPercent();

  /// 返回当前网络连接类型；读取失败时返回“网络未知”。
  Future<DeviceNetworkType> loadNetworkType();

  /// 返回包含传输类型、计量状态和低数据模式的完整网络状态。
  Future<DeviceNetworkStatus> loadNetworkStatus();
}

/// 通过 Android/Apple/Windows 方法通道读取无权限的当前设备电量与网络状态。
class NativeDeviceStatusService implements DeviceStatusService {
  const NativeDeviceStatusService();

  static const MethodChannel _channel = MethodChannel(
    'com.focubili.app/device_status',
  );

  /// 供 Android WorkManager 后台无界面引擎复用的插件网络通道。
  static const MethodChannel _androidBackgroundChannel = MethodChannel(
    'com.focubili.app/android_network_status',
  );

  /// 读取并校验原生返回的电量，系统没有可靠读数时安全返回空值。
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

  /// 读取平台当前活动网络，只区分连接类型，不读取 SSID、运营商或 IP。
  @override
  Future<DeviceNetworkType> loadNetworkType() async {
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        'getNetworkType',
      );
      return DeviceNetworkType.fromPlatformName(result);
    } on MissingPluginException {
      return _loadAndroidBackgroundNetworkType();
    } on PlatformException {
      return DeviceNetworkType.other;
    }
  }

  /// 读取包含计量与低数据模式的网络状态；兼容旧通道并支持 Android 后台引擎回退。
  @override
  Future<DeviceNetworkStatus> loadNetworkStatus() async {
    final DeviceNetworkStatus? foreground = await _tryReadStatus(_channel);
    if (foreground != null) {
      return foreground;
    }
    final DeviceNetworkStatus? androidBackground = await _tryReadStatus(
      _androidBackgroundChannel,
    );
    if (androidBackground != null) {
      return androidBackground;
    }
    return DeviceNetworkStatus.fromLegacyType(await loadNetworkType());
  }

  Future<DeviceNetworkStatus?> _tryReadStatus(MethodChannel channel) async {
    try {
      final Object? result = await channel.invokeMethod<Object?>(
        'getNetworkStatus',
      );
      if (result is Map<Object?, Object?>) {
        return DeviceNetworkStatus.fromPlatformMap(result);
      }
      if (result is String) {
        return DeviceNetworkStatus.fromLegacyType(
          DeviceNetworkType.fromPlatformName(result),
        );
      }
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<DeviceNetworkType> _loadAndroidBackgroundNetworkType() async {
    try {
      final Object? result = await _androidBackgroundChannel
          .invokeMethod<Object?>('getNetworkType');
      return DeviceNetworkType.fromPlatformName(result);
    } on MissingPluginException {
      return DeviceNetworkType.other;
    } on PlatformException {
      return DeviceNetworkType.other;
    }
  }
}
