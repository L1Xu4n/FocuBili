import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/video_note.dart';
import 'video_note_composer.dart' show formatVideoNotePosition;

String formatVideoNoteFramePosition(Duration position) {
  final base = formatVideoNotePosition(position);
  final milliseconds = position.inMilliseconds.remainder(1000);
  return milliseconds == 0
      ? base
      : '$base.${milliseconds.toString().padLeft(3, '0')}';
}

/// 展示每张画面的顺序及时间；可选编辑回调只更新草稿，保存后才清理文件。
class VideoNoteFramesView extends StatelessWidget {
  const VideoNoteFramesView({
    super.key,
    required this.frames,
    this.onChanged,
    this.onOpen,
    this.enabled = true,
    this.maxFrameHeight = 240,
  }) : assert(maxFrameHeight > 0);
  final List<VideoNoteFrame> frames;
  final ValueChanged<List<VideoNoteFrame>>? onChanged;
  final ValueChanged<VideoNoteFrame>? onOpen;
  final bool enabled;

  /// 每张图片的高度上限；紧凑编辑器按视口计算，详情页沿用默认高度。
  final double maxFrameHeight;

  void _move(int index, int delta) {
    final next = List<VideoNoteFrame>.of(frames);
    final frame = next.removeAt(index);
    next.insert(index + delta, frame);
    onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (int index = 0; index < frames.length; index++)
        Padding(
          key: ValueKey('note-frame-$index'),
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '画面 ${index + 1} · ${formatVideoNoteFramePosition(frames[index].position)}',
                    ),
                  ),
                  if (onChanged != null) ...[
                    IconButton(
                      key: ValueKey('move-note-frame-up-$index'),
                      tooltip: '画面前移',
                      onPressed: enabled && index > 0
                          ? () => _move(index, -1)
                          : null,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    ),
                    IconButton(
                      key: ValueKey('move-note-frame-down-$index'),
                      tooltip: '画面后移',
                      onPressed: enabled && index < frames.length - 1
                          ? () => _move(index, 1)
                          : null,
                      icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                    ),
                    IconButton(
                      key: ValueKey('remove-note-frame-$index'),
                      tooltip: '移除这张画面',
                      onPressed: enabled
                          ? () => onChanged!(
                              List<VideoNoteFrame>.of(frames)..removeAt(index),
                            )
                          : null,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ],
                ],
              ),
              InkWell(
                key: index == 0
                    ? const Key('open-note-frame-fullscreen')
                    : ValueKey('open-note-frame-$index'),
                onTap: onOpen == null ? null : () => onOpen!(frames[index]),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxFrameHeight),
                    child: Image.file(
                      File(frames[index].path),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stack) => Container(
                        height: 100,
                        alignment: Alignment.center,
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: const Text('画面文件缺失或无法读取'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
