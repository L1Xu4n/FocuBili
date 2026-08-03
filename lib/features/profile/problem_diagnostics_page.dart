import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/problem_diagnostics_service.dart';

/// 展示可脱敏复制的基础环境、最近错误和清空入口的问题诊断 MVP 页面。
class ProblemDiagnosticsPage extends StatefulWidget {
  /// 创建问题诊断页面；测试可注入内存服务和固定环境信息。
  const ProblemDiagnosticsPage({super.key, this.diagnosticsService});

  final ProblemDiagnosticsService? diagnosticsService;

  /// 创建负责加载、复制和清空诊断记录的页面状态。
  @override
  State<ProblemDiagnosticsPage> createState() => _ProblemDiagnosticsPageState();
}

/// 管理诊断快照的异步读取，并把用户操作反馈为简短提示。
class _ProblemDiagnosticsPageState extends State<ProblemDiagnosticsPage> {
  late final ProblemDiagnosticsService _diagnosticsService;
  ProblemDiagnosticsSnapshot? _snapshot;
  bool _loading = true;
  bool _copying = false;
  bool _clearing = false;

  /// 初始化诊断服务并读取一次当前环境与最近错误。
  @override
  void initState() {
    super.initState();
    _diagnosticsService =
        widget.diagnosticsService ?? ProblemDiagnosticsService();
    unawaited(_loadSnapshot());
  }

