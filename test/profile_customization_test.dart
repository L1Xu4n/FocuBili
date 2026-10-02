import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/profile/profile_page.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/dashboard_layout_service.dart';

/// 提供固定已登录账号，并记录布局操作是否误调用账号清理。
class _AccountFixture extends BilibiliAuthService {
  int clearCalls = 0;

  /// 返回本地测试账号，避免真实网络与 Cookie 访问。
  @override
  Future<BilibiliSessionState> loadCurrentSession() async =>
      const BilibiliSessionState.active(
        BilibiliAccount(mid: 123, name: '测试账号', avatarUrl: ''),
      );

  /// 记录退出登录，确保隐藏摘要不会删除账号状态。
  @override
  Future<void> logout() async => clearCalls++;

  /// 记录清理会话，确保编辑卡片不触发切换账号。
  @override
  Future<void> clearBilibiliSession() async => clearCalls++;
}

/// 配置真实逻辑视口，结束时恢复测试设备尺寸。
void _setWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

/// 用减少动画与指定字体比例构建实际个人中心页面。
Widget _host(
  _AccountFixture account,
  DashboardLayoutService service, {
  double textScale = 1,
}) => MaterialApp(
  // 测试包装函数保留真实 MediaQuery 尺寸，仅改变字体与动画偏好。
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: ProfilePage(authService: account, layoutService: service),
);

/// 滚动到目标控件并点击，验证底部操作确实能从实际页面到达。
Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// 覆盖页面接入的稳定身份、账号隔离、恢复保存及窄矮窗口可达性。
void main() {
  // 每次验证使用独立本机配置，不继承其他测试的隐藏状态。
  setUp(() => SharedPreferences.setMockInitialValues({}));
  // 恢复平台覆盖，避免桌面测试影响其他页面。
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// 打开真实排序菜单，再验证隐藏恢复及账号状态不会受布局编辑影响。
  testWidgets('账号和全部可选入口可隐藏恢复，设置必需且重进保持顺序', (tester) async {
    _setWindow(tester, const Size(1000, 700));
    final account = _AccountFixture();
    final service = DashboardLayoutService();
    await tester.pumpWidget(_host(account, service));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-settings-shortcut')), findsNothing);
    await _tapVisible(tester, find.text('自定义'));
    expect(find.byKey(const ValueKey('dashboard-hide-settings')), findsNothing);

    // 在实际页面上把观看记录移到账号摘要之前，跨越原分组顺序。
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('dashboard-menu-watch-history')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('dashboard-before-watch-history')),
    );
    expect((await service.load('profile', [])).order.take(2), [
      'watch-history',
      'account',
    ]);
    const optionalIds = [
      'account',
      'watch-history',
      'offline-videos',
      'app-favorites',
      'video-notes',
      'focus-statistics',
      'favorites',
      'subscriptions',
      'following',
    ];
    for (final id in optionalIds) {
      await _tapVisible(tester, find.byKey(ValueKey('dashboard-hide-$id')));
    }
    expect(
      find.byKey(const ValueKey('dashboard-card-settings')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('profile-account-card')), findsNothing);
    expect(find.text('添加卡片').hitTestable(), findsOneWidget);
    expect(account.clearCalls, 0);
    expect((await service.load('profile', [])).hidden, optionalIds.toSet());

    await _tapVisible(tester, find.text('添加卡片'));
    for (final id in ['account', 'watch-history']) {
      await _tapVisible(tester, find.byKey(ValueKey('dashboard-add-$id')));
    }
    await _tapVisible(tester, find.text('关闭'));
    await _tapVisible(tester, find.text('完成'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(account, DashboardLayoutService()));
    await tester.pumpAndSettle();
    expect(find.text('测试账号'), findsOneWidget);
    expect(find.text('观看记录'), findsOneWidget);
    expect(find.text('离线缓存'), findsNothing);
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey('dashboard-card-watch-history')),
          )
          .dy,
      greaterThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('dashboard-card-account')))
            .dy,
      ),
    );
    expect(account.clearCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320窄屏大字体单列且设置和底部自定义可达', (tester) async {
    _setWindow(tester, const Size(320, 640));
    await tester.pumpWidget(
      _host(_AccountFixture(), DashboardLayoutService(), textScale: 2),
    );
    await tester.pumpAndSettle();
    final history = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-watch-history')),
    );
    final offline = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-offline-videos')),
    );
    expect(history.width, 288);
    expect(offline.top, greaterThan(history.bottom));
    await tester.ensureVisible(
      find.byKey(const ValueKey('dashboard-card-settings')),
    );
    await tester.pumpAndSettle();
    expect(find.text('设置').hitTestable(), findsOneWidget);
    await _tapVisible(tester, find.text('自定义'));
    expect(find.text('完成').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 桌面矮视口进入编辑后按钮直接可点，并在绑定核验前恢复平台覆盖。
  testWidgets('Windows1000x420统一滚动两列且账号操作和底部设置可达', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    _setWindow(tester, const Size(1000, 420));
    await tester.pumpWidget(_host(_AccountFixture(), DashboardLayoutService()));
    await tester.pumpAndSettle();
    expect(find.byTooltip('账号操作').hitTestable(), findsOneWidget);
    final history = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-watch-history')),
    );
    final offline = tester.getRect(
      find.byKey(const ValueKey('dashboard-card-offline-videos')),
    );
    expect(history.width, 472);
    expect(history.top, offline.top);
    expect(offline.left, greaterThan(history.right));
    await tester.ensureVisible(
      find.byKey(const ValueKey('dashboard-card-settings')),
    );
    await tester.pumpAndSettle();
    expect(find.text('设置').hitTestable(), findsOneWidget);
    await _tapVisible(tester, find.text('自定义'));
    expect(find.text('添加卡片').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-hide-settings')), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
