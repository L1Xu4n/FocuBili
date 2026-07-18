import 'package:flutter/material.dart';

/// 显示由组件自己管理输入控制器的自定义分钟弹窗。
Future<int?> showCustomFocusDurationDialog(
  BuildContext context, {
  required int initialMinutes,
}) {
  return showDialog<int>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _CustomFocusDurationDialog(initialMinutes: initialMinutes),
  );
}

/// 保存弹窗的初始分钟数，输入控制器由对应 State 跟随路由生命周期释放。
class _CustomFocusDurationDialog extends StatefulWidget {
  /// 创建自定义时长弹窗。
  const _CustomFocusDurationDialog({required this.initialMinutes});

  final int initialMinutes;

  /// 创建管理分钟输入和校验提示的状态。
  @override
  State<_CustomFocusDurationDialog> createState() =>
      _CustomFocusDurationDialogState();
}

/// 管理输入控制器，避免弹窗退出动画仍在使用控制器时被过早释放。
class _CustomFocusDurationDialogState
    extends State<_CustomFocusDurationDialog> {
  late final TextEditingController _minutesController;
  String? _errorText;

  /// 根据当前选择填入默认分钟数。
  @override
  void initState() {
    super.initState();
    _minutesController = TextEditingController(
      text: '${widget.initialMinutes}',
    );
  }

  /// 校验 1 到 180 的整数，合法时把分钟数返回调用页面。
  void _confirm() {
    final int? minutes = int.tryParse(_minutesController.text.trim());
    if (minutes == null || minutes < 1 || minutes > 180) {
      setState(() => _errorText = '请输入 1 到 180 的整数');
      return;
    }
    Navigator.of(context).pop(minutes);
  }

  /// 构建分钟输入框和取消、确定操作。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义专注时间'),
      content: TextField(
        key: const Key('custom-focus-minutes-field'),
        controller: _minutesController,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: '分钟',
          helperText: '可填写 1 到 180 分钟',
          errorText: _errorText,
        ),
        onSubmitted: (_) => _confirm(),
      ),
      actions: <Widget>[
        TextButton(
          // 取消函数关闭弹窗且保持原有时长不变。
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          // 确认函数完成范围校验后返回分钟数。
          onPressed: _confirm,
          child: const Text('确定'),
        ),
      ],
    );
  }

  /// 在弹窗完全移除后释放输入控制器，修复取消时的依赖断言错误。
  @override
  void dispose() {
    _minutesController.dispose();
    super.dispose();
  }
}
