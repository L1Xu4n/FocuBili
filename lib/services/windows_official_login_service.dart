import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'bilibili_auth_service.dart';
import 'bilibili_request_policy.dart';
import 'problem_diagnostics_service.dart';

/// 抽象 Windows 官方网页登录启动器，方便登录页面在测试中注入不会打开真实窗口的实现。
abstract interface class WindowsOfficialLoginLauncher {
  /// 打开 B 站官方网页登录，成功时返回验证后的账号，用户关闭窗口时返回空。
  Future<BilibiliAccount?> open();
}

/// 表示从 WebView2 读取的一条最小 Cookie 信息，不包含任何日志输出能力。
class WindowsOfficialLoginCookie {
  /// 创建用于筛选 B 站会话的 Cookie 快照。
  const WindowsOfficialLoginCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.expires,
  });

  /// 从桌面 WebView 插件对象复制最小登录字段，避免业务层依赖其余浏览器元数据。
  factory WindowsOfficialLoginCookie.fromWebviewCookie(WebviewCookie cookie) {
    return WindowsOfficialLoginCookie(
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      expires: cookie.expires,
    );
  }

  final String name;
  final String value;
  final String domain;
  final DateTime? expires;
}

const Set<String> _allowedQqLoginHosts = <String>{
  'graph.qq.com',
  'xui.ptlogin2.qq.com',
};

const String _loginSubmitSuccessMessage = 'focubili-login-submit-success';

const Duration _loginSessionLandingTimeout = Duration(seconds: 15);

/// 观察 B站两个官方登录接口的成功响应，并在官方页面没有继续时补执行其返回的安全跳转。
const String _loginSuccessObserverScript = r'''
(() => {
  const successPaths = new Set([
    '/x/passport-login/web/login',
    '/x/passport-login/web/login/sms',
  ]);
  // 只允许 B站 HTTPS 地址作为登录成功后的落地页，拒绝账号信息和跨站地址被带出登录容器。
  const isAllowedOfficialRedirect = (value) => {
    try {
      const url = new URL(value, window.location.href);
      const host = url.hostname.toLowerCase();
      return url.protocol === 'https:' &&
        !url.username &&
        !url.password &&
        (host === 'bilibili.com' || host.endsWith('.bilibili.com'));
    } catch (_) {
      return false;
    }
  };
  // 官方 H5 成功分支会 replace(data.url)；短暂延后补跳可覆盖页面回调未执行的 WebView2 情况。
  const continueOfficialLogin = (response) => {
    const redirectUrl = response && response.data && response.data.url;
    if (!isAllowedOfficialRedirect(redirectUrl)) {
      return;
    }
    const observedUrl = window.location.href;
    window.setTimeout(() => {
      if (window.location.href === observedUrl) {
        window.location.replace(redirectUrl);
      }
    }, 800);
  };
  // 检查官方接口响应是否明确成功，只向宿主发送固定消息，跳转地址始终留在网页内部。
  const inspectResponse = (requestUrl, responseText) => {
    try {
      const url = new URL(requestUrl, window.location.href);
      if (url.hostname !== 'passport.bilibili.com' || !successPaths.has(url.pathname)) {
        return;
      }
      const response = JSON.parse(responseText);
      if (response && response.code === 0) {
        continueOfficialLogin(response);
        window.chrome.webview.postMessage('focubili-login-submit-success');
      }
    } catch (_) {
      // 非 JSON 响应或不支持 WebView 消息时保持网页原行为。
    }
  };
  const originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    // 包装 fetch 但保持原响应不变，克隆副本只用于检查 code。
    window.fetch = async function(...args) {
      const response = await originalFetch.apply(this, args);
      try {
        const requestUrl = typeof args[0] === 'string' ? args[0] : args[0].url;
        response.clone().text().then((text) => inspectResponse(requestUrl, text));
      } catch (_) {}
      return response;
    };
  }
  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSend = XMLHttpRequest.prototype.send;
  // 只记录请求 URL，不读取或复制请求正文。
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this.__focuBiliRequestUrl = String(url);
    return originalOpen.call(this, method, url, ...rest);
  };
  // 在响应完成后检查固定登录接口的 code，原始回调顺序不变。
  XMLHttpRequest.prototype.send = function(...args) {
    this.addEventListener('loadend', () => {
      try {
        inspectResponse(this.__focuBiliRequestUrl || '', this.responseText || '');
      } catch (_) {
        // 二进制响应不允许读取 responseText 时保持原请求结果。
      }
    }, {once: true});
    return originalSend.apply(this, args);
  };
})();
''';

