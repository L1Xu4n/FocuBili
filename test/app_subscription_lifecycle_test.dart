import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/app.dart';
import 'package:focubili/features/onboarding/first_launch_gate.dart';
import 'package:focubili/services/first_launch_service.dart';
import 'package:focubili/services/subscription_service.dart';

class LifecycleSubscriptions extends SubscriptionService {
  final states = <bool>[];
  @override
  void setForeground(bool value) => states.add(value);
}

void main() {
  testWidgets('协议检查在后台结束时不启动前台订阅，恢复时才开启', (tester) async {
    SharedPreferences.setMockInitialValues({
      FirstLaunchService.agreementAcceptedKey: true,
      FirstLaunchService.loginGuideShownKey: true,
    });
    final subscriptions = LifecycleSubscriptions();
    addTearDown(subscriptions.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(FocuBiliApp(subscriptionService: subscriptions));
    final gate = tester.widget<FirstLaunchGate>(find.byType(FirstLaunchGate));
    subscriptions.states.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Deliver the asynchronous gate callback after the app has backgrounded.
    gate.onReady!();
    expect(subscriptions.states, isNotEmpty);
    expect(subscriptions.states, everyElement(false));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(subscriptions.states.last, true);
    await tester.pumpWidget(const SizedBox.shrink());
    // Let the existing home-session lookup timeout finish after unmount.
    await tester.pump(const Duration(seconds: 13));
  });
}
