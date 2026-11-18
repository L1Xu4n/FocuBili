import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../services/external_link_service.dart';

/// Keeps the editable source and rendered preview on the same draft.
class VideoNoteBodyEditor extends StatefulWidget {
  const VideoNoteBodyEditor({
    super.key,
    required this.controller,
    required this.field,
  });

  final TextEditingController controller;
  final TextField field;

  @override
  State<VideoNoteBodyEditor> createState() => _VideoNoteBodyEditorState();
}

class _VideoNoteBodyEditorState extends State<VideoNoteBodyEditor> {
  bool _previewing = false;

  Future<void> _openLink(String? href) async {
    final Uri? uri = href == null ? null : Uri.tryParse(href);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('即将打开外部链接'),
        content: SelectableText(uri.toString()),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续访问'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    bool opened = false;
    try {
      opened = await launchExternalLink(uri);
    } catch (_) {
      // A browser might be unavailable on this device.
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开默认浏览器，请稍后重试。')));
    }
  }

  Widget _buildPreview(
    BuildContext context,
    TextEditingValue value,
    Widget? _,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      child: value.text.trim().isEmpty
          ? Text(
              '在正文输入 Markdown，例如 **重点**。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : SelectionArea(
              child: MarkdownBody(
                data: value.text,
                softLineBreak: true,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                    .copyWith(
                      p: widget.field.style,
                      // Wide tables scroll instead of shrinking cells until
                      // enlarged text is clipped by the column borders.
                      tableColumnWidth: const IntrinsicColumnWidth(),
                      tablePadding: const EdgeInsets.only(bottom: 8),
                      tableScrollbarThumbVisibility: true,
                    ),
                onTapLink: (_, href, _) => unawaited(_openLink(href)),
                // Show alt text without fetching images or reading paths in
                // the source. Attached screenshots have their own viewer.
                imageBuilder: (_, _, alt) =>
                    Text(alt == null || alt.isEmpty ? '［图片］' : '［图片：$alt］'),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            onPressed: () => setState(() => _previewing = !_previewing),
            icon: Icon(
              _previewing ? Icons.edit_outlined : Icons.visibility_outlined,
              size: 18,
            ),
            label: Text(_previewing ? '编辑正文' : 'Markdown 预览'),
          ),
        ),
        if (_previewing)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: _buildPreview,
          )
        else
          widget.field,
      ],
    );
  }
}