/// 返回与 Android Cookie 容器相同顺序的网页、账号接口和 passport 三个会话探测地址。
List<Uri> buildBilibiliLoginCookieProbeUris() {
  return <Uri>[
    Uri.https('www.bilibili.com', '/'),
    BilibiliHttpAuthApi.accountEndpoint,
    BilibiliRequestPolicy.officialMobileLoginUri,
  ];
}

/// 为 Windows H5 登录提供明确的 B站落地页，让成功响应总能返回可写入网页 Cookie 的官方页面。
Uri buildWindowsOfficialLoginUri() {
  return BilibiliRequestPolicy.officialMobileLoginUri.replace(
    queryParameters: <String, String>{
      ...BilibiliRequestPolicy.officialMobileLoginUri.queryParameters,
      'gourl': 'https://www.bilibili.com/',
    },
  );
}

/// 判断顶层跳转是否属于 B 站或 QQ 官方登录 HTTPS 域名，拒绝无关外站和相似伪造域名。
bool isAllowedBilibiliLoginUri(Uri? uri) {
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
    return false;
  }
  final String host = uri.host.toLowerCase();
  final bool belongsToBilibili =
      host == 'bilibili.com' || host.endsWith('.bilibili.com');
  return belongsToBilibili || _allowedQqLoginHosts.contains(host);
}

/// 从 WebView2 已按 nav 地址筛选的 Cookie 中构造请求头；保留同名条目及浏览器返回顺序。
String buildBilibiliLoginCookieHeader(
  Iterable<WindowsOfficialLoginCookie> cookies, {
  DateTime? now,
}) {
  final DateTime currentTime = now ?? DateTime.now();
  final RegExp validCookieName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  final List<String> headerValues = <String>[];
  for (final WindowsOfficialLoginCookie cookie in cookies) {
    if (!_isUsableBilibiliLoginCookie(cookie, currentTime, validCookieName)) {
      continue;
    }
    // WebView2 已按目标 URL 处理 domain/path/secure；这里不得再按名称覆盖同名 Cookie。
    headerValues.add('${cookie.name}=${cookie.value}');
  }
  return headerValues.join('; ');
}

/// 按 Android 的子域读取顺序合并 Cookie；后读到的同名值覆盖前值并形成一份完整会话。
String buildMergedBilibiliLoginCookieHeader(
  Iterable<Iterable<WindowsOfficialLoginCookie>> cookieGroups, {
  DateTime? now,
}) {
  final DateTime currentTime = now ?? DateTime.now();
  final RegExp validCookieName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  final Map<String, String> valuesByName = <String, String>{};
  for (final Iterable<WindowsOfficialLoginCookie> cookies in cookieGroups) {
    for (final WindowsOfficialLoginCookie cookie in cookies) {
      if (!_isUsableBilibiliLoginCookie(cookie, currentTime, validCookieName)) {
        continue;
      }
      valuesByName[cookie.name] = cookie.value;
    }
  }
  return valuesByName.entries
      .map((MapEntry<String, String> entry) => '${entry.key}=${entry.value}')
      .join('; ');
}

/// 判断单条 Cookie 能否安全进入 B站请求头，不读取或输出其敏感值。
bool _isUsableBilibiliLoginCookie(
  WindowsOfficialLoginCookie cookie,
  DateTime now,
  RegExp validCookieName,
) {
  final String domain = cookie.domain.trim().toLowerCase();
  final bool belongsToBilibili =
      domain == 'bilibili.com' || domain.endsWith('.bilibili.com');
  final bool expired = cookie.expires?.isBefore(now) ?? false;
  return belongsToBilibili &&
      !expired &&
      validCookieName.hasMatch(cookie.name) &&
      cookie.value.isNotEmpty &&
      !cookie.value.contains(';') &&
      !cookie.value.contains('\r') &&
      !cookie.value.contains('\n');
}

