import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/focus_notification_service.dart';

/// 展示 Windows 通知、未来提醒和 MSIX 包身份，不出现 Android 权限或电量文案。
class WindowsSystemCapabilitiesPage extends StatefulWidget {
  /// 创建 Windows 系统能力页；测试可注入内存通知后端。
  const WindowsSystemCapabilitiesPage({
    super.key,
    this.notificationService = const FocusNotificationService(),
  });

  final FocusNotificationService notificationService;

  /// 创建负责检测 Toast 和包身份状态的页面状态。
  @override
  State<WindowsSystemCapabilitiesPage> createState() =>
      _WindowsSystemCapabilitiesPageState();
}

/// 管理 Windows 能力检测、测试通知和系统设置跳转。
class _WindowsSystemCapabilitiesPageState
    extends State<WindowsSystemCapabilitiesPage> {
  bool _loading = true;
  bool _notificationAvailable = false;
  bool _sendingTestNotification = false;

  /// 页面首次显示时检测 Windows Toast 初始化状态。
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  /// 重新读取通知可用性；异常统一显示为暂不可用。
  Future<void> _refresh() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    final bool notificationAvailable = await widget.notificationService
        .hasPermission();
    if (!mounted) {
      return;
    }
    setState(() {
      _notificationAvailable = notificationAvailable;
      _loading = false;
    });
  }

  /// 发送一条由用户主动触发的测试 Toast，并用页面提示报告提交结果。
  Future<void> _sendTestNotification() async {
    if (_sendingTestNotification || !_notificationAvailable) {
      return;
    }
    setState(() => _sendingTestNotification = true);
    await widget.notificationService.showFocusCompleted(
      sessionId:
          'windows-notification-test-${DateTime.now().millisecondsSinceEpoch}',
      goal: 'Windows 通知测试',
      focusedMinutes: 1,
    );
    if (!mounted) {
      return;
    }
    setState(() => _sendingTestNotification = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('测试通知已提交给 Windows')));
  }

  /// 打开 Windows 通知系统设置；返回应用后用户可下拉刷新状态。
  Future<void> _openNotificationSettings() {
    return widget.notificationService.openSettings();
  }

  /// 构建 Windows Toast、定时提醒、包身份和勿扰边界四张能力卡。
  @override
  Widget build(BuildContext context) {
    final bool hasPackageIdentity =
        widget.notificationService.hasWindowsPackageIdentity;
    return Scaffold(
      appBar: AppBar(title: const Text('系统能力')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          key: const Key('windows-system-capabilities'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              'Windows 桌面能力',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text('这里显示桌面端实际使用的系统能力，不需要 Android 的闹钟、勿扰或电量权限。'),
            const SizedBox(height: 16),
            _WindowsCapabilityCard(
              key: const Key('windows-toast-capability'),
              icon: Icons.notifications_active_outlined,
              title: 'Windows 通知',
              status: _loading
                  ? '正在检测'
                  : _notificationAvailable
                  ? '可用'
                  : '暂不可用',
              description: '专注完成时显示 Toast，也可以发送一条测试通知。',
              actions: <Widget>[
                OutlinedButton(
                  key: const Key('open-windows-notification-settings'),
                  onPressed: _openNotificationSettings,
                  child: const Text('系统通知设置'),
                ),
                FilledButton.tonal(
                  key: const Key('send-windows-test-notification'),
                  onPressed: _notificationAvailable && !_sendingTestNotification
                      ? _sendTestNotification
                      : null,
                  child: Text(_sendingTestNotification ? '正在发送…' : '发送测试通知'),
                ),
              ],
            ),
            _WindowsCapabilityCard(
              key: const Key('windows-scheduled-toast-capability'),
              icon: Icons.schedule_rounded,
              title: '未来继续提醒',
              status: _notificationAvailable ? '可用' : '暂不可用',
              description: '由 Windows 安排一次性 Toast；应用关闭后仍由系统等待触发。',
            ),
            _WindowsCapabilityCard(
              key: const Key('windows-package-identity-capability'),
              icon: Icons.inventory_2_outlined,
              title: '安装包身份',
              status: hasPackageIdentity ? 'MSIX 已安装' : '当前为普通 exe',
              description: hasPackageIdentity
                  ? '系统支持查询和取消已经提交的通知。'
                  : '即时和未来提醒可用；安装正式 MSIX 后才能完整查询、撤回系统通知。',
            ),
            const _WindowsCapabilityCard(
              key: Key('windows-focus-assist-boundary'),
              icon: Icons.do_not_disturb_on_outlined,
              title: 'Windows 系统专注',
              status: '需要手动启动',
              description:
                  '自动启动需要微软单独批准的受限功能授权。当前版本不会再修改旧通知注册表来模拟成功；请从 Windows“时钟”启动系统专注。',
            ),
            _WindowsCapabilityCard(
              key: const Key('windows-do-not-disturb-settings-entry'),
              icon: Icons.settings_outlined,
              title: 'Windows 勿扰设置',
              status: '可打开',
              description: '打开微软公开支持的系统设置页，手动调整勿扰和自动规则。',
              actions: <Widget>[
                OutlinedButton(
                  key: const Key('open-windows-focus-settings'),
                  // 按钮函数只打开 Windows 设置，不声称已经启动系统专注。
                  onPressed:
                      widget.notificationService.openDoNotDisturbSettings,
                  child: const Text('打开勿扰设置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 以统一卡片展示一项 Windows 能力的状态、说明和可选操作。
class _WindowsCapabilityCard extends StatelessWidget {
  /// 创建一张只读能力卡。
  const _WindowsCapabilityCard({
    super.key,
    required this.icon,
    required this.title,
    required this.status,
    required this.description,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final String title;
  final String status;
  final String description;
  final List<Widget> actions;

  /// 构建带状态标签、用途说明和自动换行按钮的桌面卡片。
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(label: Text(status)),
              ],
            ),
            const SizedBox(height: 8),
            Text(description),
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
