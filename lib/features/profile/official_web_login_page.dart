import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../../services/bilibili_auth_service.dart';
import '../../services/bilibili_request_policy.dart';
import '../../services/problem_diagnostics_service.dart';
import '../../services/webview_environment_service.dart';

/// 承载官方网页登录，独立管理旧设备兼容、加载反馈和会话检查。
class OfficialWebLoginPage extends StatefulWidget {
  /// 创建只访问官方登录地址的网页登录页。
  const OfficialWebLoginPage({super.key});

  /// 创建网页与加载状态的生命周期管理对象。
  @override
  State<OfficialWebLoginPage> createState() => _OfficialWebLoginPageState();
}

class _OfficialWebLoginPageState extends State<OfficialWebLoginPage>
    with WidgetsBindingObserver {
  final _authService = BilibiliAuthService();
  final _diagnostics = ProblemDiagnosticsService();
  WebViewController? _controller;
  Timer? _loginTimer, _loadingTimer;
  bool _checking = false, _completed = false, _initializing = true;
  bool _hybridComposition = false, _webViewVisible = true;
  bool _foreground = true;
  bool _creatingController = false;
  bool _captchaResourceFailed = false;
  bool _captchaHelpOpen = false;
  static const _bridgeTimeout = Duration(seconds: 12);
  int _progress = 0;
  String? _status;

  /// 先显示 Flutter 页面，再初始化原生内核，避免转场与内核加载同时发生。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_initialize()),
    );
  }

  /// 查询内核、选择兼容渲染并按顺序配置官方网页；失败保留可重试页面。
  Future<void> _initialize() async {
    if (!mounted || _creatingController) return;
    _creatingController = true;
    setState(() {
      _initializing = true;
      _status = null;
    });
    _startLoadingDeadline();
    try {
      final environment = await const WebViewEnvironmentService().load();
      if (!mounted) return;
      if (environment.providerAvailable == false) {
        throw StateError('no_webview_provider');
      }
      _hybridComposition = environment.prefersHybridComposition;
      final controller = WebViewController();
      _controller = controller;
      await controller
          .setJavaScriptMode(JavaScriptMode.unrestricted)
          .timeout(_bridgeTimeout);
      await controller.setBackgroundColor(Colors.white).timeout(_bridgeTimeout);
      await _configureCaptchaCookies(controller).timeout(_bridgeTimeout);
      String? userAgent;
      try {
        userAgent = await controller.platform.getUserAgent().timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {
        /* 保留移动端 UA 回退。 */
      }
      await controller
          .setUserAgent(
            BilibiliRequestPolicy.ensureMobileWebUserAgent(userAgent),
          )
          .timeout(_bridgeTimeout);
      await controller
          .setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: _handleNavigation,
              onPageStarted: _handlePageStarted,
              onProgress: _handleProgress,
              onPageFinished: _handlePageFinished,
              onWebResourceError: _handleResourceError,
            ),
          )
          .timeout(_bridgeTimeout);
      if (!mounted) return;
      setState(() => _initializing = false);
      await controller
          .loadRequest(BilibiliRequestPolicy.officialMobileLoginUri)
          .timeout(_bridgeTimeout);
    } catch (_) {
      _loadingTimer?.cancel();
      _recordFailure('webview_initialize');
      if (mounted) {
        setState(() {
          _initializing = false;
          _controller = null;
          _status = '登录网页无法打开。请重试，或在问题诊断中获取 WebView 信息。';
        });
      }
    } finally {
      _creatingController = false;
    }
  }

  /// 仅为当前 Android 登录视图启用跨站 Cookie，让第三方验证服务保存自己的会话。
  Future<void> _configureCaptchaCookies(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is! AndroidWebViewController) return;
    final cookieManager = WebViewCookieManager().platform;
    if (cookieManager is AndroidWebViewCookieManager) {
      await cookieManager.setAcceptThirdPartyCookies(platform, true);
    }
  }

  /// 加载超过 25 秒时提供重试和兼容切换，网页仍可继续完成加载。
  void _startLoadingDeadline() {
    _loadingTimer?.cancel();
    _loadingTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted || _completed) return;
      _recordFailure('webview_load_timeout');
      setState(() => _status = '加载时间较长，可以重试或切换兼容显示。');
    });
  }

  /// 网页开始跳转时暂停轮询，让加载优先使用设备资源。
  void _handlePageStarted(String url) {
    _loginTimer?.cancel();
    _captchaResourceFailed = false;
    _startLoadingDeadline();
    if (mounted) {
      setState(() {
        _progress = 0;
        _status = null;
      });
    }
  }

  /// 更新真实网页加载进度，避免白屏时没有反馈。
  void _handleProgress(int value) {
    if (mounted && !_completed) setState(() => _progress = value);
  }

  /// 首次完成网页后才检测会话，并以五秒间隔启动后续检测。
  void _handlePageFinished(String url) {
    _loadingTimer?.cancel();
    if (!mounted || _completed) return;
    setState(() {
      _progress = 100;
      if (!_captchaResourceFailed) _status = null;
    });
    unawaited(_checkLogin());
    _loginTimer?.cancel();
    _loginTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_foreground) unawaited(_checkLogin());
    });
  }

  /// 只允许 HTTP(S) 导航，阻止网页通过外部协议唤起其他应用。
  NavigationDecision _handleNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http')
        ? NavigationDecision.navigate
        : NavigationDecision.prevent;
  }

  /// 分别提示主网页和已知验证服务的加载错误，每次加载最多记录一次验证错误。
  void _handleResourceError(WebResourceError error) {
    if (!mounted || _completed) return;
    if (error.isForMainFrame == true) {
      _loadingTimer?.cancel();
      _recordFailure('webview_main_frame', error.errorCode);
      setState(() => _status = '登录页面加载失败，请重试或切换兼容显示。');
    } else if (!_captchaResourceFailed &&
        BilibiliRequestPolicy.isCaptchaResourceUrl(error.url)) {
      _captchaResourceFailed = true;
      _recordFailure('webview_captcha_resource', error.errorCode);
      setState(() => _status = '人机验证资源加载失败。请切换网络后重试，或返回使用扫码登录。');
    }
  }

  /// 为网页内部一直检测、未触发主页面超时的情况提供重载和返回扫码入口。
  Future<void> _showCaptchaHelp() async {
    if (_completed || _captchaHelpOpen) return;
    _captchaHelpOpen = true;
    bool? reload;
    try {
      reload = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('人机验证一直加载'),
          scrollable: true,
          content: const Text(
            '若一直停在“智能验证检测中”，可以切换网络后重新加载。'
            '重新加载后需要重新填写手机号。\n\n'
            '也可以返回选择扫码登录，用另一台已登录 B 站的手机扫码确认。'
            '若仍需排查，请在“问题诊断”中复制报告，其中包含系统 WebView 版本。',
          ),
          actions: <Widget>[
            TextButton(
              // 返回选择页，不改变账号或清除现有登录 Cookie。
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('返回选择扫码登录'),
            ),
            FilledButton(
              // 关闭说明后由本页重新加载官方登录地址。
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    } finally {
      _captchaHelpOpen = false;
    }
    if (!mounted || _completed || reload == null) return;
    if (reload) {
      await _reload();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// 检测官方会话；帮助对话框打开时暂缓完成导航，避免把账号结果误返回给对话框。
  Future<void> _checkLogin({bool force = false}) async {
    if (_checking || _completed || _captchaHelpOpen || !mounted) return;
    _checking = true;
    try {
      final session = await _authService.loadCurrentSessionForWebLogin(
        force: force,
      );
      if (!mounted || _completed || _captchaHelpOpen) return;
      if (session.isActive) {
        await _completeLogin(session.account!);
      } else if (session.status == BilibiliSessionStatus.networkError) {
        setState(() => _status = session.message);
      }
    } catch (_) {
      if (mounted) setState(() => _status = '暂时无法确认登录，请稍后重试。');
    } finally {
      _checking = false;
    }
  }

  /// 撤下原生 WebView 后延迟返回，避免旧设备连续关闭原生视图时黑屏。
  Future<void> _completeLogin(BilibiliAccount account) async {
    _completed = true;
    _loginTimer?.cancel();
    _loadingTimer?.cancel();
    setState(() {
      _webViewVisible = false;
      _status = '登录成功，正在返回…';
    });
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (mounted) Navigator.of(context).pop(account);
  }

  /// 重新加载官方网页；控制器初始化失败时重新创建内核对象。
  Future<void> _reload() async {
    if (_completed || _creatingController) return;
    final controller = _controller;
    if (controller == null) {
      await _initialize();
      return;
    }
    setState(() {
      _status = null;
      _progress = 0;
    });
    _startLoadingDeadline();
    try {
      await controller
          .loadRequest(BilibiliRequestPolicy.officialMobileLoginUri)
          .timeout(_bridgeTimeout);
    } catch (_) {
      if (mounted) setState(() => _status = '重新加载失败，请稍后重试。');
    }
  }

  /// 先卸载视图再切换 Android 合成方式，保留网页会话和当前控制器。
  Future<void> _switchComposition() async {
    if (_completed || _controller == null) return;
    setState(() => _webViewVisible = false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() {
      _hybridComposition = !_hybridComposition;
      _webViewVisible = true;
      _status = _hybridComposition ? '已切换为兼容显示。' : '已切换为默认显示。';
    });
  }

  /// 仅记录固定操作名、渲染模式与错误码，不记录网页地址或服务端正文。
  void _recordFailure(String operation, [int? code]) {
    unawaited(
      _diagnostics.record(
        ProblemDiagnosticEntry(
          occurredAt: DateTime.now(),
          category: 'network',
          operation: operation,
          errorCode: code,
          description: '官方登录 WebView 加载异常。',
          additionalInfo: {
            'composition': _hybridComposition ? 'hybrid' : 'texture',
          },
        ),
      ),
    );
  }

  /// 后台期间暂停检测，恢复前台时补做一次检测。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && _progress == 100) unawaited(_checkLogin());
  }

  /// 取消加载和会话计时器，并解除生命周期监听。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loginTimer?.cancel();
    _loadingTimer?.cancel();
    super.dispose();
  }

  /// 构建指定合成模式的 Android WebView，其他平台使用插件默认模式。
  Widget _buildWebView(WebViewController controller) {
    if (controller.platform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          key: ValueKey(_hybridComposition),
          controller: controller.platform,
          displayWithHybridComposition: _hybridComposition,
        ),
      );
    }
    return WebViewWidget(controller: controller);
  }

  /// 显示网页、真实进度、兼容显示及网页验证卡住时仍可操作的帮助入口。
  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('B 站官方登录'),
        actions: <Widget>[
          IconButton(
            onPressed: _initializing || _completed ? null : _reload,
            tooltip: '重新加载登录页',
            icon: const Icon(Icons.refresh),
          ),
          if (controller?.platform is AndroidWebViewController)
            IconButton(
              onPressed: _completed ? null : _switchComposition,
              tooltip: '切换兼容显示',
              icon: Icon(
                _hybridComposition ? Icons.layers : Icons.layers_outlined,
              ),
            ),
          IconButton(
            onPressed: _completed ? null : () => _checkLogin(force: true),
            tooltip: '检测登录状态',
            icon: const Icon(Icons.verified_user_outlined),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_initializing || (controller != null && _progress < 100))
            LinearProgressIndicator(
              value: _initializing || _progress == 0 ? null : _progress / 100,
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: <Widget>[
                  Text(_status!),
                  if (!_completed)
                    TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            ),
          Expanded(
            child: controller != null && _webViewVisible && !_initializing
                ? _buildWebView(controller)
                : Center(
                    child: Text(
                      _completed
                          ? '登录成功'
                          : _initializing
                          ? '正在准备登录网页…'
                          : '登录网页暂时不可用',
                    ),
                  ),
          ),
          if (!_completed)
            SafeArea(
              top: false,
              child: TextButton.icon(
                onPressed: _showCaptchaHelp,
                icon: const Icon(Icons.help_outline),
                label: const Text('验证码一直加载？'),
              ),
            ),
        ],
      ),
    );
  }
}