  /// 重新读取诊断快照；失败时保留已显示内容并给出明确提示。
  Future<void> _loadSnapshot() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final ProblemDiagnosticsSnapshot snapshot = await _diagnosticsService
          .loadSnapshot();
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        _showMessage('暂时无法读取诊断信息，请稍后重试。');
      }
    }
  }

  /// 生成脱敏诊断文本并复制到系统剪贴板，成功后不自动发送给任何第三方。
  Future<void> _copyDiagnostics() async {
    if (_copying || _clearing) {
      return;
    }
    setState(() => _copying = true);
    try {
      final String content = await _diagnosticsService.buildCopyText();
      await Clipboard.setData(ClipboardData(text: content));
      if (mounted) {
        _showMessage('诊断信息已复制，可直接粘贴发送给开发者。');
      }
    } catch (_) {
      if (mounted) {
        _showMessage('复制失败，请稍后重试。');
      }
    } finally {
      if (mounted) {
        setState(() => _copying = false);
      }
    }
  }

  /// 清空本机最近错误后重新读取页面，应用版本、设备信息和其他用户数据不会受影响。
  Future<void> _clearDiagnostics() async {
    if (_clearing || _copying) {
      return;
    }
    setState(() => _clearing = true);
    try {
      await _diagnosticsService.clearRecentErrors();
      await _loadSnapshot();
      if (mounted) {
        _showMessage('诊断记录已清空。');
      }
    } catch (_) {
      if (mounted) {
        _showMessage('清空失败，请稍后重试。');
      }
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  /// 显示统一的短提示，避免重复的 SnackBar 叠在页面底部。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 创建一行“标签 + 内容”的基础环境信息，内容过长时仍能安全换行。
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 82,
            child: Text(
              '$label：',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 创建包含应用版本、系统版本、设备型号和生成时间的基础环境信息卡片。
  Widget _buildEnvironmentCard(ProblemDiagnosticsSnapshot snapshot) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.phone_android_rounded),
                const SizedBox(width: 8),
                Text(
                  '基础环境信息',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildInfoRow('应用版本', snapshot.appVersion),
            _buildInfoRow(
              '系统版本',
              'Android ${snapshot.deviceInfo.androidLabel}',
            ),
            _buildInfoRow('设备型号', snapshot.deviceInfo.model),
            _buildInfoRow(
              '生成时间',
              formatDiagnosticDateTime(snapshot.generatedAt),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建闹钟安排、恢复和触发状态卡片，帮助区分系统未唤醒与通知权限拦截。
  Widget _buildReminderDiagnosticsCard(
    ReminderDiagnosticsSnapshot diagnostics,
  ) {
    final List<ReminderDiagnosticEvent> visibleEvents = diagnostics.events
        .take(6)
        .toList(growable: false);
    return Card(
      key: const Key('reminder-diagnostics-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.alarm_on_outlined),
                const SizedBox(width: 8),
                Text(
                  '提醒诊断',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildInfoRow('待触发', '${diagnostics.pendingCount} 条'),
            _buildInfoRow(
              '精确闹钟',
              diagnostics.exactAlarmAllowed ? '已允许' : '未允许',
            ),
            _buildInfoRow(
              '通知状态',
              diagnostics.notificationsEnabled ? '已开启' : '未开启',
            ),
            _buildInfoRow(
              '后台限制',
              diagnostics.backgroundRestricted ? '系统正在限制' : '未检测到限制',
            ),
            _buildInfoRow(
              '最近安排',
              diagnostics.lastScheduledAt == null
                  ? '从未'
                  : formatDiagnosticDateTime(diagnostics.lastScheduledAt!),
            ),
            _buildInfoRow(
              '最近触发',
              diagnostics.lastTriggeredAt == null
                  ? '从未'
                  : formatDiagnosticDateTime(diagnostics.lastTriggeredAt!),
            ),
            const SizedBox(height: 8),
            Text(
              '最近原生事件',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            if (visibleEvents.isEmpty)
              const Text('暂无闹钟安排或触发记录。')
            else
              ...visibleEvents.map(
                (ReminderDiagnosticEvent event) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${formatDiagnosticDateTime(event.occurredAt)}  '
                    '${event.typeLabel}：${event.resultLabel}'
                    '${event.mode.isEmpty ? '' : '（${event.mode}）'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 创建一条最近错误卡片，显示人类可读说明和有限的脱敏附加状态。
  Widget _buildErrorCard(ProblemDiagnosticEntry entry) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.error_outline_rounded, color: colors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    formatDiagnosticDateTime(entry.occurredAt),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildInfoRow('分类', entry.categoryLabel),
            _buildInfoRow('操作', entry.operationLabel),
            if (entry.errorCode != null)
              _buildInfoRow('错误代码', entry.errorCode.toString()),
            _buildInfoRow('说明', entry.description),
            if (entry.additionalInfo.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '附加信息',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              ...entry.additionalInfo.entries.map(
                (MapEntry<String, String> item) => Text(
                  '- ${item.key}: ${item.value}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 创建最近错误区域；没有记录时明确说明当前设备尚未捕获到可诊断错误。
  Widget _buildRecentErrors(ProblemDiagnosticsSnapshot snapshot) {
    final List<ProblemDiagnosticEntry> errors = snapshot.recentErrors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Text(
            '最近错误',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (errors.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.check_circle_outline_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '暂无诊断记录。发生播放或网络错误后，会在这里显示最近的脱敏信息。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...errors.map(_buildErrorCard),
      ],
    );
  }

  /// 创建复制、清空和隐私说明区域，让用户知道数据只在明确点击复制后才会离开应用。
  Widget _buildActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('copy-problem-diagnostics'),
          // 复制按钮函数只写入系统剪贴板，不会联网发送诊断内容。
          onPressed: _loading || _copying || _clearing
              ? null
              : _copyDiagnostics,
          icon: _copying
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.content_copy_rounded),
          label: Text(_copying ? '正在复制…' : '复制诊断信息'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('clear-problem-diagnostics'),
          // 清空按钮函数只删除本机诊断记录，不会影响账号、笔记、观看记录或学习清单。
          onPressed: _loading || _copying || _clearing
              ? null
              : _clearDiagnostics,
          icon: _clearing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_sweep_outlined),
          label: Text(_clearing ? '正在清空…' : '清空诊断记录'),
        ),
        const SizedBox(height: 18),
        Text(
          '隐私说明：本诊断信息不包含登录凭据、Cookie、搜索内容、笔记正文、专注目标或完整请求地址。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 构建诊断页面；加载期间显示进度，完成后提供下拉刷新以重新读取当前环境。
  @override
  Widget build(BuildContext context) {
    final ProblemDiagnosticsSnapshot? snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('问题诊断'),
        actions: <Widget>[
          IconButton(
            key: const Key('reload-problem-diagnostics'),
            // 刷新按钮函数重新读取环境和最近错误，不发送任何网络请求。
            onPressed: _loading || _copying || _clearing
                ? null
                : () => unawaited(_loadSnapshot()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新诊断信息',
          ),
        ],
      ),
      body: snapshot == null && _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              // 下拉刷新函数重新读取本机诊断快照，适合用户遇到新问题后马上查看。
              onRefresh: _loadSnapshot,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: <Widget>[
                  if (snapshot != null) ...<Widget>[
                    _buildEnvironmentCard(snapshot),
                    const SizedBox(height: 8),
                    _buildReminderDiagnosticsCard(snapshot.reminderDiagnostics),
                    _buildRecentErrors(snapshot),
                  ],
                  _buildActions(),
                ],
              ),
            ),
    );
  }
}
