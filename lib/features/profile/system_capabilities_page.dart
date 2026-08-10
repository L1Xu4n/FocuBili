import 'dart:io';

import 'package:flutter/material.dart';

import 'android_permission_management_page.dart';
import 'windows_system_capabilities_page.dart';

/// 根据操作系统显示 Android 权限管理或 Windows 桌面系统能力页面。
class SystemCapabilitiesPage extends StatelessWidget {
  /// 创建平台化系统能力入口。
  const SystemCapabilitiesPage({super.key});

  /// Windows 不构建 Android 权限文案，其他现有平台继续保留原页面。
  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return const WindowsSystemCapabilitiesPage();
    }
    return const AndroidPermissionManagementPage();
  }
}
