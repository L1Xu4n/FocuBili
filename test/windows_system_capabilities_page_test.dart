import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/windows_system_capabilities_page.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/services/windows_focus_notification_service.dart';

/// 用内存计数器模拟 Windows Toast，页面测试不会触发真实通知或系统设置。
class _PageWindowsNotificationClient implements WindowsNotificationClient {
  int shownCount = 0;
  int settingsCount = 0;

  /// 页面测试模拟普通 exe，因此不具备 MSIX 包身份。
  @override
  bool get hasPackageIdentity => false;

  /// 模拟 Windows Toast 初始化成功。
  @override
  Future<bool> initialize() async => true;

  /// 记录用户主动发送的测试通知。
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    shownCount += 1;
  }

  /// 页面组件测试不安排真实提醒，因此该函数保持为空。
  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  }) async {}

  /// 页面组件测试不创建待取消提醒，因此该函数保持为空。
  @override
  Future<void> cancel(int id) async {}

  /// 记录用户点击系统通知设置按钮的次数。
  @override
  Future<void> openSettings() async {
    settingsCount += 1;
  }
}

/// 验证 Windows 系统能力页只显示桌面端真实能力并允许发送测试 Toast。
void main() {
  testWidgets('Windows 系统能力页不显示 Android 权限并可发送测试通知', (
    WidgetTester tester,
  ) async {
    final _PageWindowsNotificationClient client =
        _PageWindowsNotificationClient();
    final FocusNotificationService service = FocusNotificationService(
      windowsBackend: WindowsFocusNotificationBackend(client: client),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: WindowsSystemCapabilitiesPage(notificationService: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Windows 桌面能力'), findsOneWidget);
    expect(find.text('未来继续提醒'), findsOneWidget);
    expect(find.text('当前为普通 exe'), findsOneWidget);
    expect(find.textContaining('精确闹钟权限'), findsNothing);
    expect(find.textContaining('电量优化'), findsNothing);
    expect(find.textContaining('后台自启动'), findsNothing);

    await tester.tap(find.text('发送测试通知'));
    await tester.pumpAndSettle();
    expect(client.shownCount, 1);

    await tester.tap(find.text('系统通知设置'));
    await tester.pumpAndSettle();
    expect(client.settingsCount, 1);
  });
}