/// 使用独立 WebView2 窗口承载 B 站官方账号密码页，并只在形成有效会话后保存 Cookie。
class WindowsOfficialLoginService implements WindowsOfficialLoginLauncher {
  /// 创建 Windows 登录服务；账号校验继续复用统一鉴权服务。
  WindowsOfficialLoginService({
    BilibiliAuthService? authService,
    ProblemDiagnosticsService? diagnosticsService,
  }) : _authService = authService ?? BilibiliAuthService(),
       _diagnosticsService = diagnosticsService ?? ProblemDiagnosticsService();

  final BilibiliAuthService _authService;
  final ProblemDiagnosticsService _diagnosticsService;

  /// 检查 WebView2、创建隔离登录窗口并轮询官方 Cookie，整个过程不读取网页表单内容。
  @override
  Future<BilibiliAccount?> open() async {
    if (!Platform.isWindows) {
      throw const WindowsOfficialLoginException('账号密码网页登录仅支持 Windows 客户端。');
    }
    if (!await WebviewWindow.isWebviewAvailable()) {
      throw const WindowsOfficialLoginException(
        '系统缺少 Microsoft Edge WebView2 Runtime，请安装后重试；扫码登录仍可正常使用。',
      );
    }
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final String profileDirectory =
        '${supportDirectory.path}${Platform.pathSeparator}official_login_webview';
    try {
      await WebviewWindow.clearAll(userDataFolderWindows: profileDirectory);
    } catch (_) {
      // 启动前清理旧临时会话失败时仍允许创建窗口，后续账号接口会再次验证 Cookie 有效性。
    }
    final Webview webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        windowWidth: 1000,
        windowHeight: 760,
        title: 'B 站官方登录',
        userDataFolderWindows: profileDirectory,
        // 让插件按 Windows DPI 缩放并自动居中，避免高缩放屏幕只显示半个登录表单。
        useWindowPositionAndSize: false,
      ),
    );
    final Completer<BilibiliAccount?> result = Completer<BilibiliAccount?>();
    Timer? checkTimer;
    bool checking = false;
    bool loginSubmitSucceeded = false;
    DateTime? loginSubmitSucceededAt;
    int cookieReadFailures = 0;

    /// 记录一次 Cookie 桥接失败；连续失败三次后给主页面明确错误，避免窗口无限无响应。
    void recordCookieReadFailure(StackTrace stackTrace) {
      cookieReadFailures += 1;
      if (cookieReadFailures < 3 || result.isCompleted) {
        return;
      }
      unawaited(
        _recordLoginDiagnostic(
          operation: 'windows_login_cookie_bridge_failed',
          stage: 'cookie_read_exception',
          cookieCount: 0,
        ),
      );
      result.completeError(
        const WindowsOfficialLoginException('连续多次无法读取官方登录状态，请关闭窗口后重试。'),
        stackTrace,
      );
      webview.close();
    }

    /// 登录 Cookie 出现后让当前 WebView2 自己导航到官方账号接口，由浏览器原样携带会话。
    Future<void> checkSession() async {
      if (checking || result.isCompleted) {
        return;
      }
      checking = true;
      try {
        final List<WindowsOfficialLoginCookie> allCookies =
            (await webview
                    .getCookiesForUrl(
                      BilibiliHttpAuthApi.accountEndpoint.toString(),
                    )
                    .timeout(const Duration(seconds: 4)))
                .map(WindowsOfficialLoginCookie.fromWebviewCookie)
                .toList();
        final String cookieHeader = buildBilibiliLoginCookieHeader(allCookies);
        cookieReadFailures = 0;
        if (!_containsBilibiliSessionCookie(cookieHeader)) {
          final DateTime? submittedAt = loginSubmitSucceededAt;
          if (loginSubmitSucceeded && submittedAt != null) {
            final bool landingTimedOut =
                DateTime.now().difference(submittedAt) >=
                _loginSessionLandingTimeout;
            if (landingTimedOut && !result.isCompleted) {
              unawaited(
                _recordLoginDiagnostic(
                  operation: 'windows_login_cookie_missing',
                  stage: 'official_redirect_no_session',
                  cookieCount: allCookies.length,
                ),
              );
              result.completeError(
                const WindowsOfficialLoginException(
                  'B站已接受本次登录并完成落地跳转，但 WebView2 仍没有生成可接管的会话；请关闭窗口后重试。',
                ),
              );
              webview.close();
            }
          }
          return;
        }
        final Completer<BilibiliSessionState> verification =
            Completer<BilibiliSessionState>();
        webview.setOnNavigationCompletedCallback((String url, bool isSuccess) {
          if (verification.isCompleted || !_isBilibiliAccountEndpoint(url)) {
            return;
          }
          if (!isSuccess) {
            verification.complete(
              const BilibiliSessionState.networkError(
                message: 'B站登录状态页面加载失败，请检查网络。',
              ),
            );
            return;
          }
          unawaited(() async {
            try {
              // 这里只读取官方 nav 页的 JSON 文本；不读取登录页表单、密码或验证码。
              final String? scriptResult = await webview.evaluateJavaScript(
                'document.body ? document.body.innerText : ""',
              );
              final BilibiliSessionState session = await _authService
                  .saveBrowserVerifiedSession(
                    responseText: _decodeWebviewScriptString(scriptResult),
                    rawCookie: cookieHeader,
                  );
              if (!verification.isCompleted) {
                verification.complete(session);
              }
            } catch (_) {
              if (!verification.isCompleted) {
                verification.complete(
                  const BilibiliSessionState.networkError(
                    message: '暂时无法读取网页登录状态，请稍后重试。',
                  ),
                );
              }
            }
          }());
        });
        await webview.launch(
          BilibiliHttpAuthApi.accountEndpoint.toString(),
          triggerOnUrlRequestEvent: false,
        );
        final BilibiliSessionState session = await verification.future.timeout(
          const Duration(seconds: 12),
        );
        if (session.isActive && !result.isCompleted) {
          result.complete(session.account);
          webview.close();
          return;
        }
        if (!result.isCompleted) {
          unawaited(
            _recordLoginDiagnostic(
              operation: 'windows_login_nav_rejected',
              stage: session.status.name,
              cookieCount: allCookies.length,
            ),
          );
          result.completeError(
            WindowsOfficialLoginException(
              session.status == BilibiliSessionStatus.networkError
                  ? (session.message ?? '无法向 B站确认登录状态，请检查网络后重试。')
                  : '网页登录已产生会话，但 B站账号接口未确认登录；请重新打开登录窗口。',
            ),
          );
          webview.close();
        }
      } on TimeoutException catch (_, stackTrace) {
        recordCookieReadFailure(stackTrace);
      } on PlatformException catch (_, stackTrace) {
        recordCookieReadFailure(stackTrace);
      } on BilibiliAuthException catch (error, stackTrace) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
          webview.close();
        }
      } catch (error, stackTrace) {
        if (!result.isCompleted) {
          result.completeError(
            const WindowsOfficialLoginException('无法读取官方登录状态，请关闭窗口后重试。'),
            stackTrace,
          );
          webview.close();
        }
      } finally {
        checking = false;
      }
    }

    // 把 QQ 精确主机交给 WebView2 同步校验，避免异步回调重放密码 POST 或成功重定向。
    await webview.setAllowedNavigationHosts(_allowedQqLoginHosts.toList());
    // Windows 与已经稳定工作的 Android 登录链保持一致：完整移动 UA 配合官方 H5 入口。
    await webview.setUserAgent(
      BilibiliRequestPolicy.fallbackMobileWebUserAgent,
    );
    // 注入脚本观察 code=0 并补齐官方 data.url 落地链，不读取提交正文与表单字段。
    await webview.addScriptToExecuteOnDocumentCreated(
      _loginSuccessObserverScript,
    );
    webview.addOnWebMessageReceivedCallback((String message) {
      if (message != _loginSubmitSuccessMessage) {
        return;
      }
      loginSubmitSucceeded = true;
      loginSubmitSucceededAt ??= DateTime.now();
      unawaited(checkSession());
    });
    // 与 Android onPageFinished 对齐：QQ 回跳或登录页跳转完成后立即检查，不必等下一个周期。
    webview.setOnNavigationCompletedCallback((String _, bool _) {
      unawaited(checkSession());
    });
    await webview.launch(buildWindowsOfficialLoginUri().toString());
    // 首屏命令发出后先检查一次，周期计时器继续覆盖不发生导航的手机号/密码 XHR 登录。
    unawaited(checkSession());
    checkTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      // 周期回调函数只请求会话快照，不输出 Cookie、账号或密码。
      unawaited(checkSession());
    });
    webview.onClose.whenComplete(() {
      // 窗口关闭函数把用户主动取消转换为空结果，并停止后续网络检查。
      checkTimer?.cancel();
      if (!result.isCompleted) {
        result.complete(null);
      }
    });
    try {
      return await result.future;
    } finally {
      checkTimer.cancel();
      bool windowClosed = false;
      try {
        // 原生层正常会立即通知关闭；设置上限可避免极端插件异常让已验证账号永远无法返回主页面。
        await webview.onClose.timeout(const Duration(seconds: 3));
        windowClosed = true;
      } catch (_) {
        // 关闭通知超时不改变已验证账号结果，也不输出 Cookie 或本机路径。
      }
      if (windowClosed) {
        try {
          await WebviewWindow.clearAll(userDataFolderWindows: profileDirectory);
        } catch (_) {
          // 临时登录容器清理失败不改变已验证账号结果，也不输出 Cookie 或本机路径。
        }
      }
    }
  }

  /// 写入一条只含阶段名和 Cookie 数量的本机诊断，不保存任何会话值或登录输入。
  Future<void> _recordLoginDiagnostic({
    required String operation,
    required String stage,
    required int cookieCount,
  }) {
    return _diagnosticsService.record(
      ProblemDiagnosticEntry(
        occurredAt: DateTime.now(),
        category: 'network',
        operation: operation,
        description: 'Windows B站网页登录会话接管阶段记录。',
        additionalInfo: <String, String>{
          'stage': stage,
          'cookie_count': cookieCount.toString(),
        },
      ),
    );
  }
}

