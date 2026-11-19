import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_favorites_backup.dart';

/// 本机收藏备份的载体；两种方式读写同一种 JSON。
enum FavoriteBackupMethod { file, text }

Future<FavoriteBackupMethod?> chooseFavoriteBackupMethod(
  BuildContext context, {
  required bool importing,
}) => showDialog<FavoriteBackupMethod>(
  context: context,
  builder: (dialogContext) => SimpleDialog(
    title: Text(importing ? '选择导入方式' : '选择导出方式'),
    children: [
      ListTile(
        key: const Key('app-favorites-method-file'),
        leading: const Icon(Icons.insert_drive_file_outlined),
        title: Text(importing ? '从文件导入' : '保存为文件'),
        subtitle: const Text('JSON 备份文件'),
        onTap: () => Navigator.pop(dialogContext, FavoriteBackupMethod.file),
      ),
      ListTile(
        key: const Key('app-favorites-method-text'),
        leading: Icon(importing ? Icons.content_paste : Icons.copy_rounded),
        title: Text(importing ? '从文本导入' : '复制为文本'),
        subtitle: Text(importing ? '粘贴或输入收藏夹备份' : '直接复制到剪贴板'),
        onTap: () => Navigator.pop(dialogContext, FavoriteBackupMethod.text),
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(end: 16),
          child: TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ),
      ),
    ],
  ),
);

/// 仅在用户主动请求时读取剪贴板；预览不会写入本机收藏。
class FavoriteBackupTextDialog extends StatefulWidget {
  const FavoriteBackupTextDialog({super.key});

  @override
  State<FavoriteBackupTextDialog> createState() =>
      _FavoriteBackupTextDialogState();
}

class _FavoriteBackupTextDialogState extends State<FavoriteBackupTextDialog> {
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
        setState(() => _error = '剪贴板没有文本，可手动输入或粘贴。');
      } else {
        AppFavoritesBackup.checkTextSize(text);
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    } on FormatException catch (error) {
      if (_active) setState(() => _error = error.message);
    } catch (_) {
      if (_active) setState(() => _error = '无法读取剪贴板，请手动粘贴。');
    } finally {
      if (_active) setState(() => _reading = false);
    }
  }

  void _preview() {
    if (!_active || _reading) return;
    try {
      final backup = AppFavoritesBackup.fromText(_controller.text);
      Navigator.pop(context, backup);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('从文本导入'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('app-favorites-backup-text'),
            controller: _controller,
            readOnly: _reading,
            minLines: 3,
            maxLines: 6,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '备份 JSON',
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
        onPressed: _reading ? null : _preview,
        child: const Text('预览导入'),
      ),
    ],
  );
}
