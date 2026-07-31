import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../models/player_enhancement.dart';

/// 把章节时间转换为 00:00 或 1:00:00，供进度条面板统一显示。
String _formatChapterTime(Duration value) {
  final int hours = value.inHours;
  final int minutes = value.inMinutes.remainder(60);
  final int seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 在竖屏使用底部面板、横屏使用右侧面板展示全部视频分段。
Future<void> showVideoChapterPanel({
  required BuildContext context,
  required List<VideoChapter> chapters,
  required Duration position,
  required bool chapterProgressVisible,
  required ValueChanged<Duration> onSeek,
  required VoidCallback onToggleChapterProgress,
}) async {
  final bool landscape =
      MediaQuery.orientationOf(context) == Orientation.landscape;
  final Widget panel = VideoChapterPanel(
    chapters: chapters,
    position: position,
    chapterProgressVisible: chapterProgressVisible,
    onSeek: onSeek,
    onToggleChapterProgress: onToggleChapterProgress,
  );
  if (!landscape) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return FractionallySizedBox(heightFactor: 0.72, child: panel);
      },
    );
    return;
  }
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭分段信息',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> primaryAnimation,
          Animation<double> secondaryAnimation,
        ) {
          return Align(
            alignment: Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.56,
              heightFactor: 1,
              child: Material(
                key: const Key('video-chapter-side-panel'),
                color: Theme.of(dialogContext).colorScheme.surface,
                child: SafeArea(child: panel),
              ),
            ),
          );
        },
    transitionBuilder:
        (
          BuildContext dialogContext,
          Animation<double> primaryAnimation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: primaryAnimation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: child,
          );
        },
  );
}

/// 按真实时长比例绘制章节条，并允许点击任意章节跳转到开始位置。
class VideoChapterStrip extends StatelessWidget {
  /// 创建章节进度条；紧凑模式用于播放器控制层，普通模式用于竖屏详情页。
  const VideoChapterStrip({
    super.key,
    required this.chapters,
    required this.position,
    required this.onSeek,
    this.compact = false,
    this.onDarkSurface = false,
  });

  final List<VideoChapter> chapters;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  final bool compact;
  final bool onDarkSurface;

  /// 创建按章节时长分配宽度的横向分段条。
  @override
  Widget build(BuildContext context) {
    if (chapters.isEmpty) {
      return const SizedBox.shrink();
    }
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int activeIndex = _activeChapterIndex();
    return SizedBox(
      key: const Key('video-chapter-strip'),
      height: compact ? 24 : 40,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int index = 0; index < chapters.length; index += 1) ...<Widget>[
            Expanded(
              flex: math.max(chapters[index].duration.inMilliseconds, 1),
              child: Material(
                color: index == activeIndex
                    ? colors.primary.withValues(alpha: compact ? 0.72 : 0.2)
                    : onDarkSurface
                    ? Colors.black45
                    : colors.surfaceContainerHighest,
                child: InkWell(
                  key: ValueKey<String>('video-chapter-strip-$index'),
                  // 章节条点击函数只跳到对应开始时间，不自动改变播放或暂停状态。
                  onTap: () => onSeek(chapters[index].start),
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 4 : 8,
                      ),
                      child: Text(
                        chapters[index].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: onDarkSurface
                              ? Colors.white
                              : index == activeIndex
                              ? colors.primary
                              : colors.onSurfaceVariant,
                          fontSize: compact ? 10 : 12,
                          fontWeight: index == activeIndex
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (index < chapters.length - 1)
              ColoredBox(
                color: onDarkSurface ? Colors.white38 : colors.outlineVariant,
                child: const SizedBox(width: 1),
              ),
          ],
        ],
      ),
    );
  }

  /// 返回当前播放位置命中的章节序号，章节间存在空隙时返回 -1。
  int _activeChapterIndex() {
    for (int index = 0; index < chapters.length; index += 1) {
      if (chapters[index].contains(
        position,
        isLast: index == chapters.length - 1,
      )) {
        return index;
      }
    }
    return -1;
  }
}

/// 展示章节预览图、名称、时间范围和分段进度条开关。
class VideoChapterPanel extends StatefulWidget {
  /// 创建分段信息面板，并接收跳转与显示开关回调。
  const VideoChapterPanel({
    super.key,
    required this.chapters,
    required this.position,
    required this.chapterProgressVisible,
    required this.onSeek,
    required this.onToggleChapterProgress,
  });

  final List<VideoChapter> chapters;
  final Duration position;
  final bool chapterProgressVisible;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onToggleChapterProgress;

  /// 创建保存面板内开关即时状态的组件状态。
  @override
  State<VideoChapterPanel> createState() => _VideoChapterPanelState();
}

/// 管理分段面板开关，并构建可滚动的章节列表。
class _VideoChapterPanelState extends State<VideoChapterPanel> {
  late bool _chapterProgressVisible;

  /// 从播放器当前设置初始化面板内的开关。
  @override
  void initState() {
    super.initState();
    _chapterProgressVisible = widget.chapterProgressVisible;
  }

  /// 切换面板开关，并通知播放器立即显示或隐藏章节条。
  void _toggleChapterProgress(bool visible) {
    if (visible == _chapterProgressVisible) {
      return;
    }
    setState(() => _chapterProgressVisible = visible);
    widget.onToggleChapterProgress();
  }

  /// 创建标题、分段进度条开关和带真实预览图的章节列表。
  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('video-chapter-panel'),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 10, 10),
          child: Row(
            children: <Widget>[
              Text(
                '分段信息',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              const Text('分段进度条'),
              Switch(
                key: const Key('video-chapter-progress-toggle'),
                value: _chapterProgressVisible,
                // 开关函数同步面板状态和播放器时间轴显示状态。
                onChanged: _toggleChapterProgress,
              ),
              IconButton(
                // 关闭按钮函数只收起分段面板，不改变播放状态。
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: widget.chapters.length,
            separatorBuilder: (BuildContext context, int index) {
              return const SizedBox(height: 14);
            },
            itemBuilder: (BuildContext context, int index) {
              return _buildChapterItem(context, index);
            },
          ),
        ),
      ],
    );
  }

  /// 创建单个章节行，当前章节使用主题色，点击后跳转并关闭面板。
  Widget _buildChapterItem(BuildContext context, int index) {
    final VideoChapter chapter = widget.chapters[index];
    final bool selected = chapter.contains(
      widget.position,
      isLast: index == widget.chapters.length - 1,
    );
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey<String>('video-chapter-item-$index'),
        // 章节行点击函数跳到对应开始时间，并关闭当前分段面板。
        onTap: () {
          widget.onSeek(chapter.start);
          Navigator.of(context).pop();
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 156,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: chapter.imageUrl.isEmpty
                        ? ColoredBox(
                            color: colors.surfaceContainerHighest,
                            child: const Icon(Icons.movie_filter_outlined),
                          )
                        : CachedNetworkImage(
                            imageUrl: chapter.imageUrl,
                            fit: BoxFit.cover,
                            errorWidget:
                                (
                                  BuildContext context,
                                  String url,
                                  Object error,
                                ) {
                                  return ColoredBox(
                                    color: colors.surfaceContainerHighest,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                    ),
                                  );
                                },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        chapter.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: selected ? colors.primary : null,
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${_formatChapterTime(chapter.start)} - '
                        '${_formatChapterTime(chapter.end)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
