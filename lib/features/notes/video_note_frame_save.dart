import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/local_export_service.dart';

const String videoNoteFrameSaveLabel = '保存截图到本地';

/// 让截图列表和全屏查看器共用原图另存为操作。
class VideoNoteFrameSave extends StatefulWidget {
  const VideoNoteFrameSave({
    super.key,
    required this.builder,
    this.localExportService = const LocalExportService(),
  });

  final Widget Function(BuildContext context, ValueChanged<String>? onSave)
  builder;
  final LocalExportService localExportService;

  @override
  State<VideoNoteFrameSave> createState() => _VideoNoteFrameSaveState();
}

class _VideoNoteFrameSaveState extends State<VideoNoteFrameSave> {
  bool _saving = false;

  Future<void> _save(String path) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final source = File(path);
      final bytes = await source.readAsBytes();
      if (bytes.isEmpty) {
        throw const FileSystemException('empty_frame');
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final extension = source.uri.pathSegments.last
          .split('.')
          .last
          .toLowerCase();
      final suffix = const {'png', 'jpg', 'jpeg', 'webp'}.contains(extension)
          ? extension
          : 'png';
      final result = await widget.localExportService.save(
        fileName:
            'focubili_screenshot_${DateTime.now().millisecondsSinceEpoch}.$suffix',
        bytes: bytes,
        dialogTitle: videoNoteFrameSaveLabel,
      );
      _notify(result == null ? '已取消保存截图。' : '截图已保存。');
    } on FileSystemException {
      _notify('截图文件缺失或无法读取。');
    } on LocalExportException catch (error) {
      _notify(error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _notify(String message) {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _saving ? null : _save);
}
