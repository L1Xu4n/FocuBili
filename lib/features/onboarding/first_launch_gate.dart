import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/router/app_router.dart';
import '../../services/first_launch_service.dart';
import 'user_agreement_page.dart';

typedef ApplicationExit = Future<void> Function();
typedef LoginPageLauncher = Future<void> Function(BuildContext context);

/// 在首次安装时阻止进入主页，直到用户明确同意当前使用协议。
class FirstLaunchGate extends StatefulWidget {
  /// 创建首次启动门禁；测试可替换存储、退出和登录导航实现。
  const FirstLaunchGate({
    super.key,
    required this.child,
    this.service,
    this.exitApplication,
    this.openLoginPage,
  });

  final Widget child;
  final FirstLaunchService? service;
  final ApplicationExit? exitApplication;
  final LoginPageLauncher? openLoginPage;

  /// 创建读取协议状态、管理倒计时和登录引导的门禁状态。
  @override
  State<FirstLaunchGate> createState() => _FirstLaunchGateState();
}

/// 管理协议读取、十秒倒计时、同意写入和一次性登录引导。
class _FirstLaunchGateState extends State<FirstLaunchGate> {
  static const int _unlockDelaySeconds = 10;

  late final FirstLaunchService _service;
  Timer? _unlockTimer;
  bool _loading = true;
  bool _agreementAccepted = false;
  bool _loginGuideShown = false;
  bool _loginGuideScheduled = false;
  bool _accepting = false;
  bool _exiting = false;
  int _secondsRemaining = _unlockDelaySeconds;

  /// 初始化本机首次启动服务，并异步读取之前保存的状态。
  @override
  void initState() {
    super.initState();
    _service = widget.service ?? FirstLaunchService();
    unawaited(_loadState());
  }

  /// 读取协议和登录引导状态，再决定显示协议页还是直接进入主页。
  Future<void> _loadState() async {
    final FirstLaunchState state = await _service.loadState();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _agreementAccepted = state.agreementAccepted;
      _loginGuideShown = state.loginGuideShown;
    });
    if (_agreementAccepted) {
      _scheduleLoginGuide();
    } else {
      _startUnlockCountdown();
    }
  }

  /// 从十秒开始每秒减少一次倒计时，到零后立即释放计时器。
  void _startUnlockCountdown() {
    _unlockTimer?.cancel();
    _secondsRemaining = _unlockDelaySeconds;
    _unlockTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsRemaining = (_secondsRemaining - 1)
            .clamp(0, _unlockDelaySeconds)
            .toInt();
      });
      if (_secondsRemaining == 0) {
        timer.cancel();
        _unlockTimer = null;
      }
    });
  }

  /// 保存协议同意状态；只有写入成功后才进入主页并安排登录引导。
  Future<void> _acceptAgreement() async {
    if (_secondsRemaining > 0 || _accepting || _exiting) {
      return;
    }
    setState(() => _accepting = true);
    final bool saved = await _service.acceptAgreement();
    if (!mounted) {
      return;
    }
    if (!saved) {
      setState(() => _accepting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法保存协议状态，请检查设备存储后重试。')));
      return;
    }
    _unlockTimer?.cancel();
    _unlockTimer = null;
    setState(() {
      _accepting = false;
      _agreementAccepted = true;
    });
    _scheduleLoginGuide();
  }

  /// 不保存任何协议状态并调用系统退出；重复点击只处理一次。
  Future<void> _exitApplication() async {
    if (_accepting || _exiting) {
      return;
    }
    setState(() => _exiting = true);
    final ApplicationExit exit =
        widget.exitApplication ?? _defaultExitApplication;
    await exit();
    if (mounted) {
      setState(() => _exiting = false);
    }
  }

  /// 使用 Flutter 系统导航通道关闭当前 Android Activity。
  Future<void> _defaultExitApplication() {
    return SystemNavigator.pop();
  }

  /// 在主页完成首帧布局后安排一次登录引导，避免在 build 中直接弹窗。
  void _scheduleLoginGuide() {
    if (_loginGuideShown || _loginGuideScheduled || !_agreementAccepted) {
      return;
    }
    _loginGuideScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showLoginGuide());
    });
  }

  /// 先记录引导已经展示，再询问用户现在登录还是暂时跳过。
  Future<void> _showLoginGuide() async {
    if (!mounted || _loginGuideShown || !_agreementAccepted) {
      return;
    }
    _loginGuideShown = true;
    await _service.markLoginGuideShown();
    if (!mounted) {
      return;
    }
    final bool openLogin =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          // 登录引导构建函数只说明登录收益，不会自动读取账号或打开网页。
          builder: (BuildContext dialogContext) => AlertDialog(
            key: const Key('first-login-guide-dialog'),
            icon: const Icon(Icons.account_circle_outlined),
            title: const Text('登录 B 站账号'),
            content: const Text('登录后，您可以播放高清视频，并使用您的收藏夹等内容。'),
            actions: <Widget>[
              TextButton(
                // 暂不登录按钮函数关闭本次且以后不再重复的登录引导。
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('暂不登录'),
              ),
              FilledButton(
                // 去登录按钮函数关闭引导，并在下一步打开应用登录页面。
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('去登录'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted || !openLogin) {
      return;
    }
    final LoginPageLauncher launcher =
        widget.openLoginPage ?? _defaultOpenLoginPage;
    await launcher(context);
  }

  /// 通过应用统一命名路由打开登录页，关闭后仍回到主页。
  Future<void> _defaultOpenLoginPage(BuildContext context) async {
    await Navigator.of(context).pushNamed(AppRoutes.login);
  }

  /// 根据首次启动状态构建加载页、协议页或真正的应用主页。
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        key: Key('first-launch-loading'),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_agreementAccepted) {
      return UserAgreementPage(
        secondsRemaining: _secondsRemaining,
        accepting: _accepting,
        exiting: _exiting,
        onAccept: _acceptAgreement,
        onExit: _exitApplication,
      );
    }
    return widget.child;
  }

  /// 释放倒计时，避免测试或应用退出后仍继续触发页面刷新。
  @override
  void dispose() {
    _unlockTimer?.cancel();
    super.dispose();
  }
}
