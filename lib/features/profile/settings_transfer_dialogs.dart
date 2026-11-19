import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/settings_transfer_service.dart';

/// 只选择载体，不在选择面板读取文件、剪贴板或会话。
enum DataTransferMethod { file, text }

Future<DataTransferMethod?> chooseDataTransferMethod(
  BuildContext context, {
  required bool importing,
  bool login = false,
}) => showDialog<DataTransferMethod>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text('选择${login ? '登录信息' : '设置'}${importing ? '导入' : '导出'}方式'),
    children: [
      ListTile(
        leading: const Icon(Icons.insert_drive_file_outlined),
        title: Text(importing ? '从文件导入' : '保存为文件'),
        onTap: () => Navigator.pop(context, DataTransferMethod.file),
      ),
      ListTile(
        leading: Icon(importing ? Icons.content_paste : Icons.copy_rounded),
        title: Text(importing ? (login ? '从剪贴板粘贴' : '从文本导入') : '复制到剪贴板'),
        subtitle: login && importing ? const Text('只粘贴你自己的登录备份') : null,
        onTap: () => Navigator.pop(context, DataTransferMethod.text),
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(end: 16),
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
      ),
    ],
  ),
);

/// 用户可手动输入，也可主动粘贴；校验失败时保留输入以便更正。
class SettingsTextImportDialog extends StatefulWidget {
  const SettingsTextImportDialog({super.key, required this.parse});
  final Map<String, Object> Function(String) parse;

  @override
  State<SettingsTextImportDialog> createState() =>
      _SettingsTextImportDialogState();
}

class _SettingsTextImportDialogState extends State<SettingsTextImportDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _reading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _active => mounted && ModalRoute.of(context)?.isCurrent == true;

  Future<void> _paste() async {
    if (_reading) return;
    setState(() {
      _error = null;
      _reading = true;
    });
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!_active) return;
      final text = data?.text;
      if (text == null || text.isEmpty) {
        setState(() => _error = '剪贴板没有文本，可手动粘贴。');
      } else if (!SettingsTransferService.fitsTransferLimit(text)) {
        setState(() => _error = '设置文本不能超过 2 MB。');
      } else {
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    } catch (_) {
      if (_active) setState(() => _error = '无法读取剪贴板，请手动粘贴。');
    } finally {
      if (_active) setState(() => _reading = false);
    }
  }

  void _next() {
    if (_reading || !_active) return;
    try {
      final values = widget.parse(_controller.text);
      Navigator.pop(context, values);
    } on FormatException {
      setState(() => _error = '不是有效的设置备份，请检查文本后重试。');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('从文本导入设置'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            readOnly: _reading,
            minLines: 3,
            maxLines: 6,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '设置 JSON',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          TextButton.icon(
            onPressed: _reading ? null : _paste,
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text('从剪贴板粘贴'),
          ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _reading ? null : _next,
        child: const Text('下一步'),
      ),
    ],
  );
}
