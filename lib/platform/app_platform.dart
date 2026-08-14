import 'dart:io';

/// 列出 FocuBili 能明确识别的运行平台，未知环境不会自动伪装成 Android。
enum AppPlatform { android, windows, ios, macos, linux, unsupported }

/// 集中读取 dart:io 平台信息，业务页面不再直接判断具体操作系统。
abstract final class AppPlatformDetector {
  /// 读取当前进程的真实操作系统并转换成可穷尽处理的平台枚举。
  static AppPlatform get current => resolve(
    isAndroid: Platform.isAndroid,
    isWindows: Platform.isWindows,
    isIOS: Platform.isIOS,
    isMacOS: Platform.isMacOS,
    isLinux: Platform.isLinux,
  );

  /// 返回当前系统公开版本字符串，诊断层仍需自行裁剪和脱敏。
  static String get operatingSystemVersion => Platform.operatingSystemVersion;

  /// 判断当前进程是否由 Flutter 测试宿主启动，避免测试调用真实平台通道。
  static bool get isFlutterTest =>
      Platform.environment['FLUTTER_TEST'] == 'true';

  /// 把一组互斥平台标记转换为枚举，供单元测试覆盖所有目标和未知环境。
  static AppPlatform resolve({
    required bool isAndroid,
    required bool isWindows,
    required bool isIOS,
    required bool isMacOS,
    required bool isLinux,
  }) {
    if (isAndroid) {
      return AppPlatform.android;
    }
    if (isWindows) {
      return AppPlatform.windows;
    }
    if (isIOS) {
      return AppPlatform.ios;
    }
    if (isMacOS) {
      return AppPlatform.macos;
    }
    if (isLinux) {
      return AppPlatform.linux;
    }
    return AppPlatform.unsupported;
  }
}

/// 提供不含版本和设备标识的平台显示名称，供不可用页面与诊断回退使用。
extension AppPlatformDisplayName on AppPlatform {
  /// 把平台枚举转换为稳定的用户可读名称。
  String get displayName => switch (this) {
    AppPlatform.android => 'Android',
    AppPlatform.windows => 'Windows',
    AppPlatform.ios => 'iOS',
    AppPlatform.macos => 'macOS',
    AppPlatform.linux => 'Linux',
    AppPlatform.unsupported => '未知平台',
  };
}
