import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/focus_interruption_dialog.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/models/focus_session.dart';

/// 注册专注打断表单的中文日期与时间选择器测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 验证提醒时间选择器显示中文操作文案，并使用 24 小时制。
  testWidgets('专注提醒时间选择器使用中文', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '测试中文提醒',
      duration: const Duration(minutes: 25),
      sourceBvid: 'BV1TEST',
      sourcePartCid: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const <Locale>[Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: FilledButton(
              // 测试入口函数打开真实打断流程，不跳过任何产品对话框。
              onPressed: () => showFocusInterruptionFlow(
                context,
                controller: controller,
                kind: FocusInterruptionKind.manualPause,
              ),
              child: const Text('打开打断流程'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开打断流程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍要暂停'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置下次继续时间（可选）'));
    await tester.pumpAndSettle();
    expect(find.text('选择日期'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('选择提醒时间'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('SELECT TIME'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await controller.endFocusEarly(reason: '测试结束');
    await tester.pump();
  });
}
