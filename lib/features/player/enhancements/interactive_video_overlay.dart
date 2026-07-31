import 'package:flutter/material.dart';

import '../../../models/player_enhancement.dart';

/// 在播放器画面内显示互动剧情选择，只有用户点击后才会切换分支。
class InteractiveVideoChoiceOverlay extends StatelessWidget {
  /// 创建互动选择层，并接收加载、失败、重试和分支选择状态。
  const InteractiveVideoChoiceOverlay({
    super.key,
    required this.node,
    required this.loading,
    required this.errorMessage,
    required this.onChoiceSelected,
    required this.onRetry,
  });

  final InteractiveVideoNode? node;
  final bool loading;
  final String? errorMessage;
  final ValueChanged<InteractiveVideoChoice> onChoiceSelected;
  final VoidCallback onRetry;

  /// 创建不遮住整幅画面的底部选择卡，并根据状态展示按钮、加载或重试。
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(18, 48, 18, 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Material(
            key: const Key('interactive-video-choice-overlay'),
            color: Colors.black.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    node?.title.isNotEmpty == true ? node!.title : '请选择剧情走向',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (loading)
                    const Center(
                      child: SizedBox.square(
                        dimension: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      ),
                    )
                  else if (errorMessage != null)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          errorMessage!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          key: const Key('retry-interactive-video-node'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                          ),
                          // 重试按钮函数重新读取当前剧情节点，不会自动选择任何分支。
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重新加载选项'),
                        ),
                      ],
                    )
                  else
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        for (
                          int index = 0;
                          index < (node?.choices.length ?? 0);
                          index += 1
                        )
                          FilledButton(
                            key: ValueKey<String>(
                              'interactive-video-choice-$index',
                            ),
                            // 选择按钮函数只把用户明确点击的剧情分支交给播放器。
                            onPressed: () =>
                                onChoiceSelected(node!.choices[index]),
                            child: Text(node!.choices[index].label),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
