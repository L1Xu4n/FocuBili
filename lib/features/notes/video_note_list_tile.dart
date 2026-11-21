import 'package:flutter/material.dart';

import '../../models/video_note.dart';
import '../common/app_network_image.dart';
import 'video_note_composer.dart';

/// 笔记正文是列表的主内容，视频封面只作为来源的辅助标记。
class VideoNoteListTile extends StatelessWidget {
  const VideoNoteListTile({
    super.key,
    required this.note,
    required this.query,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
    this.selectionHandleKey,
  });

  final VideoNote note;
  final String query;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final Key? selectionHandleKey;

  String _shorten(String text, int limit) {
    final head = text.characters.take(limit).toString();
    return head.length < text.length ? '$head…' : head;
  }

  Widget _excerpt(ThemeData theme) {
    final colors = theme.colorScheme;
    final body = note.body.trim().replaceAll(RegExp(r'\s+'), ' ');
    final term = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    final match = term.isEmpty
        ? null
        : RegExp(RegExp.escape(term), caseSensitive: false).firstMatch(body);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    if (match == null) {
      return Text(
        _shorten(body, 120),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    // 保留少量命中前文但不把关键词推到两行以外；不要截断 emoji 等组合字形。
    final before = body.substring(0, match.start);
    final lead = before.characters.takeLast(5).toString();

    return Text.rich(
      TextSpan(
        children: [
          if (match.start > 0)
            TextSpan(text: before.length > lead.length ? '…$lead' : lead),
          TextSpan(
            text: body.substring(match.start, match.end),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: colors.primary,
            ),
          ),
          TextSpan(text: _shorten(body.substring(match.end), 120)),
        ],
      ),
      style: style,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _source(ThemeData theme) {
    final colors = theme.colorScheme;
    final time = formatVideoNotePosition(note.position);
    final metadata = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Row(
      children: [
        if (note.videoCoverUrl.isNotEmpty) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: SizedBox(
              width: 48,
              height: 27,
              child: ExcludeSemantics(
                child: AppNetworkImage(
                  key: Key('managed-video-note-cover-${note.id}'),
                  imageUrl: note.videoCoverUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => _CoverPlaceholder(colors: colors),
                  errorWidget: (_, _, _) => _CoverPlaceholder(colors: colors),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    time,
                    semanticsLabel: '视频时间点 $time',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    note.videoTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: metadata,
                  ),
                ],
              ),
              Text(formatVideoNoteDateTime(note.createdAt), style: metadata),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selectedHere = selecting && selected;
    final card = Card(
      semanticContainer: false,
      margin: EdgeInsets.zero,
      color: selectedHere ? colors.secondaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selectedHere
            ? BorderSide(color: colors.primary, width: 1.5)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: selecting ? null : onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        note.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (selecting)
                    SizedBox.square(
                      key: selectionHandleKey,
                      dimension: 48,
                      child: ExcludeSemantics(
                        child: Icon(
                          selectedHere
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          color: selectedHere
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    PopupMenuButton<String>(
                      key: Key('managed-video-note-menu-${note.id}'),
                      tooltip: '笔记操作',
                      onSelected: (_) => onDelete(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.delete_outline_rounded),
                            title: Text('删除笔记'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              if (note.body.trim().isNotEmpty) ...[
                _excerpt(theme),
                const SizedBox(height: 10),
              ],
              _source(theme),
            ],
          ),
        ),
      ),
    );
    // 选择时整行只保留一个带勾选状态、笔记名称和切换动作的语义节点。
    return selecting
        ? MergeSemantics(
            child: Semantics(checked: selectedHere, child: card),
          )
        : card;
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.colors});
  final ColorScheme colors;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: colors.surfaceContainerHighest,
    child: Icon(
      Icons.ondemand_video_rounded,
      size: 16,
      color: colors.onSurfaceVariant,
    ),
  );
}
