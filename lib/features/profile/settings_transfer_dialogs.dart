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
        leading: Icon(
          importing ? Icons.text_fields_rounded : Icons.copy_rounded,
        ),
        title: Text(importing ? '从文本导入' : '复制到剪贴板'),
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
class DataTransferTextImportDialog<T extends Object> extends StatefulWidget {
  const DataTransferTextImportDialog({
    super.key,
    required this.parse,
    this.login = false,
  });
  final T Function(String) parse;
  final bool login;

  @override
  State<DataTransferTextImportDialog<T>> createState() =>
      _DataTransferTextImportDialogState<T>();
}

class _DataTransferTextImportDialogState<T extends Object>
    extends State<DataTransferTextImportDialog<T>> {
  final _controller = TextEditingController();
  final _fieldFocus = FocusNode();
  String? _error;
  bool _reading = false;

  String get _backup => widget.login ? '登录' : '设置';

  @override
  void dispose() {
    _fieldFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _active => mounted && ModalRoute.of(context)?.isCurrent == true;
  bool get _foreground => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed => true,
    _ => false,
  };

  Future<void> _fillFromClipboard() async {
    if (_reading || !_active || !_foreground) return;
    // 通过按钮填充登录备份时，不主动把剪贴板内容同步给已打开的输入法。
    if (widget.login) _fieldFocus.unfocus();
    setState(() {
      _error = null;
      _reading = true;
    });
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!_active || !_foreground) return;
      final text = data?.text;
      if (text == null || text.isEmpty) {
        setState(() => _error = '剪贴板没有文本，请手动输入。');
      } else if (!SettingsTransferService.fitsTransferLimit(text)) {
        setState(() => _error = '备份文本不能超过 2 MB。');
      } else {
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    } catch (_) {
      if (_active && _foreground) {
        setState(() => _error = '无法读取剪贴板，请手动输入。');
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _next() {
    if (_reading || !_active || !_foreground) return;
    final source = _controller.text;
    if (!SettingsTransferService.fitsTransferLimit(source)) {
      setState(() => _error = '备份文本不能超过 2 MB。');
      return;
    }
    if (source.trim().isEmpty) {
      setState(() => _error = '请输入$_backup备份文本。');
      return;
    }
    try {
      Navigator.pop<T>(context, widget.parse(source));
    } on FormatException {
      setState(() => _error = '不是有效的$_backup备份，请检查文本后重试。');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('从文本导入${widget.login ? '登录信息' : '设置'}'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            focusNode: _fieldFocus,
            readOnly: _reading,
            // 登录凭据只保留在当次编辑会话中，不明文展示或交给自动填充。
            obscureText: widget.login,
            minLines: widget.login ? 1 : 3,
            maxLines: widget.login ? 1 : 6,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            autofillHints: null,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            spellCheckConfiguration: widget.login
                ? const SpellCheckConfiguration.disabled()
                : null,
            decoration: InputDecoration(
              labelText: '$_backup JSON',
              helperText: widget.login ? '内容已隐藏，请只导入你自己的登录备份。' : null,
              helperMaxLines: 2,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          TextButton.icon(
            onPressed: _reading ? null : _fillFromClipboard,
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text('从剪贴板填充'),
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
