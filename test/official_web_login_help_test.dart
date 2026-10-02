import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/official_web_login_page.dart';

/// 从独立上一页打开登录页，检查帮助操作实际影响的导航层级。
Future<void> _openLogin(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          // 建立属于 Navigator 的上下文，模拟真实登录方式选择页。
          builder: (context) => TextButton(
            // 测试入口与应用一致，使用单独路由承载官方登录页面。
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const OfficialWebLoginPage(),
              ),
            ),
            child: const Text('选择登录方式'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('选择登录方式'));
  await tester.pumpAndSettle();
}

/// 验证网页不可用时恢复入口仍可操作，且关闭帮助不会错误退出登录页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.focubili.app/device_status');
  var environmentReads = 0;

  // 用明确缺失的内核模拟加载失败；测试不创建原生网页或读取真实账号。
  setUp(() {
    environmentReads = 0;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          environmentReads++;
          return <String, Object>{'providerAvailable': false};
        });
  });

  // 每例结束后移除平台替身，避免污染其他登录检查。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // 先取消再重试，验证两个操作都保留登录路由，重试确实重新查询内核。
  testWidgets('验证码帮助可取消，重载仍停留在登录页', (tester) async {
    await _openLogin(tester);
    expect(environmentReads, 1);
    await tester.tap(find.text('验证码一直加载？'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(OfficialWebLoginPage), findsOneWidget);

    await tester.tap(find.text('验证码一直加载？'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(OfficialWebLoginPage), findsOneWidget);
    expect(environmentReads, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 返回扫码先关闭帮助再退出网页登录，让已有登录方式选择页重新可见。
  testWidgets('验证码帮助能返回登录方式选择页', (tester) async {
    await _openLogin(tester);
    await tester.tap(find.text('验证码一直加载？'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回选择扫码登录'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(OfficialWebLoginPage), findsNothing);
    expect(find.text('选择登录方式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
