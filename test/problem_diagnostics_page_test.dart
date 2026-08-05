import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/problem_diagnostics_page.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';

/// 创建固定环境与内存存储的诊断服务，供页面测试验证显示和清空按钮。
Future<ProblemDiagnosticsService> _createPageDiagnosticsService() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return ProblemDiagnosticsService(
    preferencesLoader: () async => preferences,
    appVersionLoader: () async => '1.1.1+10',
    deviceInfoLoader: () async => const DiagnosticDeviceInfo(
      androidRelease: '15',
      apiLevel: 35,
      model: 'Xiaomi 23127PN0CC',
    ),
    clock: () => DateTime(2026, 8, 2, 22, 40),
  );
}

/// 注册问题诊断页面的基础环境、最近错误与清空入口组件测试。
void main() {
  /// 每项测试前清空 SharedPreferences，避免诊断记录影响其他组件测试。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('问题诊断页面展示环境、最近错误和两个操作按钮', (WidgetTester tester) async {
    final ProblemDiagnosticsService service =
        await _createPageDiagnosticsService();
    await service.recordNetworkFailure(
      operation: 'search_video',
      message: '网络连接失败。',
    );
    await tester.pumpWidget(
      MaterialApp(home: ProblemDiagnosticsPage(diagnosticsService: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text('基础环境信息'), findsOneWidget);
    expect(find.text('1.1.1+10'), findsOneWidget);
    expect(find.text('Android 15 / API 35'), findsOneWidget);
    expect(find.text('网络错误'), findsOneWidget);
    expect(find.byKey(const Key('reminder-diagnostics-card')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('copy-problem-diagnostics')),
      300,
    );
    expect(find.byKey(const Key('copy-problem-diagnostics')), findsOneWidget);
    expect(find.byKey(const Key('clear-problem-diagnostics')), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear-problem-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无诊断记录'), findsOneWidget);
  });
}
