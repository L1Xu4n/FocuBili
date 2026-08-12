import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../platform/app_platform.dart';
import '../../platform/platform_capabilities.dart';
import '../../platform/platform_services.dart';
import '../../services/bilibili_auth_service.dart';
import '../../services/bilibili_qr_login_service.dart';
import '../../services/bilibili_request_policy.dart';

/// 标识登录首页提供的手机号、密码和 Cookie 三种入口。
enum _LoginMode { phone, password, cookie }

/// 提供登录方式选择，并把账号密码与验证码交给 B 站官方页面处理。
class LoginPage extends StatefulWidget {
  /// 创建登录页面；测试可注入平台，账号切换时可自动打开官方登录。
  const LoginPage({
    super.key,
    this.openOfficialLoginOnStart = false,
    this.platformServices,
  });

  /// 表示此页是否由“切换账号”打开，并应优先进入 B 站官方网页登录。
  final bool openOfficialLoginOnStart;

  final PlatformServices? platformServices;

  /// 创建保存登录方式、Cookie 输入和提交状态的页面状态。
  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 管理登录方式切换、Cookie 验证和官方网页登录结果。
class _LoginPageState extends State<LoginPage> {
  final BilibiliAuthService _authService = BilibiliAuthService();
  final TextEditingController _cookieController = TextEditingController();
  _LoginMode _mode = _LoginMode.phone;
  bool _submitting = false;
  bool _obscureCookie = true;
  bool _openedOfficialLoginOnStart = false;
  String? _errorMessage;

  /// 返回注入的平台装配器或进程共享的真实平台装配器。
  PlatformServices get _platformServices =>
      widget.platformServices ?? PlatformServices.current;

  /// 读取当前平台已经实现的登录体验。
  LoginExperience get _loginExperience =>
      _platformServices.capabilities.loginExperience;

  /// 判断当前是否应使用不依赖 WebView 的官方扫码登录。
  bool get _usesQrLogin => _loginExperience == LoginExperience.officialQrCode;

  /// 判断当前平台是否还没有安全可用的登录实现。
  bool get _loginUnavailable => _loginExperience == LoginExperience.unavailable;

