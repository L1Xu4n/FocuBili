import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/focus_session.dart';
import '../../services/focus_encouragement_service.dart';
import '../../services/focus_notification_service.dart';
import 'focus_timer_controller.dart';

/// 显示鼓励、原因和可选提醒流程；返回 true 表示用户确认打断或退出。
Future<bool> showFocusInterruptionFlow(
  BuildContext context, {
  required FocusTimerController controller,
  required FocusInterruptionKind kind,
  FocusEncouragementService? encouragementService,
  FocusNotificationService? notificationService,
}) async {
  final FocusSession? session = controller.activeSession;
  if (session == null || !session.isActive) {
    return true;
  }
  final bool nearCompletion =
      controller.progress >= 0.8 ||
      controller.remainingDuration <= const Duration(minutes: 5);
  final String message =
      await (encouragementService ?? FocusEncouragementService()).messageFor(
        nearCompletion: nearCompletion,
        seed: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
  if (!context.mounted) {
    return false;
  }
  final bool? continueToReason = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      icon: Icon(
        nearCompletion ? Icons.emoji_events_rounded : Icons.favorite_rounded,
      ),
      title: Text(nearCompletion ? '马上就完成了' : '要不要再坚持一下？'),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          // 坚持打断函数进入原因和可选提醒填写步骤。
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            kind == FocusInterruptionKind.playerExit ? '仍然退出' : '仍要暂停',
          ),
        ),
        FilledButton(
          // 继续函数关闭流程并保留当前专注与播放器页面。
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('继续专注'),
        ),
      ],
    ),
  );
  if (continueToReason != true || !context.mounted) {
    return false;
  }
  final FocusInterruptionDraft? draft =
      await showDialog<FocusInterruptionDraft>(
        context: context,
        builder: (BuildContext dialogContext) =>
            const _InterruptionReasonDialog(),
      );
  if (draft == null || !context.mounted) {
    return false;
  }
  await controller.interruptFocus(
    kind: kind,
    reason: draft.reason,
    reminderAt: draft.reminderAt,
  );
  if (draft.reminderAt != null && context.mounted) {
    await _scheduleReminderWithPermission(
      context,
      controller: controller,
      session: session,
      draft: draft,
      service: notificationService ?? const FocusNotificationService(),
    );
  }
  return true;
}

/// 显示主动终止原因输入框，返回空字符串时统一转换成“未填写原因”。
Future<String?> showFocusTerminationReasonDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => const _TerminationReasonDialog(),
  );
}

/// 保存用户确认的一次打断原因和可选提醒时间。
class FocusInterruptionDraft {
  /// 创建不可变的打断表单结果。
  const FocusInterruptionDraft({required this.reason, this.reminderAt});

  final String reason;
  final DateTime? reminderAt;
}

/// 在安排提醒前请求权限，拒绝后提供直达系统通知设置的按钮。
Future<void> _scheduleReminderWithPermission(
  BuildContext context, {
  required FocusTimerController controller,
  required FocusSession session,
  required FocusInterruptionDraft draft,
  required FocusNotificationService service,
}) async {
  bool permitted = await service.hasPermission();
  if (!permitted && context.mounted) {
    final bool? shouldRequest = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('需要通知权限'),
        content: const Text('开启通知后，焦点哔哩才能在你选择的时间提醒继续任务。'),
        actions: <Widget>[
          TextButton(
            // 暂不开启函数只跳过本次系统提醒，不影响打断记录。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('暂不开启'),
          ),
          FilledButton(
            // 允许通知函数交给 Android 显示系统权限对话框。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('允许通知'),
          ),
        ],
      ),
    );
    if (shouldRequest == true) {
      permitted = await service.requestPermission();
    }
  }
  if (!permitted && context.mounted) {
    final bool? openSettings = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('通知权限未开启'),
        content: const Text('可以直接打开系统设置，在“通知”中允许焦点哔哩发送提醒。'),
        actions: <Widget>[
          TextButton(
            // 取消设置函数保留原因记录但不创建系统提醒。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 打开设置函数返回系统通知权限页面。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('打开设置'),
          ),
        ],
      ),
    );
    if (openSettings == true) {
      await service.openSettings();
    }
    return;
  }
  final bool scheduled = await service.scheduleReminder(
    sessionId: session.id,
    goal: session.goal,
    reason: draft.reason,
    reminderAt: draft.reminderAt!,
  );
  if (!scheduled || !context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('已设置继续专注提醒')));
}

