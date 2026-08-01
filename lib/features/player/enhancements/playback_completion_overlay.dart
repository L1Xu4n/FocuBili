import 'package:flutter/material.dart';

/// 以紧凑卡片展示普通视频完播后的学习操作，避免遮挡播放器控制栏。
class PlaybackCompletionOverlay extends StatelessWidget {
  /// 创建完播卡片，并接收学习完成状态及两个由用户主动触发的操作。
  const PlaybackCompletionOverlay({
    super.key,
    required this.hasNextPart,
    required this.markingCompleted,
    required this.onMarkCompleted,
    required this.onPlayNext,
  });

  final bool hasNextPart;
  final bool markingCompleted;
  final VoidCallback onMarkCompleted;
  final VoidCallback onPlayNext;

  /// 构建横向标题区与等宽操作按钮，把卡片高度控制在横屏播放器可用范围内。
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Material(
        key: const Key('playback-completion-prompt'),
        elevation: 10,
        color: Colors.black.withValues(alpha: 0.84),
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.check_circle_outline_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Text(
                          '这一节播放完成',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            height: 1.15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          hasNextPart
                              ? '标记学习完成，或由你决定播放下一节。'
                              : '已经是最后一节，可以标记这条学习任务完成。',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Row(
                children: <Widget>[
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: OutlinedButton.icon(
                        key: const Key('mark-learning-complete'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          visualDensity: VisualDensity.compact,
                        ),
                        // 完成按钮函数只把用户明确操作交给学习清单服务。
                        onPressed: markingCompleted ? null : onMarkCompleted,
                        icon: markingCompleted
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.task_alt_rounded, size: 19),
                        label: const Text(
                          '标记完成',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: FilledButton.icon(
                        key: const Key('play-next-after-completion'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          visualDensity: VisualDensity.compact,
                        ),
                        // 下一节按钮函数只在仍有后续分P时执行用户主动切换。
                        onPressed: hasNextPart && !markingCompleted
                            ? onPlayNext
                            : null,
                        icon: const Icon(Icons.skip_next_rounded, size: 19),
                        label: const Text(
                          '播放下一节',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