  /// 首帧完成后根据账号切换入口打开官方登录页，避免在构建期间重复导航。
  @override
  void initState() {
    super.initState();
    if (!widget.openOfficialLoginOnStart || _loginUnavailable) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _openedOfficialLoginOnStart) {
        return;
      }
      _openedOfficialLoginOnStart = true;
      // 自动打开函数只进入官方网页，不会读取密码、验证码或 Cookie 原文。
      unawaited(_openOfficialLogin());
    });
  }

  /// 释放 Cookie 输入控制器，避免关闭页面后继续占用输入资源。
  @override
  void dispose() {
    _cookieController.dispose();
    super.dispose();
  }

  /// 响应分段按钮选择，并清除上一种登录方式留下的错误提示。
  void _selectMode(Set<_LoginMode> values) {
    if (values.isEmpty) {
      return;
    }
    setState(() {
      _mode = values.first;
      _errorMessage = null;
    });
  }

  /// 打开 B 站官方登录页，成功抓取会话后把账号信息返回“我的”页面。
  Future<void> _openOfficialLogin() async {
    if (_loginUnavailable) {
      return;
    }
    final BilibiliAccount? account = await Navigator.of(context).push(
      MaterialPageRoute<BilibiliAccount>(
        // Windows 使用官方扫码接口，Android 继续创建隔离的 WebView 登录页面。
        builder: (BuildContext context) => _usesQrLogin
            ? const _OfficialQrLoginPage()
            : const _OfficialWebLoginPage(),
      ),
    );
    if (!mounted || account == null) {
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(account);
  }

  /// 验证用户主动粘贴的 Cookie，成功后返回账号信息且不在 Flutter 中持久化原文。
  Future<void> _loginWithCookie() async {
    if (_loginUnavailable) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final BilibiliAccount account = await _authService.loginWithCookie(
        _cookieController.text,
      );
      if (mounted) {
        Navigator.of(context).pop(account);
      }
    } on BilibiliAuthException catch (error) {
      _showLoginError(error.message);
    } catch (_) {
      _showLoginError('Cookie 登录失败，请检查内容或网络后重试。');
    }
  }

  /// 切换 Cookie 输入的遮挡状态，默认隐藏敏感会话内容。
  void _toggleCookieVisibility() {
    setState(() => _obscureCookie = !_obscureCookie);
  }

  /// 在页面仍存在时结束提交状态并显示不包含敏感内容的登录错误。
  void _showLoginError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _submitting = false;
      _errorMessage = message;
    });
  }

  /// 按当前选项创建手机号、密码说明入口或 Cookie 输入表单。
  Widget _buildSelectedMode() {
    if (_mode == _LoginMode.cookie) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            _usesQrLogin
                ? '仅粘贴你自己账号的 Cookie。内容只写入 Windows 加密凭据存储。'
                : '仅粘贴你自己账号的 Cookie。内容只写入本应用的 WebView 会话容器。',
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _cookieController,
            obscureText: _obscureCookie,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'B 站 Cookie',
              hintText: '需要包含 SESSDATA',
              suffixIcon: IconButton(
                // Cookie 可见按钮函数只改变本地输入显示方式。
                onPressed: _toggleCookieVisibility,
                icon: Icon(
                  _obscureCookie
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                tooltip: _obscureCookie ? '显示 Cookie' : '隐藏 Cookie',
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            // Cookie 登录按钮函数验证会话后返回账号资料。
            onPressed: _submitting ? null : _loginWithCookie,
            child: Text(_submitting ? '正在验证…' : '使用 Cookie 登录'),
          ),
        ],
      );
    }
    if (_usesQrLogin) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('使用手机 B 站 App 扫描官方二维码并确认。FocuBili 不会接触账号密码。'),
          const SizedBox(height: 14),
          FilledButton.icon(
            // Windows 扫码按钮函数打开官方二维码并在确认后安全保存会话。
            onPressed: _openOfficialLogin,
            icon: const Icon(Icons.qr_code_2_rounded),
            label: const Text('打开 B 站扫码登录'),
          ),
        ],
      );
    }
    final bool phoneMode = _mode == _LoginMode.phone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          phoneMode
              ? '手机号登录为默认入口。短信、人机验证和账号信息都在 B 站官方页面中填写。'
              : '密码不会交给 FocuBili。账号、密码和人机验证都由 B 站官方页面直接处理。',
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          // 官方登录按钮函数打开支持手机号、密码和验证码的 B 站页面。
          onPressed: _openOfficialLogin,
          icon: Icon(
            phoneMode ? Icons.phone_android_rounded : Icons.password_rounded,
          ),
          label: Text(phoneMode ? '进入官方手机号登录' : '进入官方密码登录'),
        ),
      ],
    );
  }

  /// 根据平台创建登录方式选项；Windows 只展示扫码与 Cookie，避免出现不可用的桌面 WebView 密码入口。
  List<ButtonSegment<_LoginMode>> _buildLoginSegments() {
    if (_usesQrLogin) {
      return const <ButtonSegment<_LoginMode>>[
        ButtonSegment<_LoginMode>(
          value: _LoginMode.phone,
          icon: Icon(Icons.qr_code_2_rounded),
          label: Text('扫码'),
        ),
        ButtonSegment<_LoginMode>(
          value: _LoginMode.cookie,
          icon: Icon(Icons.cookie_outlined),
          label: Text('Cookie'),
        ),
      ];
    }
    return const <ButtonSegment<_LoginMode>>[
      ButtonSegment<_LoginMode>(
        value: _LoginMode.phone,
        icon: Icon(Icons.phone_android_rounded),
        label: Text('手机号'),
      ),
      ButtonSegment<_LoginMode>(
        value: _LoginMode.password,
        icon: Icon(Icons.password_rounded),
        label: Text('密码'),
      ),
      ButtonSegment<_LoginMode>(
        value: _LoginMode.cookie,
        icon: Icon(Icons.cookie_outlined),
        label: Text('Cookie'),
      ),
    ];
  }

  /// 为尚未接入登录与安全存储的平台创建不会触发网络或原生插件的说明页。
  Widget _buildUnavailableLogin() {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 B 站账号')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.no_accounts_outlined, size: 48),
              const SizedBox(height: 16),
              Text(
                '${_platformServices.platform.displayName} 暂不支持账号登录',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                '安全登录和 Cookie 存储接入完成后，这里才会开放登录入口。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建登录方式选择、隐私说明和当前登录表单。
  @override
  Widget build(BuildContext context) {
    if (_loginUnavailable) {
      return _buildUnavailableLogin();
    }
    return Scaffold(
      appBar: AppBar(title: const Text('登录 B 站账号')),
      body: AdaptivePageFrame(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            SegmentedButton<_LoginMode>(
              segments: _buildLoginSegments(),
              selected: <_LoginMode>{_mode},
              // 登录方式选择函数切换当前表单但不自动提交任何数据。
              onSelectionChanged: _selectMode,
            ),
            const SizedBox(height: 24),
            _buildSelectedMode(),
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            const Divider(),
            if (_mode == _LoginMode.cookie) ...<Widget>[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                // Cookie 模式的备用官方入口函数按平台打开扫码或 B 站完整网页流程。
                onPressed: _openOfficialLogin,
                icon: Icon(
                  _usesQrLogin
                      ? Icons.qr_code_2_rounded
                      : Icons.language_rounded,
                ),
                label: Text(_usesQrLogin ? '打开 B 站扫码登录' : '打开 B 站网页登录'),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              _usesQrLogin
                  ? '说明：扫码由 B 站官方接口完成；确认后的会话通过 Windows 加密存储保护。'
                  : '说明：当前原生手机号/密码接口尚未直接接入；这样可以避免 App 接触密码，并确保验证码由官方页面完成。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// 在 Windows 中展示 B 站官方扫码二维码，并在手机确认后验证和保存账号会话。
class _OfficialQrLoginPage extends StatefulWidget {
  /// 创建不接触账号密码的 Windows 扫码登录页面。
  const _OfficialQrLoginPage();

  /// 创建二维码会话、轮询计时器和状态文字。
  @override
  State<_OfficialQrLoginPage> createState() => _OfficialQrLoginPageState();
}

/// 管理二维码生成、两秒轮询、过期刷新和登录成功返回。
class _OfficialQrLoginPageState extends State<_OfficialQrLoginPage> {
  final BilibiliQrLoginService _qrService = BilibiliQrLoginService();
  final BilibiliAuthService _authService = BilibiliAuthService();
  BilibiliQrLoginSession? _session;
  Timer? _pollTimer;
  bool _loading = true;
  bool _polling = false;
  bool _expired = false;
  String _statusMessage = '正在生成官方登录二维码…';

  /// 首次进入页面时立即生成二维码。
  @override
  void initState() {
    super.initState();
    unawaited(_refreshQrCode());
  }

  /// 停止轮询计时器，避免页面关闭后继续访问网络。
  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// 请求新二维码并启动固定两秒轮询；失败时保留可重试按钮。
  Future<void> _refreshQrCode() async {
    _pollTimer?.cancel();
    setState(() {
      _loading = true;
      _expired = false;
      _session = null;
      _statusMessage = '正在生成官方登录二维码…';
    });
    try {
      final BilibiliQrLoginSession session = await _qrService.generate();
      if (!mounted) {
        return;
      }
      setState(() {
        _session = session;
        _loading = false;
        _statusMessage = '请使用手机 B 站 App 扫描二维码。';
      });
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_pollLoginState());
      });
      unawaited(_pollLoginState());
    } on BilibiliQrLoginException catch (error) {
      _showFailure(error.message);
    } catch (_) {
      _showFailure('暂时无法生成二维码，请检查网络后重试。');
    }
  }

  /// 轮询一次扫码状态；确认成功后再调用账号接口验证 Cookie 并写入加密存储。
  Future<void> _pollLoginState() async {
    final BilibiliQrLoginSession? session = _session;
    if (_polling || session == null || _expired) {
      return;
    }
    _polling = true;
    try {
      final BilibiliQrLoginPollResult result = await _qrService.poll(
        session.key,
      );
      if (!mounted || _session?.key != session.key) {
        return;
      }
      if (result.status == BilibiliQrLoginStatus.expired) {
        _pollTimer?.cancel();
        setState(() {
          _expired = true;
          _statusMessage = result.message;
        });
        return;
      }
      setState(() => _statusMessage = result.message);
      if (result.status != BilibiliQrLoginStatus.confirmed) {
        return;
      }
      _pollTimer?.cancel();
      final BilibiliAccount account = await _authService.loginWithCookie(
        result.cookieHeader,
      );
      if (mounted) {
        Navigator.of(context).pop(account);
      }
    } on BilibiliAuthException catch (error) {
      _showFailure(error.message);
    } on BilibiliQrLoginException catch (error) {
      _showFailure(error.message);
    } catch (_) {
      _showFailure('扫码登录暂时失败，请刷新二维码后重试。');
    } finally {
      _polling = false;
    }
  }

  /// 停止当前轮询并展示不包含 Cookie 或二维码密钥的错误说明。
  void _showFailure(String message) {
    if (!mounted) {
      return;
    }
    _pollTimer?.cancel();
    setState(() {
      _loading = false;
      _expired = true;
      _statusMessage = message;
    });
  }

  /// 创建二维码、当前状态和手动刷新入口，并限制内容宽度适配桌面窗口。
  @override
  Widget build(BuildContext context) {
    final BilibiliQrLoginSession? session = _session;
    return Scaffold(
      appBar: AppBar(title: const Text('B 站扫码登录')),
      body: AdaptivePageFrame(
        maxWidth: 620,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '使用手机 B 站 App 扫码',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 20),
                    SizedBox.square(
                      dimension: 260,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: session == null
                              ? Center(
                                  child: _loading
                                      ? const CircularProgressIndicator()
                                      : const Icon(
                                          Icons.qr_code_2_rounded,
                                          size: 96,
                                          color: Colors.black26,
                                        ),
                                )
                              : QrImageView(
                                  key: const Key('bilibili-login-qr-code'),
                                  data: session.url,
                                  version: QrVersions.auto,
                                  backgroundColor: Colors.white,
                                  eyeStyle: const QrEyeStyle(
                                    eyeShape: QrEyeShape.square,
                                    color: Colors.black,
                                  ),
                                  dataModuleStyle: const QrDataModuleStyle(
                                    dataModuleShape: QrDataModuleShape.square,
                                    color: Colors.black,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _expired
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (_expired)
                      FilledButton.icon(
                        // 刷新按钮函数废弃旧键并生成全新的官方二维码。
                        onPressed: _loading ? null : _refreshQrCode,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('刷新二维码'),
                      ),
                    const SizedBox(height: 14),
                    const Text(
                      '二维码和确认均由 B 站官方接口处理；FocuBili 不会读取你的密码或验证码。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 承载 B 站官方登录网页，并定时检测 WebView Cookie 是否已形成有效会话。
class _OfficialWebLoginPage extends StatefulWidget {
  /// 创建只访问 B 站官方登录地址的 WebView 页面。
  const _OfficialWebLoginPage();

  /// 创建网页控制器、检测计时器和登录提示状态。
  @override
  State<_OfficialWebLoginPage> createState() => _OfficialWebLoginPageState();
}

/// 管理官方网页加载、非网页协议拦截和登录成功后的自动返回。
class _OfficialWebLoginPageState extends State<_OfficialWebLoginPage> {
  final BilibiliAuthService _authService = BilibiliAuthService();
  late final WebViewController _webController;
  Timer? _loginCheckTimer;
  bool _checking = false;
  bool _loginCompleted = false;
  String? _statusMessage;

  /// 创建 WebView、启用官方验证码所需的 JavaScript，并启动会话自动检测。
  @override
  void initState() {
    super.initState();
    _webController = WebViewController();
    unawaited(_configureWebController());
  }

  /// 按顺序设置移动端 UA、网页权限和导航规则，再加载 B 站官方登录地址。
  Future<void> _configureWebController() async {
    await _webController.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _webController.setBackgroundColor(Colors.white);
    String? defaultUserAgent;
    try {
      defaultUserAgent = await _webController.platform.getUserAgent();
    } catch (_) {
      // 平台未提供 UA 读取能力时使用固定移动端回退值，登录页仍可继续加载。
    }
    await _webController.setUserAgent(
      BilibiliRequestPolicy.ensureMobileWebUserAgent(defaultUserAgent),
    );
    await _webController.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: _handleNavigationRequest,
        onPageFinished: _handlePageFinished,
        onWebResourceError: _handleWebResourceError,
      ),
    );
    if (!mounted) {
      return;
    }
    await _webController.loadRequest(
      BilibiliRequestPolicy.officialMobileLoginUri,
    );
    if (!mounted) {
      return;
    }
    _startLoginCheckTimer();
  }

  /// 每两秒检查一次官方网页产生的会话，以便登录后无需额外点击确认。
  void _startLoginCheckTimer() {
    _loginCheckTimer?.cancel();
    _loginCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      // 定时检测函数读取会话但不会输出 Cookie 内容。
      unawaited(_checkLoginState());
    });
  }

  /// 仅允许 WebView 导航到 HTTP(S) 页面，阻止网页唤起外部 App 协议。
  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final Uri? uri = Uri.tryParse(request.url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  /// 网页完成加载后立即补做一次登录检测，缩短成功后的等待时间。
  void _handlePageFinished(String url) {
    unawaited(_checkLoginState());
  }

  /// 网页资源失败时展示轻量说明，验证码子资源失败仍允许用户刷新重试。
  void _handleWebResourceError(WebResourceError error) {
    if (mounted && error.isForMainFrame == true) {
      setState(() => _statusMessage = '登录页面加载失败，请检查网络后重试。');
    }
  }

  /// 读取并验证 WebView 会话，成功后自动把账号信息返回上一页。
  Future<void> _checkLoginState() async {
    if (_checking || _loginCompleted || !mounted) {
      return;
    }
    _checking = true;
    try {
      final BilibiliSessionState session = await _authService
          .loadCurrentSession();
      if (mounted && session.isActive) {
        await _completeOfficialLogin(session.account!);
      } else if (mounted &&
          session.status == BilibiliSessionStatus.networkError) {
        setState(() {
          _statusMessage = session.message ?? '暂时无法读取登录状态，请稍后重试。';
        });
      }
    } finally {
      _checking = false;
    }
  }

  /// 先撤下原生 WebView 并显示成功画面，再延迟返回，避免连续关闭两层页面造成黑屏。
  Future<void> _completeOfficialLogin(BilibiliAccount account) async {
    if (_loginCompleted || !mounted) {
      return;
    }
    _loginCompleted = true;
    _loginCheckTimer?.cancel();
    setState(() => _statusMessage = '登录成功，正在返回…');
    await _webController.loadHtmlString(
      '<!doctype html><html><body style="margin:0;background:#fff"></body></html>',
    );
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (mounted) {
      Navigator.of(context).pop(account);
    }
  }

  /// 取消轮询计时器，避免离开网页后继续读取登录状态。
  @override
  void dispose() {
    _loginCheckTimer?.cancel();
    super.dispose();
  }

  /// 创建官方登录 WebView、状态提示和手动检测按钮。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('B 站官方登录'),
        actions: <Widget>[
          IconButton(
            // 登录检测按钮函数允许网络较慢时由用户立即重新检查会话。
            onPressed: _checkLoginState,
            icon: const Icon(Icons.verified_user_outlined),
            tooltip: '检测登录状态',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_statusMessage != null)
            MaterialBanner(
              content: Text(_statusMessage!),
              actions: <Widget>[
                TextButton(
                  // 状态关闭按钮函数只清除当前提示，不影响网页登录进度。
                  onPressed: () => setState(() => _statusMessage = null),
                  child: const Text('关闭'),
                ),
              ],
            ),
          Expanded(child: WebViewWidget(controller: _webController)),
        ],
      ),
    );
  }
}
