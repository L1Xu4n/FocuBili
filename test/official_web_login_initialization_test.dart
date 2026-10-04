import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:focubili/features/profile/official_web_login_page.dart';
import 'package:focubili/services/bilibili_request_policy.dart';

/// 用真实登录页面配合平台接口替身，验证初始化能到达官方地址而不读取账号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.focubili.app/device_status');
  final originalPlatform = WebViewPlatform.instance ?? _LoginWebViewPlatform();
  late _LoginWebViewPlatform platform;

  /// 每例重置内核、偏好设置和 WebView 替身，避免外部网络或原生视图依赖。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    platform = _LoginWebViewPlatform();
    WebViewPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => <String, Object>{'providerAvailable': true},
        );
  });

  /// 恢复全局平台和方法通道，避免影响其他页面测试。
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    WebViewPlatform.instance = originalPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final target in <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    /// macOS 模拟上游同步异常，iOS 与 Android 必须保留白色背景配置。
    testWidgets('$target 初始化后加载官方登录地址', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: OfficialWebLoginPage()));
      await tester.pumpAndSettle();

      final controller = platform.controllers.single;
      expect(controller.javaScriptMode, JavaScriptMode.unrestricted);
      expect(
        controller.backgroundColors,
        target == TargetPlatform.macOS ? isEmpty : <Color>[Colors.white],
      );
      expect(controller.userAgent, contains('Mobile'));
      expect(controller.delegate, isNotNull);
      expect(
        controller.requests.single.uri,
        BilibiliRequestPolicy.officialMobileLoginUri,
      );
      expect(find.byKey(const Key('login-webview')), findsOneWidget);
      expect(find.text('登录网页暂时不可用'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(target));
  }

  /// 加载失败后仍可重建控制器并重试；不会把所有初始化错误吞掉。
  testWidgets('macOS 初始化加载失败后可重试', (tester) async {
    platform.failNextLoad = true;
    await tester.pumpWidget(const MaterialApp(home: OfficialWebLoginPage()));
    await tester.pumpAndSettle();
    expect(find.text('登录网页暂时不可用'), findsOneWidget);
    expect(platform.controllers, hasLength(1));

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(platform.controllers, hasLength(2));
    expect(
      platform.controllers.last.requests.single.uri,
      BilibiliRequestPolicy.officialMobileLoginUri,
    );
    expect(find.byKey(const Key('login-webview')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

/// 提供控制器、导航回调与可见视图的轻量替身。
class _LoginWebViewPlatform extends WebViewPlatform {
  final controllers = <_LoginController>[];
  bool failNextLoad = false;

  /// 每次重试创建独立控制器，模拟一次可恢复的加载失败。
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _LoginController(params, failLoad: failNextLoad);
    failNextLoad = false;
    controllers.add(controller);
    return controller;
  }

  /// 接收页面的真实导航配置，不触发会话轮询。
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _LoginDelegate(params);

  /// 替代原生 WebView，保留页面是否完成初始化的可见证据。
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _LoginWidget(params);
}

/// 记录初始化配置，并精确模拟锁定 WKWebView 版本的 macOS 背景色异常。
class _LoginController extends PlatformWebViewController {
  /// 创建只记录调用的控制器；可指定加载官方地址时失败。
  _LoginController(super.params, {required this.failLoad})
    : super.implementation();

  final bool failLoad;
  final backgroundColors = <Color>[];
  final requests = <LoadRequestParams>[];
  JavaScriptMode? javaScriptMode;
  String? userAgent;
  PlatformNavigationDelegate? delegate;

  /// 记录 JavaScript 配置，保证修复后仍完成原有初始化。
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {
    javaScriptMode = mode;
  }

  /// macOS 同步抛出上游错误，防止重新引入导致登录页打不开的调用。
  @override
  Future<void> setBackgroundColor(Color color) {
    backgroundColors.add(color);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      throw UnimplementedError('opaque is not implemented on macOS');
    }
    return Future<void>.value();
  }

  /// 返回公开固定 UA，不读取设备或账号数据。
  @override
  Future<String?> getUserAgent() async => 'TestWebView';

  /// 记录页面补充的移动端 UA。
  @override
  Future<void> setUserAgent(String? value) async => userAgent = value;

  /// 保存页面导航委托，让测试确认回调配置没有被跳过。
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate value,
  ) async => delegate = value;

  /// 记录官方地址并模拟一次初始化失败，不访问外部网络。
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requests.add(params);
    if (failLoad) throw StateError('test_load_failure');
    (delegate as _LoginDelegate).onProgress?.call(100);
  }
}

/// 接收页面已有的五种导航回调，不主动调用网络或账号服务。
class _LoginDelegate extends PlatformNavigationDelegate {
  /// 使用官方接口构造函数注册导航替身。
  _LoginDelegate(super.params) : super.implementation();

  ProgressCallback? onProgress;

  /// 接收导航策略。
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}

  /// 接收加载开始回调。
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}

  /// 接收加载结束回调。
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {}

  /// 接收进度回调。
  @override
  Future<void> setOnProgress(ProgressCallback callback) async =>
      onProgress = callback;

  /// 接收资源错误回调。
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

/// 在初始化成功时绘制标记视图，不创建真实原生窗口。
class _LoginWidget extends PlatformWebViewWidget {
  /// 使用官方接口构造函数注册视图替身。
  _LoginWidget(super.params) : super.implementation();

  /// 显示固定标记，供测试确认登录页已挂载 WebView。
  @override
  Widget build(BuildContext context) =>
      const SizedBox(key: Key('login-webview'));
}
