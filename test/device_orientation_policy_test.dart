import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/layout/adaptive_layout.dart';
import 'package:focubili/core/layout/device_orientation_policy.dart';

/// 验证横屏工作台断点和设备方向策略不会因后续重构而失效。
void main() {
  /// 验证只有足够宽的横向窗口才会进入工作台布局。
  test('横向宽窗口启用工作台，竖向窗口保持普通布局', () {
    expect(AdaptiveLayout.usesWorkspace(const Size(900, 600)), isTrue);
    expect(AdaptiveLayout.usesWorkspace(const Size(899, 600)), isFalse);
    expect(AdaptiveLayout.usesWorkspace(const Size(1200, 1400)), isFalse);
  });

  /// 验证只有 1200dp 以上的横屏窗口会展开导航文字。
  test('桌面宽度启用展开工作台', () {
    expect(AdaptiveLayout.usesExpandedWorkspace(const Size(1200, 700)), isTrue);
    expect(
      AdaptiveLayout.workspaceNavigationWidth(const Size(1000, 700)),
      AdaptiveLayout.compactNavigationWidth,
    );
  });

  /// 验证 Android 平板启动时只允许左右两个横屏方向。
  test('Android 平板启动方向为横屏', () {
    expect(
      DeviceOrientationPolicy.startupOrientations(
        logicalSize: const Size(1067, 600),
        isAndroid: true,
      ),
      const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    );
  });

  /// 验证 Android 手机仍以竖屏启动，并能在播放器中旋转到横屏。
  test('Android 手机保持竖屏启动并允许播放器横屏', () {
    expect(
      DeviceOrientationPolicy.startupOrientations(
        logicalSize: const Size(393, 852),
        isAndroid: true,
      ),
      const <DeviceOrientation>[DeviceOrientation.portraitUp],
    );
    expect(
      DeviceOrientationPolicy.playerOrientations(
        logicalSize: const Size(393, 852),
        isAndroid: true,
      ),
      contains(DeviceOrientation.landscapeLeft),
    );
  });

  /// 验证桌面端不调用移动设备的强制旋转能力。
  test('非 Android 平台不强制屏幕方向', () {
    expect(
      DeviceOrientationPolicy.startupOrientations(
        logicalSize: const Size(1280, 800),
        isAndroid: false,
      ),
      isEmpty,
    );
    expect(
      DeviceOrientationPolicy.playerOrientations(
        logicalSize: const Size(1280, 800),
        isAndroid: false,
      ),
      isEmpty,
    );
  });
}
