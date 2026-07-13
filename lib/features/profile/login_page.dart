import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/bilibili_auth_service.dart';

/// 标识登录首页提供的手机号、密码和 Cookie 三种入口。
enum _LoginMode { phone, password, cookie }

/// 提供登录方式选择，并把账号密码与验证码交给 B 站官方页面处理。
class LoginPage extends StatefulWidget {
  /// 创建登录页面；账号切换时可在首帧后直接打开官方网页登录。
  const LoginPage({
    super.key,
    this.openOfficialLoginOnStart = false,
  });

  /// 表示此页是否由“切换账号”打开，并应优先进入 B 站官方网页登录。
  final bool openOfficialLoginOnStart;

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

  /// 首帧完成后根据账号切换入口打开官方登录页，避免在构建期间重复导航。
  @override
  void initState() {
    super.initState();
    if (!widget.openOfficialLoginOnStart) {
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
    final BilibiliAccount? account = await Navigator.of(context).push(
      MaterialPageRoute<BilibiliAccount>(
        // 官方网页登录构建函数创建隔离的 WebView 登录页面。
        builder: (BuildContext context) => const _OfficialWebLoginPage(),
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
          const Text(
            '仅粘贴你自己账号的 Cookie。内容只写入本应用的 WebView 会话容器。',
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

  /// 创建登录方式选择、隐私说明和当前登录表单。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 B 站账号')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          SegmentedButton<_LoginMode>(
            segments: const <ButtonSegment<_LoginMode>>[
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
            ],
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
          const SizedBox(height: 12),
          OutlinedButton.icon(
            // 网页登录入口函数允许用户直接使用 B 站完整官方登录流程。
            onPressed: _openOfficialLogin,
            icon: const Icon(Icons.language_rounded),
            label: const Text('打开 B 站网页登录'),
          ),
          const SizedBox(height: 10),
          const Text(
            '说明：当前原生手机号/密码接口尚未直接接入；这样可以避免 App 接触密码，并确保验证码由官方页面完成。',
            style: TextStyle(fontSize: 12),
          ),
        ],
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
  static final Uri _officialLoginUri = Uri.parse(
    'https://passport.bilibili.com/login',
  );
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
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onPageFinished: _handlePageFinished,
          onWebResourceError: _handleWebResourceError,
        ),
      )
      ..loadRequest(_officialLoginUri);
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
      final BilibiliSessionState session =
          await _authService.loadCurrentSession();
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
