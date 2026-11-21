import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/shell/main_shell.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/focus_timer_scope.dart';
import 'package:focubili/services/app_update_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/following_group_service.dart';
import 'package:focubili/services/subscription_onboarding_service.dart';
import 'subscription_performance_probe_test.dart'
    show feedFixture, feedFixtureClock;

// Render production MainShell with synthetic local records. Run with:
// FOCUBILI_PREVIEW_FONT=/path/to/CJK-Regular.otf flutter test test/desktop_dock_preview_test.dart
// Optional: FOCUBILI_PREVIEW_FONT_BOLD, FOCUBILI_PREVIEW_BRIGHTNESS=light,
// FOCUBILI_PREVIEW_DIR (default: build/desktop-dock).
void main() {
  final font = Platform.environment['FOCUBILI_PREVIEW_FONT'];
  final bold = Platform.environment['FOCUBILI_PREVIEW_FONT_BOLD'];
  final output = Directory(
    Platform.environment['FOCUBILI_PREVIEW_DIR'] ?? 'build/desktop-dock',
  );

  final light = Platform.environment['FOCUBILI_PREVIEW_BRIGHTNESS'] == 'light';

  testWidgets('真实桌面首页截图', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      SubscriptionOnboardingService.choiceKey: 'declined',
      SubscriptionService.storageKey: feedFixture(count: 3, sourceCount: 1),
      'dashboard.home_drawer_enabled': true,
      'dashboard.layout.home': jsonEncode({
        'version': 1,
        'order': [
          'home.continue_learning',
          'home.focus_session',
          'home.today_summary',
        ],
        'hidden': [
          'home.focus_finished',
          'home.recent_history',
          'home.quick_actions',
          'home.focus_subscriptions',
          'home.favorites',
          'home.followings',
        ],
      }),
      'focubili_learning_list_v2': jsonEncode({
        'schemaVersion': 3,
        'folders': [],
        'entries': [
          {
            'title': '高等数学 · 必修一',
            'ownerName': '示例',
            'bvid': 'BV1xx411c7mD',
            'partCid': 20,
            'partPageNumber': 4,
            'partTitle': '集合的概念',
            'positionMs': 352000,
            'durationMs': 1509000,
            'status': 'learning',
            'addedAt': '2026-01-01',
            'updatedAt': '2026-01-01',
          },
        ],
      }),
    });
    FlutterSecureStorage.setMockInitialValues({});
    await BilibiliAuthService().loadCurrentSession();
    await FollowingGroupService.instance.load(1);
    final subscriptions = SubscriptionService(clock: () => feedFixtureClock);
    await subscriptions.initialize();
    final focus = FocusTimerController(tickInterval: const Duration(days: 1));
    await focus.initialize();
    final updates = AppUpdateController();
    final shot = GlobalKey();
    await tester.runAsync(() async {
      final loader = FontLoader('DockSC');
      for (final path in [?font, ?bold]) {
        loader.addFont(
          Future.value(ByteData.sublistView(await File(path).readAsBytes())),
        );
      }
      await loader.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final base = light ? AppTheme.light() : AppTheme.dark();
    final theme = base.copyWith(
      platform: TargetPlatform.linux,
      textTheme: base.textTheme.apply(fontFamily: 'DockSC'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'DockSC'),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) => FocusTimerScope(
            controller: focus,
            child: AppUpdateScope(controller: updates, child: child!),
          ),
          home: MainShell(subscriptionService: subscriptions),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }

    await settle();
    Future<void> save(String which) async {
      await tester.runAsync(() async {
        final b =
            shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 1);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        await output.create(recursive: true);
        await File(
          '${output.path}/FocuBili-desktop-dock-$which.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        img.dispose();
      });
    }

    await save('collapsed');
    await tester.tap(find.byKey(const Key('desktop-dock-open')));
    await settle();
    expect(find.byKey(const Key('continue-learning-card')), findsOneWidget);
    expect(find.byKey(const Key('focus-ready-card')), findsOneWidget);
    expect(
      find.byKey(const Key('workspace-navigation-open-subscription')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await save('expanded');
    await tester.pumpWidget(const SizedBox.shrink());
    subscriptions.dispose();
    updates.dispose();
    focus.dispose();
  }, skip: font == null);
}
