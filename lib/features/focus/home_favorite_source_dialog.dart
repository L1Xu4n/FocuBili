import 'package:flutter/material.dart';

/// 首页收藏总览的两个目的地平级；关闭弹窗不隐式选择任何一项。
class HomeFavoriteSourceDialog extends StatelessWidget {
  const HomeFavoriteSourceDialog({super.key});

  void _finish(BuildContext context, [bool? local]) {
    // 快速连点时，已经关闭的来源弹窗不可再弹出下方的页面。
    if (ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context, local);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      constraints: const BoxConstraints(maxWidth: 480),
      child: LayoutBuilder(
        builder: (context, size) {
          // 辅助说明重复了来源。在短窗、大字时让两个主要操作优先占用空间。
          final compact =
              size.maxWidth <
                  MediaQuery.textScalerOf(context).scale(16) * 5 + 156 ||
              size.maxHeight <
                  MediaQuery.textScalerOf(context).scale(14) * 9 + 112;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 16,
              12,
              compact ? 12 : 16,
              20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsetsDirectional.only(start: compact ? 0 : 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          namesRoute: true,
                          child: Text(
                            '我的收藏',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('home-favorite-source-close'),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: () => _finish(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _SourceButton(
                  key: const Key('home-favorite-source-local'),
                  label: '本机收藏夹',
                  detail: '保存在这台设备',
                  icon: Icons.folder_outlined,
                  iconColor: colors.onPrimaryContainer,
                  iconSurface: colors.primaryContainer,
                  compact: compact,
                  onPressed: () => _finish(context, true),
                ),
                const SizedBox(height: 10),
                _SourceButton(
                  key: const Key('home-favorite-source-bilibili'),
                  label: 'B 站收藏夹',
                  detail: '来自你的 B 站账号',
                  icon: Icons.live_tv_rounded,
                  iconColor: colors.onSecondaryContainer,
                  iconSurface: colors.secondaryContainer,
                  compact: compact,
                  onPressed: () => _finish(context, false),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SourceButton extends StatelessWidget {
  const _SourceButton({
    super.key,
    required this.label,
    required this.detail,
    required this.icon,
    required this.iconColor,
    required this.iconSurface,
    required this.compact,
    required this.onPressed,
  });

  final String label;
  final String detail;
  final IconData icon;
  final Color iconColor;
  final Color iconSurface;
  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 80),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 16,
          vertical: 12,
        ),
        foregroundColor: colors.onSurface,
        backgroundColor: colors.surfaceContainerHighest,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: onPressed,
      child: Row(
        children: [
          Container(
            width: compact ? 32 : 46,
            height: compact ? 32 : 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: iconSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: compact ? 24 : 26, color: iconColor),
          ),
          SizedBox(width: compact ? 8 : 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: colors.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
  }
}
