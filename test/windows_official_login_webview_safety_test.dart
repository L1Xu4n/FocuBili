import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证仓库内 WebView2 修复持续保留原始登录请求，并由原生同步白名单限制跳转。
void main() {
  /// 登录窗口不得再通过取消后 Navigate 的方式重放密码 POST 或成功重定向。
  test('Windows 登录使用同步原生白名单且不重放导航', () {
    final String source = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();

    expect(source, contains('IsAllowedNavigationUri(uri.get())'));
    expect(source, contains('args->put_Cancel(!allowed)'));
    expect(
      source,
      isNot(contains('GetDeferral(&deferral)')),
      reason: '当前 WebView2 版本不支持延迟普通导航，登录请求必须同步放行或阻止。',
    );
  });

  /// FocuBili 登录服务必须把可信主机交给原生层，避免退回异步 Dart 导航回调。
  test('Windows 登录服务启用原生可信主机列表', () {
    final String source = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();

    expect(source, contains('setAllowedNavigationHosts'));
    expect(source, contains("'graph.qq.com'"));
    expect(source, contains("'xui.ptlogin2.qq.com'"));
    expect(source, isNot(contains('setOnUrlRequestCallback')));
  });

  /// 创建接口只能在 CoreWebView2 和导航监听器全部就绪后通知 Dart，防止首屏加载丢失后黑屏。
  test('Windows WebView2 准备完成后才返回创建成功', () {
    final String nativeSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();
    final int setupIndex = nativeSource.indexOf(
      'webview_controller_ = controller;',
    );
    final int callbackIndex = nativeSource.indexOf(
      'on_web_view_created_callback_(OnWebviewControllerCreated());',
    );

    expect(setupIndex, greaterThanOrEqualTo(0));
    expect(callbackIndex, greaterThan(setupIndex));
  });

  /// URL 组件直接引用原字符串时不得请求 WinINet 解码，否则所有 HTTPS 首屏都会被误拒绝为黑屏。
  test('Windows 登录白名单使用有效的 URL 解析参数', () {
    final String nativeSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();

    expect(
      nativeSource,
      contains('InternetCrackUrlW(url.c_str(), 0, 0, &components)'),
    );
    expect(
      nativeSource,
      isNot(contains('InternetCrackUrlW(url.c_str(), 0, ICU_DECODE')),
    );
  });

  /// 登录服务必须等待原生首屏导航调用，启动失败才可以被页面捕获并提示。
  test('Windows 登录服务等待首屏导航调用', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();

    expect(serviceSource, contains('await webview.launch('));
  });

  /// Windows 应完整替换为 Android 移动 UA 并打开同一 H5 入口，不能继续追加桌面 UA 标记。
  test('Windows 登录复用 Android 移动 UA 与 H5 入口', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();
    final String pluginSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();

    expect(serviceSource, contains('await webview.setUserAgent('));
    expect(serviceSource, contains('fallbackMobileWebUserAgent'));
    expect(serviceSource, contains('officialMobileLoginUri'));
    expect(serviceSource, contains('buildWindowsOfficialLoginUri()'));
    expect(serviceSource, contains("'gourl': 'https://www.bilibili.com/'"));
    expect(serviceSource, isNot(contains('officialDesktopLoginUri')));
    expect(serviceSource, isNot(contains('setApplicationNameForUserAgent')));
    expect(
      pluginSource,
      contains('settings2->put_UserAgent(user_agent.c_str())'),
    );
  });

  /// 登录窗口应交给原生层按 DPI 缩放，防止 150% 等缩放比例下表单被横向裁切。
  test('Windows 登录窗口启用系统 DPI 尺寸换算', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();

    expect(serviceSource, contains('useWindowPositionAndSize: false'));
  });

  /// WebView2 可选 Cookie 元数据读取失败时仍必须保留 SESSDATA 的必要字段。
  test('Windows Cookie 桥接不会因可选元数据失败丢弃登录态', () {
    final String nativeSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();

    expect(nativeSource, contains('double expires = -1;'));
    expect(nativeSource, contains('cookie->get_Expires(&expires);'));
    expect(
      nativeSource,
      isNot(
        contains(
          'if (FAILED(hr)) continue;\n                hr = cookie->get_IsSecure',
        ),
      ),
    );
  });

  /// WebView2 同步拒绝 Cookie 查询时必须立即回传错误，不能让 Dart Future 永久等待。
  test('Windows Cookie 查询同步失败时会完成方法调用', () {
    final String nativeSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();

    expect(nativeSource, contains('const HRESULT get_cookies_hr'));
    expect(nativeSource, contains('if (FAILED(get_cookies_hr))'));
    expect(nativeSource, contains('Failed to start cookie query'));
  });

  /// 会话 Cookie 不得把 WebView2 的零过期时间传成 Unix 纪元并被筛选器丢弃。
  test('Windows Cookie 桥接保留仍有效的会话 Cookie', () {
    final String nativeSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();

    expect(nativeSource, contains('if (!isSessionOnly && expires > 0)'));
  });

  /// 网页登录成功只由 B站官方账号接口判定，不在窗口层硬编码单一 Cookie 名。
  test('Windows 网页登录使用官方账号接口确认完成', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();

    expect(serviceSource, contains('saveBrowserVerifiedSession'));
    expect(serviceSource, contains('webview.launch('));
    expect(serviceSource, contains('document.body.innerText'));
    expect(serviceSource, contains('BilibiliHttpAuthApi.accountEndpoint'));
    expect(serviceSource, contains('buildMergedBilibiliLoginCookieHeader'));
    expect(serviceSource, contains('getCookiesForUrl('));
    expect(serviceSource, isNot(contains("RegExp(r'(^|;\\s*)SESSDATA")));
  });

  /// 手机号和密码接口成功后应补齐官方 data.url 落地链，但不得把地址或登录输入发给宿主。
  test('Windows 登录完成官方成功响应的落地跳转', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();

    expect(serviceSource, contains('/x/passport-login/web/login/sms'));
    expect(serviceSource, contains("response.code === 0"));
    expect(serviceSource, contains('response.data.url'));
    expect(serviceSource, contains('window.location.replace(redirectUrl)'));
    expect(serviceSource, contains('_loginSessionLandingTimeout'));
    expect(serviceSource, contains('official_redirect_no_session'));
    expect(serviceSource, isNot(contains('postMessage(redirectUrl)')));
    expect(serviceSource, isNot(contains('request.body')));
  });

  /// 登录观察脚本必须等 WebView2 确认注册后再打开网页，避免首屏导航抢跑。
  test('Windows 登录等待文档脚本注册完成', () {
    final String nativeSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();
    final String pluginSource = File(
      'third_party/desktop_webview_window/windows/web_view_window_plugin.cc',
    ).readAsStringSync();

    expect(nativeSource, contains('const HRESULT add_script_hr'));
    expect(nativeSource, contains('result->Success()'));
    expect(pluginSource, contains('std::move(result)'));
  });

  /// Windows 应在导航完成时像 Android onPageFinished 一样立即检查，同时保留周期轮询。
  test('Windows 登录导航完成后立即检查会话', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();
    final String webviewSource = File(
      'third_party/desktop_webview_window/lib/src/webview_impl.dart',
    ).readAsStringSync();

    expect(serviceSource, contains('setOnNavigationCompletedCallback'));
    expect(serviceSource, contains('unawaited(checkSession())'));
    expect(serviceSource, contains('getCookiesForUrl('));
    expect(
      webviewSource,
      contains('_onNavigationCompletedCallback?.call(url, isSuccess)'),
    );
  });

  /// Cookie 查询应把 nav HTTPS 地址传给 WebView2，由浏览器处理域名、路径和同名 Cookie。
  test('Windows Cookie 桥接按官方 nav 地址筛选', () {
    final String nativeSource = File(
      'third_party/desktop_webview_window/windows/web_view.cc',
    ).readAsStringSync();
    final String pluginSource = File(
      'third_party/desktop_webview_window/windows/web_view_window_plugin.cc',
    ).readAsStringSync();

    expect(nativeSource, contains('url.empty() ? nullptr : url.c_str()'));
    expect(pluginSource, contains('getCookiesForUrl'));
    expect(pluginSource, contains('GetCookiesForUrl('));
  });

  /// 已读取登录 Cookie 但官方接口连续拒绝时必须明确报错，不能继续无限轮询。
  test('Windows 登录会话无法确认时有次数上限', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();

    expect(serviceSource, contains('_containsBilibiliSessionCookie'));
    expect(serviceSource, contains('网页登录已产生会话'));
  });

  /// 程序识别登录成功后关闭窗口时，必须先完成 Dart onClose 且不得重入删除同一窗口。
  test('Windows 程序关闭登录窗口会可靠完成 onClose', () {
    final String windowSource = File(
      'third_party/desktop_webview_window/windows/webview_window.cc',
    ).readAsStringSync();
    final String pluginSource = File(
      'third_party/desktop_webview_window/windows/web_view_window_plugin.cc',
    ).readAsStringSync();

    expect(windowSource, contains('void WebviewWindow::NotifyWindowClosed()'));
    expect(windowSource, contains('void WebviewWindow::Close()'));
    expect(pluginSource, contains('auto closing_window = std::move('));
    expect(pluginSource, contains('closing_window->Close();'));
  });

  /// 即使原生关闭通知异常，已经验证成功的账号也不能永远卡在登录窗口收尾阶段。
  test('Windows 登录完成后等待关闭通知有超时兜底', () {
    final String serviceSource = File(
      'lib/services/windows_official_login_service.dart',
    ).readAsStringSync();

    expect(
      serviceSource,
      contains('webview.onClose.timeout(const Duration(seconds: 3))'),
    );
  });
}
