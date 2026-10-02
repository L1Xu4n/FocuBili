import 'package:flutter/material.dart';

/// 让搜索结果的封面、标题和操作随实际宽度与文字大小排布。
class SearchVideoRow extends StatelessWidget {
  /// 接收展示资料和既有操作，布局组件不负责查询或修改视频数据。
  const SearchVideoRow({
    super.key,
    required this.rowKey,
    required this.title,
    required this.owner,
    required this.publishedAt,
    required this.playCount,
    required this.danmakuCount,
    required this.thumbnailBuilder,
    required this.menu,
    required this.onTap,
    this.opening = false,
  });

  final Key rowKey;
  final String title;
  final String owner;
  final String publishedAt;
  final String playCount;
  final String danmakuCount;
  final Widget Function(double width) thumbnailBuilder;
  final Widget menu;
  final VoidCallback? onTap;
  final bool opening;

  /// 将图标与数字作为一个整体换行，避免统计文字挤出窄屏。
  Widget _metric(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      label: '$label $value',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color, height: 1.1),
            ),
          ),
        ],
      ),
    );
  }

  /// 标题与资料对齐封面两端，圆形菜单使用独立方形区域，不撑高统计行。
  Widget _buildDetails(BuildContext context, double coverHeight) {
    final theme = Theme.of(context);
    final byline = '$owner · $publishedAt';
    return Stack(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: coverHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 5, right: 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: byline,
                      child: Text(
                        byline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 12,
                      runSpacing: 3,
                      children: [
                        _metric(
                          context,
                          Icons.play_circle_outline_rounded,
                          '播放量',
                          playCount,
                        ),
                        _metric(
                          context,
                          Icons.subtitles_outlined,
                          '弹幕量',
                          danmakuCount,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(right: 0, bottom: 0, width: 40, height: 40, child: menu),
      ],
    );
  }

  /// 正常字号保持封面与资料齐高，放大字号可自然增高，加载提示不挤动文字。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
        final width = (constraints.maxWidth * (largeText ? .29 : .36)).clamp(
          92.0,
          160.0,
        );
        return Material(
          color: Colors.transparent,
          child: InkWell(
            key: rowKey,
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              // 右侧留出桌面滚动条区域，避免更多菜单被滚动条抢走点击。
              padding: const EdgeInsets.fromLTRB(2, 6, 12, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      thumbnailBuilder(width),
                      if (opening)
                        const Positioned.fill(
                          child: Center(
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _buildDetails(context, width * 9 / 16)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
