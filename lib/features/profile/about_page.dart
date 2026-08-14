import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/router/app_router.dart';
import '../../services/app_update_service.dart';

/// 打开外部链接的可注入函数类型，组件测试用它避免真的离开 App。
typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);

/// 展示项目来源、QQ 群、负责人、安装版本和 GitHub Release 更新状态。
class AboutPage extends StatefulWidget {
  /// 创建关于页；测试可注入更新控制器和不会真正打开浏览器的函数。
  const AboutPage({super.key, this.controller, this.externalUrlLauncher});

  final AppUpdateController? controller;
  final ExternalUrlLauncher? externalUrlLauncher;

  /// 创建负责监听全局更新状态的页面状态。
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  AppUpdateController? _controller;

  static final Uri _projectUri = Uri.parse(
    'https://github.com/L1Xu4n/FocuBili',
  );
  static final Uri _ownerUri = Uri.parse('https://github.com/L1Xu4n');
  static final Uri _qqGroupUri = Uri.parse('https://qm.qq.com/q/szv665wx7W');

  /// 连接应用级更新控制器，并在首次进入时补读本机版本信息。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppUpdateController controller =
        widget.controller ?? AppUpdateScope.of(context);
    if (!identical(controller, _controller)) {
      _controller?.removeListener(_handleUpdateChanged);
      _controller = controller..addListener(_handleUpdateChanged);
      if (!controller.loaded) {
        unawaited(controller.initialize(checkOnStart: false));
      }
    }
  }

  /// 更新状态变化时刷新版本、红点和按钮文案。
  void _handleUpdateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 交给系统打开项目、负责人、QQ 群或 Release 链接，失败时展示对应提示。
  Future<void> _open(Uri uri, {String failureMessage = '无法打开外部链接。'}) async {
    final ExternalUrlLauncher launcher =
        widget.externalUrlLauncher ?? _launchExternally;
    final bool opened = await launcher(uri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }

  /// 要求 url_launcher 离开当前 App，让 QQ 或系统默认浏览器处理链接。
  Future<bool> _launchExternally(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 把内部更新状态转换成面向普通用户的中文说明。
  String _statusText(AppUpdateResult result) {
    return switch (result.status) {
      AppUpdateStatus.idle => '尚未检查更新',
      AppUpdateStatus.disabled => '已关闭启动时检查更新',
      AppUpdateStatus.checking => '正在检查更新…',
      AppUpdateStatus.upToDate => '当前已是最新版本',
      AppUpdateStatus.available => '发现新版本 ${result.latestVersion}',
      AppUpdateStatus.failed => result.message ?? '暂时无法检查更新',
    };
  }

  /// 把 Release 摘要绘制为最多三条紧凑列表，未按约定提供摘要时不显示空区域。
  Widget _buildUpdateHighlights(AppUpdateResult result) {
    return Column(
      key: const Key('about-update-highlights'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '本次更新',
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        ...result.releaseHighlights.map(
          (String highlight) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('•  '),
                Expanded(child: Text(highlight)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 绘制应用信息、项目链接和更新检查卡片。
  @override
  Widget build(BuildContext context) {
    final AppUpdateController controller = _controller!;
    final AppUpdateResult result = controller.result;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: AdaptivePageFrame(
        maxWidth: 900,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: <Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Image.asset(
                        'assets/icon/focubili_icon.png',
                        width: 88,
                        height: 88,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '焦点哔哩 FocuBili',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      result.currentVersion.isEmpty
                          ? '版本信息读取中…'
                          : '版本 ${result.currentVersion}',
                      key: const Key('about-version'),
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '用于个人学习、技术研究和专注观看公开视频的第三方客户端。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.code_rounded),
                    title: const Text('项目地址'),
                    subtitle: const Text('github.com/L1Xu4n/FocuBili'),
                    trailing: const Icon(Icons.open_in_new_rounded),
                    onTap: () => _open(_projectUri),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.person_outline_rounded),
                    title: const Text('项目负责人'),
                    subtitle: const Text('@L1Xu4n'),
                    trailing: const Icon(Icons.open_in_new_rounded),
                    onTap: () => _open(_ownerUri),
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    key: const Key('open-project-qq-group'),
                    leading: const Icon(Icons.groups_rounded),
                    title: const Text('项目QQ群'),
                    subtitle: const Text('焦点哔哩交流群 · 1055054828'),
                    trailing: const Icon(Icons.open_in_new_rounded),
                    // QQ 群入口函数把官方邀请链接交给系统，优先由已安装的 QQ 处理。
                    onTap: () => _open(
                      _qqGroupUri,
                      failureMessage: '无法唤起 QQ，请确认已安装 QQ 后重试。',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                key: const Key('open-problem-diagnostics'),
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('问题诊断'),
                subtitle: const Text('查看最近错误并复制脱敏诊断信息'),
                trailing: const Icon(Icons.chevron_right_rounded),
                // 问题诊断入口函数只打开本机页面；诊断内容仅在用户点击复制后才进入剪贴板。
                onTap: () => Navigator.of(
                  context,
                ).pushNamed(AppRoutes.problemDiagnostics),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: result.updateAvailable
                  ? Theme.of(context).colorScheme.errorContainer
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          result.updateAvailable
                              ? Icons.system_update_alt_rounded
                              : Icons.update_rounded,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '检查更新',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (result.updateAvailable)
                          const _UpdateDot(key: Key('about-update-dot')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _statusText(result),
                      key: const Key('about-update-status'),
                    ),
                    if (result.updateAvailable &&
                        result.releaseHighlights.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      _buildUpdateHighlights(result),
                    ],
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      alignment: WrapAlignment.end,
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: controller.checking
                              ? null
                              : controller.checkNow,
                          icon: controller.checking
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded),
                          label: const Text('重新检查'),
                        ),
                        if (result.updateAvailable)
                          FilledButton.icon(
                            key: const Key('open-release-page'),
                            onPressed: () => _open(
                              result.downloadUrl ??
                                  result.releaseUrl ??
                                  AppUpdateService.releasesUri,
                              failureMessage: result.downloadUrl == null
                                  ? '无法打开 Release 页面。'
                                  : '无法打开安装包下载地址，请前往 Release 页面重试。',
                            ),
                            icon: Icon(
                              result.downloadUrl == null
                                  ? Icons.open_in_new_rounded
                                  : Icons.download_rounded,
                            ),
                            label: Text(result.downloadActionLabel),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 页面销毁时解除监听，避免已关闭页面继续接收更新通知。
  @override
  void dispose() {
    _controller?.removeListener(_handleUpdateChanged);
    super.dispose();
  }
}

/// 用统一尺寸绘制更新提示红点，设置入口复用相同视觉语义。
class _UpdateDot extends StatelessWidget {
  /// 创建用于提示新版本的九像素红点。
  const _UpdateDot({super.key});

  /// 使用当前主题的错误色绘制圆形红点。
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        shape: BoxShape.circle,
      ),
    );
  }
}
