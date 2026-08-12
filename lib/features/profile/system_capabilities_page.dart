import 'package:flutter/material.dart';

import '../../platform/app_platform.dart';
import '../../platform/platform_capabilities.dart';
import '../../platform/platform_services.dart';
import 'android_permission_management_page.dart';
import 'windows_system_capabilities_page.dart';

/// 根据统一能力表显示 Android 权限、Windows 桌面能力或暂不支持说明。
class SystemCapabilitiesPage extends StatelessWidget {
  /// 创建平台化系统能力入口；测试可注入指定平台的装配器。
  const SystemCapabilitiesPage({super.key, this.platformServices});

  final PlatformServices? platformServices;

  /// 按能力表穷尽选择页面，未知平台不会回退到 Android 权限页。
  @override
  Widget build(BuildContext context) {
    final PlatformServices services =
        platformServices ?? PlatformServices.current;
    return switch (services.capabilities.systemCapabilitiesExperience) {
      SystemCapabilitiesExperience.androidPermissions =>
        const AndroidPermissionManagementPage(),
      SystemCapabilitiesExperience.windowsDesktop =>
        const WindowsSystemCapabilitiesPage(),
      SystemCapabilitiesExperience.unavailable =>
        _UnavailableSystemCapabilitiesPage(platform: services.platform),
    };
  }
}

/// 在尚未实现系统集成的平台给出明确说明，不展示错误的 Android 权限开关。
class _UnavailableSystemCapabilitiesPage extends StatelessWidget {
  /// 创建带当前平台名称的不可用页面。
  const _UnavailableSystemCapabilitiesPage({required this.platform});

  final AppPlatform platform;

  /// 创建简洁的不可用状态和返回导航。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('系统能力')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.extension_off_outlined, size: 48),
              const SizedBox(height: 16),
              Text(
                '${platform.displayName} 的系统能力尚未接入',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text('当前不会申请权限或打开其他平台的系统设置。', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