/// 保存原因输入和提醒时间的弹窗组件。
class _InterruptionReasonDialog extends StatefulWidget {
  /// 创建打断原因弹窗。
  const _InterruptionReasonDialog();

  /// 创建管理输入控制器与时间选择的状态。
  @override
  State<_InterruptionReasonDialog> createState() =>
      _InterruptionReasonDialogState();
}

/// 管理打断原因文本与可选的本地日期时间。
class _InterruptionReasonDialogState extends State<_InterruptionReasonDialog> {
  final TextEditingController _reasonController = TextEditingController();
  DateTime? _reminderAt;

  /// 依次选择日期和时间，并拒绝已经过去的提醒时间。
  Future<void> _selectReminder() async {
    final DateTime now = DateTime.now();
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: _reminderAt ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) {
      return;
    }
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: _reminderAt == null
          ? TimeOfDay.fromDateTime(now.add(const Duration(hours: 1)))
          : TimeOfDay.fromDateTime(_reminderAt!),
    );
    if (time == null || !mounted) {
      return;
    }
    final DateTime selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!selected.isAfter(now)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('提醒时间需要晚于现在')));
      return;
    }
    setState(() => _reminderAt = selected);
  }

  /// 把提醒时间格式化为用户可确认的本地日期和时分。
  String _formatReminder(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
  }

  /// 返回填写结果，空原因按产品规则自动保存为“未填写原因”。
  void _confirm() {
    final String reason = _reasonController.text.trim();
    Navigator.of(context).pop(
      FocusInterruptionDraft(
        reason: reason.isEmpty ? '未填写原因' : reason,
        reminderAt: _reminderAt,
      ),
    );
  }

  /// 构建原因输入、提醒时间选择和确认按钮。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('记录这次打断'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const Key('focus-interruption-reason'),
              controller: _reasonController,
              maxLength: 80,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '退出或暂停原因（可选）',
                hintText: '不填写将记录为“未填写原因”',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              // 选择提醒函数打开系统日期与时间选择器。
              onPressed: () => unawaited(_selectReminder()),
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(
                _reminderAt == null
                    ? '设置下次继续时间（可选）'
                    : _formatReminder(_reminderAt!),
              ),
            ),
            if (_reminderAt != null)
              TextButton(
                // 清除提醒函数只取消表单中的时间选择。
                onPressed: () => setState(() => _reminderAt = null),
                child: const Text('不设置提醒'),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          // 返回函数取消整次退出或暂停流程。
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
        FilledButton.tonal(
          // 确认函数保存打断记录，任务本身仍保持活动状态。
          onPressed: _confirm,
          child: const Text('确认'),
        ),
      ],
    );
  }

  /// 弹窗移除后释放原因输入控制器。
  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }
}

/// 保存主动终止原因的弹窗组件。
class _TerminationReasonDialog extends StatefulWidget {
  /// 创建终止原因弹窗。
  const _TerminationReasonDialog();

  /// 创建管理终止原因输入的状态。
  @override
  State<_TerminationReasonDialog> createState() =>
      _TerminationReasonDialogState();
}

/// 管理终止原因输入并只在用户明确确认后返回结果。
class _TerminationReasonDialogState extends State<_TerminationReasonDialog> {
  final TextEditingController _controller = TextEditingController();

  /// 返回规范化原因，空输入使用默认原因。
  void _confirm() {
    final String reason = _controller.text.trim();
    Navigator.of(context).pop(reason.isEmpty ? '未填写原因' : reason);
  }

  /// 构建终止说明、原因输入和最终确认操作。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('终止本次专注？'),
      content: TextField(
        key: const Key('focus-termination-reason'),
        controller: _controller,
        maxLength: 80,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: '终止原因（可选）',
          helperText: '只有确认终止才会计入“提前结束”',
        ),
      ),
      actions: <Widget>[
        TextButton(
          // 继续函数放弃终止并返回当前专注。
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('继续专注'),
        ),
        FilledButton.tonal(
          // 终止函数返回原因供控制器归档记录。
          onPressed: _confirm,
          child: const Text('确认终止'),
        ),
      ],
    );
  }

  /// 弹窗移除后释放终止原因输入控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
