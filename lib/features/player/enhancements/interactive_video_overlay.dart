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
    required this.bottomInset,
    required this.onChoiceSelected,
    required this.onRetry,
  });

  final InteractiveVideoNode? node;
  final bool loading;
  final String? errorMessage;
  final double bottomInset;
  final ValueChanged<InteractiveVideoChoice> onChoiceSelected;
  final VoidCallback onRetry;

  /// 创建贴近画面底部的半透明分支按钮，并随播放栏显示状态平滑改变高度。
  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      left: 16,
      right: 16,
      bottom: bottomInset,
      child: Center(
        child: ConstrainedBox(
          key: const Key('interactive-video-choice-overlay'),
          constraints: const BoxConstraints(maxWidth: 620),
          child: Semantics(
            container: true,
            label: node?.title.isNotEmpty == true ? node!.title : '请选择剧情走向',
            child: _buildContent(),
          ),
        ),
      ),
    );
  }

  /// 根据节点加载、失败和可选择状态，返回对应的紧凑内容。
  Widget _buildContent() {
    if (loading) {
      return _buildStatusCard(
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 10),
            Text('正在加载剧情选项', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }
    if (errorMessage != null) {
      return _buildStatusCard(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                errorMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              key: const Key('retry-interactive-video-node'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
                visualDensity: VisualDensity.compact,
              ),
              // 重试按钮函数重新读取当前剧情节点，不会自动选择任何分支。
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final List<InteractiveVideoChoice> choices =
        node?.choices ?? const <InteractiveVideoChoice>[];
    if (choices.length == 2) {
      return Row(
        children: <Widget>[
          Expanded(child: _buildChoiceButton(choices[0], 0)),
          const SizedBox(width: 12),
          Expanded(child: _buildChoiceButton(choices[1], 1)),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (int index = 0; index < choices.length; index += 1)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 180, maxWidth: 280),
            child: _buildChoiceButton(choices[index], index),
          ),
      ],
    );
  }

  /// 创建无色黑灰半透明分支按钮，并保留完整点击反馈和两行文字空间。
  Widget _buildChoiceButton(InteractiveVideoChoice choice, int index) {
    return Material(
      key: ValueKey<String>('interactive-video-choice-$index'),
      color: const Color(0x70000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: const BorderSide(color: Colors.white12),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // 选择按钮函数只把用户明确点击的剧情分支交给播放器。
        onTap: () => onChoiceSelected(choice),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 50),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Center(
              child: Text(
                choice.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 为加载和失败状态提供小型深色提示卡，不让异常信息扩张为整块遮罩。
  Widget _buildStatusCard({required Widget child}) {
    return Center(
      child: Material(
        color: Colors.black.withValues(alpha: 0.78),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Colors.white12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: child,
        ),
      ),
    );
  }
}
