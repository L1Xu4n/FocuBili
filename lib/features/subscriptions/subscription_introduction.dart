import 'dart:async';
import 'package:flutter/material.dart';
import '../../platform/app_platform.dart';
import '../../services/dashboard_layout_service.dart';
import '../../services/subscription_service.dart';
import '../../services/subscription_onboarding_service.dart';
import 'subscription_updates_page.dart';

class SubscriptionIntroduction extends StatefulWidget {
  const SubscriptionIntroduction({
    super.key,
    required this.service,
    required this.layoutService,
    required this.onEnabled,
    this.onVisibilityChanged,
  });
  final SubscriptionService service;
  final DashboardLayoutService layoutService;
  final VoidCallback onEnabled;
  final ValueChanged<bool>? onVisibilityChanged;
  @override
  State<SubscriptionIntroduction> createState() =>
      _SubscriptionIntroductionState();
}

class _SubscriptionIntroductionState extends State<SubscriptionIntroduction>
    with SingleTickerProviderStateMixin {
  late final _onboarding = SubscriptionOnboardingService(
    subscriptions: widget.service,
    layoutService: widget.layoutService,
  );
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  bool _visible = false, _busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final visible = await _onboarding.shouldPrompt();
      if (mounted && _onboarding.homeLayoutChanged) widget.onEnabled();
      _setVisible(visible);
    } catch (_) {
      /* Keep existing data; retry on next launch. */
    }
  }

  /// 首屏只为实际可见的提示预留高度，选择完成后恢复原有简洁布局。
  void _setVisible(bool value) {
    if (!mounted || _visible == value) return;
    setState(() => _visible = value);
    // Both callers resume after an awaited storage operation. Update the parent
    // in this same turn so the first visible frame already reserves its height.
    widget.onVisibilityChanged?.call(value);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.disableAnimationsOf(context) &&
        !AppPlatformDetector.isFlutterTest) {
      _breath.repeat(reverse: true);
    } else {
      _breath.stop();
    }
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    final choice = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => AlertDialog(
        title: const Text('开启焦点订阅？'),
        content: const SingleChildScrollView(
          child: Text(
            '焦点订阅功能允许你在焦点哔哩内订阅一些UP主和订阅合集，APP将检查订阅源并通过系统通知或首页卡片推送给你，如果你不需要，点击下面的按钮，你的首页会像往常一样简洁。当你需要焦点订阅时，在“我的页面”仍然能够再次开启',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('我不需要焦点订阅'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('好，开启焦点订阅'),
          ),
        ],
      ),
    );
    try {
      if (choice == null) return;
      if (choice) {
        await _onboarding.accept();
      } else {
        await _onboarding.decline();
      }
      if (!mounted) return;
      _setVisible(false);
      if (choice) {
        widget.onEnabled();
        await showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
            content: const Text('首页已经添加“焦点订阅”卡片和快捷按钮'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('好的'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => SubscriptionSettingsPage(service: widget.service),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('选择未保存，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('焦点订阅'),
        AnimatedBuilder(
          animation: _breath,
          builder: (context, child) => FilledButton.tonal(
            key: const Key('new-focus-subscription'),
            onPressed: _busy ? null : _open,
            style: FilledButton.styleFrom(
              backgroundColor: Color.lerp(
                colors.primaryContainer,
                colors.secondaryContainer,
                Curves.easeInOut.transform(_breath.value),
              ),
            ),
            child: const Text('新增焦点订阅'),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }
}