/// 解码 WebView2 ExecuteScript 返回的 JSON 字符串包装，失败时交给账号解析器统一处理。
String _decodeWebviewScriptString(String? scriptResult) {
  if (scriptResult == null || scriptResult.trim().isEmpty) {
    return '';
  }
  final Object? decoded = jsonDecode(scriptResult);
  return decoded is String ? decoded : '';
}

/// 判断导航完成地址是否仍是官方账号接口，允许服务端附加无害查询参数。
bool _isBilibiliAccountEndpoint(String url) {
  final Uri? uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == BilibiliHttpAuthApi.accountEndpoint.scheme &&
      uri.host == BilibiliHttpAuthApi.accountEndpoint.host &&
      uri.path == BilibiliHttpAuthApi.accountEndpoint.path;
}

/// 判断 Cookie 请求头是否包含当前 B站常用登录会话，仅用于候选排序而不作为成功依据。
bool _containsBilibiliSessionCookie(String cookieHeader) {
  return RegExp(
    r'(^|;\s*)SESSDATA=([^;]+)',
    caseSensitive: false,
  ).hasMatch(cookieHeader);
}

/// 表示 Windows 官方登录窗口无法启动或读取状态，消息中绝不包含敏感原文。
class WindowsOfficialLoginException implements Exception {
  /// 创建可直接展示给用户的安全错误说明。
  const WindowsOfficialLoginException(this.message);

  final String message;

  /// 返回不含 Cookie、密码或网页地址的简短错误文本。
  @override
  String toString() => message;
}
