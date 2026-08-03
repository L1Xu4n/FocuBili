import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/focus_notification_service.dart';

/// 集中展示和管理当前应用使用的 Android 权限与后台提醒保护设置。
class AndroidPermissionManagementPage extends StatefulWidget {
  /// 创建统一权限页；测试可注入自定义原生通知服务。
  const AndroidPermissionManagementPage({
    super.key,
    this.notificationService = const FocusNotificationService(),
  });

  final FocusNotificationService notificationService;

  /// 创建负责检查权限与监听系统设置返回的页面状态。
  @override
  State<AndroidPermissionManagementPage> createState() =>
      _AndroidPermissionManagementPageState();
}

/// 管理统一权限状态读取、通知申请和各系统设置入口。
class _AndroidPermissionManagementPageState
    extends State<AndroidPermissionManagementPage>
    with WidgetsBindingObserver {
  AndroidPermissionOverview? _overview;
  bool _loading = true;
  bool _requestingNotification = false;

  /// 页面创建后注册生命周期监听并立即执行第一次权限检查。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadOverview());
  }

  /// 页面销毁时解除系统设置返回监听，避免已经退出的页面继续刷新。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置返回应用时重新检查全部权限，让状态文字即时更新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadOverview(showProgress: false));
    }
  }

  /// 一次读取全部 Android 权限和后台限制；失败时仍保留上一次结果。
  Future<void> _loadOverview({bool showProgress = true}) async {
    if (showProgress && mounted) {
      setState(() => _loading = true);
    }
    final AndroidPermissionOverview overview = await widget.notificationService
        .getPermissionOverview();
    if (!mounted) {
      return;
    }
    setState(() {
      _overview = overview;
      _loading = false;
    });
  }

  /// 请求 Android 13+ 通知权限，旧系统会直接重新检查通知总开关。
  Future<void> _requestNotificationPermission() async {
    if (_requestingNotification) {
      return;
    }
    setState(() => _requestingNotification = true);
    final bool allowed = await widget.notificationService.requestPermission();
    await _loadOverview(showProgress: false);
    if (mounted && !allowed) {
      _showMessage('通知仍未开启，可点击“管理/取消”进入系统通知设置。');
    }
    if (mounted) {
      setState(() => _requestingNotification = false);
    }
  }

  /// 打开系统设置后保持当前页面，用户返回时生命周期回调会自动重新检查。
  Future<void> _openSystemSettings(Future<void> Function() opener) async {
    await opener();
  }

  /// 显示不会叠加的底部提示，说明权限操作必须由用户在系统页完成。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 构建页面顶部的权限原则和统一检查按钮。
  Widget _buildIntroduction() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '权限只在功能需要时申请',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              '这里集中提供申请、检查、取消入口和用途说明。原有功能内的权限入口仍然保留；取消权限需要在 Android 系统设置中由你确认。',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('refresh-android-permissions'),
              // 检查按钮函数重新读取所有可查询权限，不会自动修改系统设置。
              onPressed: _loading ? null : _loadOverview,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新检查全部权限'),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建所有权限卡片；厂商自启动没有公开查询接口时会明确标记为手动确认。
  List<Widget> _buildPermissionCards(AndroidPermissionOverview overview) {
    final bool batteryProtected =
        overview.batteryOptimizationIgnored && !overview.backgroundRestricted;
    return <Widget>[
      _PermissionCard(
        key: const Key('permission-notifications'),
        icon: Icons.notifications_active_outlined,
        title: '通知权限',
        status: overview.notificationAllowed ? '已允许' : '未允许',
        granted: overview.notificationAllowed,
        description: '用于在预约时间显示“继续专注”通知，不读取通知内容。',
        primaryLabel: overview.notificationAllowed ? null : '申请',
        // 通知申请函数在 Android 13+ 弹出系统权限框，旧系统重新检查总开关。
        onPrimary: overview.notificationAllowed || _requestingNotification
            ? null
            : _requestNotificationPermission,
        manageLabel: '管理/取消',
        // 通知管理函数打开当前应用通知设置，可开启频道或取消通知权限。
        onManage: () =>
            _openSystemSettings(widget.notificationService.openSettings),
      ),
      _PermissionCard(
        key: const Key('permission-exact-alarm'),
        icon: Icons.alarm_on_outlined,
        title: '闹钟和提醒',
        status: overview.exactAlarmAllowed ? '已允许精确提醒' : '未允许',
        granted: overview.exactAlarmAllowed,
        description: '用于在应用退到后台或进程被系统回收后，仍按你选定的时间唤醒提醒。',
        primaryLabel: overview.exactAlarmAllowed ? null : '去开启',
        // 精确闹钟申请函数打开 Android 特殊访问页面，由用户亲自授权。
        onPrimary: overview.exactAlarmAllowed
            ? null
            : () => _openSystemSettings(
                widget.notificationService.openExactAlarmSettings,
              ),
        manageLabel: '管理/取消',
        // 精确闹钟管理函数使用同一特殊访问页面进行检查或撤销。
        onManage: () => _openSystemSettings(
          widget.notificationService.openExactAlarmSettings,
        ),
      ),
      _PermissionCard(
        key: const Key('permission-do-not-disturb'),
        icon: Icons.do_not_disturb_on_outlined,
        title: '勿扰模式访问',
        status: overview.doNotDisturbAllowed ? '已允许' : '未允许',
        granted: overview.doNotDisturbAllowed,
        description: '仅在你开启自动勿扰后使用：视频播放时开启，暂停或专注结束时恢复原状态。',
        primaryLabel: overview.doNotDisturbAllowed ? null : '去开启',
        // 勿扰申请函数打开系统特殊访问列表，不会自行切换用户权限。
        onPrimary: overview.doNotDisturbAllowed
            ? null
            : () => _openSystemSettings(
                widget.notificationService.openDoNotDisturbSettings,
              ),
        manageLabel: '管理/取消',
        // 勿扰管理函数让用户在相同系统页面检查或取消特殊访问。
        onManage: () => _openSystemSettings(
          widget.notificationService.openDoNotDisturbSettings,
        ),
      ),
      _PermissionCard(
        key: const Key('permission-battery'),
        icon: Icons.battery_saver_outlined,
        title: '后台电量限制',
        status: batteryProtected
            ? '已允许后台运行'
            : overview.backgroundRestricted
            ? '系统正在限制后台运行'
            : '建议设为无限制',
        granted: batteryProtected,
        description: '避免省电策略延迟或阻止闹钟接收器。不同品牌的选项名称可能是“无限制”或“不优化”。',
        primaryLabel: batteryProtected ? null : '去设置',
        // 电量设置函数打开应用详情，由用户选择无限制后台运行。
        onPrimary: batteryProtected
            ? null
            : () => _openSystemSettings(
                widget.notificationService.openBatterySettings,
              ),
        manageLabel: '管理/取消',
        // 电量管理函数允许用户随时恢复系统默认限制。
        onManage: () =>
            _openSystemSettings(widget.notificationService.openBatterySettings),
      ),
      _PermissionCard(
        key: const Key('permission-autostart'),
        icon: Icons.mobile_friendly_outlined,
        title: '后台自启动',
        status: overview.requiresAutostartGuide ? '需要在系统页手动确认' : '由系统自动管理',
        granted: !overview.requiresAutostartGuide,
        description: overview.requiresAutostartGuide
            ? '${overview.manufacturer.isEmpty ? '当前厂商' : overview.manufacturer} 系统不提供自启动状态查询接口。请确认焦点哔哩已开启“后台自启动”，小米/HyperOS 划掉后台后尤其需要。'
            : '标准 Android 通常不需要单独的自启动开关；如果厂商系统提供该选项，也可从应用详情管理。',
        primaryLabel: '打开设置',
        // 自启动管理函数优先直达小米安全中心，入口缺失时回退应用详情。
        onPrimary: () => _openSystemSettings(
          widget.notificationService.openBackgroundAutostartSettings,
        ),
        manageLabel: null,
        onManage: null,
      ),
    ];
  }

  /// 构建统一权限管理页面，加载完成后逐项显示状态、用途和系统入口。
  @override
  Widget build(BuildContext context) {
    final AndroidPermissionOverview? overview = _overview;
    return Scaffold(
      appBar: AppBar(title: const Text('权限管理')),
      body: overview == null && _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              // 下拉刷新函数只检查权限状态，不会申请或取消任何权限。
              onRefresh: _loadOverview,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: <Widget>[
                  _buildIntroduction(),
                  const SizedBox(height: 8),
                  if (overview != null) ..._buildPermissionCards(overview),
                ],
              ),
            ),
    );
  }
}

/// 展示单项 Android 权限状态、用途以及申请和系统管理入口。
class _PermissionCard extends StatelessWidget {
  /// 创建一张可复用于后续新增权限的状态卡片。
  const _PermissionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.status,
    required this.granted,
    required this.description,
    required this.primaryLabel,
    required this.onPrimary,
    required this.manageLabel,
    required this.onManage,
  });

  final IconData icon;
  final String title;
  final String status;
  final bool granted;
  final String description;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? manageLabel;
  final VoidCallback? onManage;

  /// 构建带状态色、用途说明和最多两个操作按钮的权限卡片。
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: granted
                        ? colors.primaryContainer
                        : colors.errorContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Text(
                      status,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: granted
                            ? colors.onPrimaryContainer
                            : colors.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(description),
            if (primaryLabel != null || manageLabel != null) ...<Widget>[
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: <Widget>[
                  if (primaryLabel != null)
                    FilledButton.tonal(
                      onPressed: onPrimary,
                      child: Text(primaryLabel!),
                    ),
                  if (manageLabel != null)
                    OutlinedButton(
                      onPressed: onManage,
                      child: Text(manageLabel!),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
