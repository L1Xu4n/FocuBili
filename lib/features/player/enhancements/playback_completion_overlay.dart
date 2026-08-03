import 'package:flutter/material.dart';

/// 以紧凑卡片展示学习清单任务完播后的明确完成和继续学习操作。
class PlaybackCompletionOverlay extends StatelessWidget {
  /// 创建完播卡片；所有操作都必须由用户主动点击，播放器绝不自动跳到下一项。
  const PlaybackCompletionOverlay({
    super.key,
    required this.markedCompleted,
    required this.learningFinished,
    required this.processing,
    required this.onMarkCompleted,
    required this.onContinueLearning,
  });

  /// 当前分 P 是否已被用户明确标记完成。
  final bool markedCompleted;

  /// 点击“继续学习”后是否确认清单中已没有后续未完成任务。
  final bool learningFinished;

  /// 当前是否正在写入完成状态或加载下一条学习任务。
  final bool processing;

  /// 用户点击“标记已完成”时执行的状态更新回调。
  final VoidCallback onMarkCompleted;

  /// 用户点击“继续学习”时执行的按清单顺序跳转回调。
  final VoidCallback onContinueLearning;

  /// 根据当前完成状态生成卡片的标题，避免用户误以为视频会自动连播。
  String _title() {
    if (learningFinished) {
      return '已完成学习';
    }
    return markedCompleted ? '已标记完成' : '这一项播放完成';
  }

  /// 根据当前完成状态生成下一步说明，明确最后一项的继续学习结果。
  String _description() {
    if (learningFinished) {
      return '学习清单内的全部视频都已完成。';
    }
    if (markedCompleted) {
      return '可以继续学习，应用会按学习清单中的顺序打开下一项。';
    }
    return '标记此分 P 完成，或继续学习并按清单顺序打开下一项。';
  }

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
                  Icon(
                    learningFinished || markedCompleted
                        ? Icons.task_alt_rounded
                        : Icons.check_circle_outline_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          _title(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            height: 1.15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _description(),
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
              if (!learningFinished) ...<Widget>[
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
                          // 完成按钮函数只把用户明确操作交给当前分 P 的学习任务。
                          onPressed: processing || markedCompleted
                              ? null
                              : onMarkCompleted,
                          icon: processing && !markedCompleted
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  markedCompleted
                                      ? Icons.task_alt_rounded
                                      : Icons.task_alt_outlined,
                                  size: 19,
                                ),
                          label: Text(
                            markedCompleted ? '已标记完成' : '标记已完成',
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
                          key: const Key('continue-learning-after-completion'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            visualDensity: VisualDensity.compact,
                          ),
                          // 继续按钮函数只在用户点击后完成当前任务并按学习清单顺序跳转。
                          onPressed: processing ? null : onContinueLearning,
                          icon: processing && markedCompleted
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.play_arrow_rounded, size: 19),
                          label: const Text(
                            '继续学习',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
