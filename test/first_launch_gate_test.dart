import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/onboarding/first_launch_gate.dart';
import 'package:focubili/services/first_launch_service.dart';

/// 为首次启动门禁创建一个可识别的测试主页。
Widget _buildGate({
  Future<void> Function()? exitApplication,
  Future<void> Function(BuildContext context)? openLoginPage,
}) {
  return MaterialApp(
    home: FirstLaunchGate(
      exitApplication: exitApplication,
      openLoginPage: openLoginPage,
      child: const Scaffold(body: Text('测试主页')),
    ),
  );
}

/// 验证首次安装协议倒计时、退出、持久化和一次性登录引导。
void main() {
  /// 每项测试都从独立的内存本机存储开始，避免状态互相污染。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证首次打开必须阅读十秒，保存成功后才显示主页与登录引导。
  testWidgets('首次安装十秒后才能同意并显示一次登录引导', (WidgetTester tester) async {
    await tester.pumpWidget(_buildGate());
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('user-agreement-page')), findsOneWidget);
    expect(find.text('一、非官方项目声明'), findsOneWidget);
    expect(find.text('同意并继续（10 秒）'), findsOneWidget);
    FilledButton acceptButton = tester.widget<FilledButton>(
      find.byKey(const Key('accept-user-agreement')),
    );
    expect(acceptButton.onPressed, isNull);

    await tester.pump(const Duration(seconds: 9));
    expect(find.text('同意并继续（1 秒）'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    acceptButton = tester.widget<FilledButton>(
      find.byKey(const Key('accept-user-agreement')),
    );
    expect(acceptButton.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('accept-user-agreement')));
    await tester.pumpAndSettle();

    expect(find.text('测试主页'), findsOneWidget);
    expect(find.byKey(const Key('first-login-guide-dialog')), findsOneWidget);
    expect(find.text('登录后，您可以播放高清视频，并使用您的收藏夹等内容。'), findsOneWidget);
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(FirstLaunchService.agreementAcceptedKey),
      isTrue,
    );
    expect(preferences.getBool(FirstLaunchService.loginGuideShownKey), isTrue);

    await tester.tap(find.text('暂不登录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-login-guide-dialog')), findsNothing);
  });

  /// 验证不同意会调用系统退出替身，且绝不会写入协议同意状态。
  testWidgets('不同意协议直接退出且不保存同意状态', (WidgetTester tester) async {
    int exitCalls = 0;
    await tester.pumpWidget(
      _buildGate(
        exitApplication: () async {
          exitCalls += 1;
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('decline-user-agreement')));
    await tester.pump();

    expect(exitCalls, 1);
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(FirstLaunchService.agreementAcceptedKey),
      isNull,
    );
  });

  /// 验证协议和引导都已处理时直接进入主页，不再重复打扰用户。
  testWidgets('已同意且看过登录引导后直接进入主页', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      FirstLaunchService.agreementAcceptedKey: true,
      FirstLaunchService.loginGuideShownKey: true,
    });

    await tester.pumpWidget(_buildGate());
    await tester.pumpAndSettle();

    expect(find.text('测试主页'), findsOneWidget);
    expect(find.byKey(const Key('user-agreement-page')), findsNothing);
    expect(find.byKey(const Key('first-login-guide-dialog')), findsNothing);
  });

  /// 验证用户在唯一一次引导中选择登录后会调用登录页面导航。
  testWidgets('同意过协议但未看引导时可以前往登录', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      FirstLaunchService.agreementAcceptedKey: true,
    });
    int loginLaunches = 0;

    await tester.pumpWidget(
      _buildGate(
        openLoginPage: (BuildContext context) async {
          loginLaunches += 1;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('first-login-guide-dialog')), findsOneWidget);
    await tester.tap(find.text('去登录'));
    await tester.pumpAndSettle();

    expect(loginLaunches, 1);
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(FirstLaunchService.loginGuideShownKey), isTrue);
  });
}
