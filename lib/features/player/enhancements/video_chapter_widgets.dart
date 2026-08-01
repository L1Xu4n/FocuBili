import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../models/player_enhancement.dart';

/// 让 B 站图片 CDN 返回与网页播放页一致的章节预览图资源。
const Map<String, String> _bilibiliChapterPreviewHeaders = <String, String>{
  'Referer': 'https://www.bilibili.com/',
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/126.0.0.0 Mobile Safari/537.36',
};

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
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8),
                    child: Center(
                      child: SizedBox(
                        width: double.infinity,
                        child: _ChapterMarqueeLabel(
                          key: ValueKey<String>('video-chapter-marquee-$index'),
                          text: chapters[index].title,
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

/// 在章节标题超过本身分段宽度时来回滚动，保证窄分段也能读到完整名称。
class _ChapterMarqueeLabel extends StatefulWidget {
  /// 创建可自动滚动、但不抢占章节点击手势的单行标题。
  const _ChapterMarqueeLabel({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  /// 创建负责测量溢出并驱动标题滚动的状态对象。
  @override
  State<_ChapterMarqueeLabel> createState() => _ChapterMarqueeLabelState();
}

/// 管理章节标题的延迟、往返滚动和页面销毁后的安全取消。
class _ChapterMarqueeLabelState extends State<_ChapterMarqueeLabel> {
  final ScrollController _scrollController = ScrollController();
  int _scrollCycleToken = 0;

  /// 首次布局完成后测量文字是否溢出，只有溢出时才开始滚动。
  @override
  void initState() {
    super.initState();
    _scheduleScrollCycle();
  }

  /// 标题或样式更新后重新测量，避免复用列表元素时滚动旧标题。
  @override
  void didUpdateWidget(covariant _ChapterMarqueeLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _scheduleScrollCycle();
    }
  }

  /// 释放滚动控制器，并让尚未完成的异步滚动安全失效。
  @override
  void dispose() {
    _scrollCycleToken += 1;
    _scrollController.dispose();
    super.dispose();
  }

  /// 在本帧结束后获取真实可滚动距离，并为当前标题启动一轮往返动画。
  void _scheduleScrollCycle() {
    final int token = ++_scrollCycleToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          token != _scrollCycleToken ||
          !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(0);
      final double distance = _scrollController.position.maxScrollExtent;
      if (distance <= 0) {
        return;
      }
      // 滚动协程只读取当前 token，标题更新或页面销毁后会自动停止。
      unawaited(_runScrollCycle(token, distance));
    });
  }

  /// 让标题停留、滚到末尾再回到开头，完整展示一次后保持静止避免持续占用动画帧。
  Future<void> _runScrollCycle(int token, double distance) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!_canContinueScrolling(token)) {
      return;
    }
    await _scrollController.animateTo(
      distance,
      duration: _scrollDurationFor(distance),
      curve: Curves.linear,
    );
    if (!_canContinueScrolling(token)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!_canContinueScrolling(token)) {
      return;
    }
    await _scrollController.animateTo(
      0,
      duration: _scrollDurationFor(distance),
      curve: Curves.linear,
    );
  }

  /// 判断延迟动画仍属于当前标题且控制器未随页面一同释放。
  bool _canContinueScrolling(int token) {
    return mounted &&
        token == _scrollCycleToken &&
        _scrollController.hasClients;
  }

  /// 根据实际溢出距离计算阅读速度，短标题不会闪动，长标题也不会过快掠过。
  Duration _scrollDurationFor(double distance) {
    final int milliseconds = (distance * 32).round().clamp(900, 5200).toInt();
    return Duration(milliseconds: milliseconds);
  }

  /// 构建裁切后的横向文字区域；滚动层忽略指针以保持整块章节可点击。
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.text,
      child: ClipRect(
        child: IgnorePointer(
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              textAlign: TextAlign.center,
              style: widget.style,
            ),
          ),
        ),
      ),
    );
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
                            key: ValueKey<String>(
                              'video-chapter-preview-$index',
                            ),
                            color: colors.surfaceContainerHighest,
                            child: const Icon(Icons.movie_filter_outlined),
                          )
                        : CachedNetworkImage(
                            key: ValueKey<String>(
                              'video-chapter-preview-$index',
                            ),
                            imageUrl: chapter.imageUrl,
                            httpHeaders: _bilibiliChapterPreviewHeaders,
                            fit: BoxFit.cover,
                            // 加载期间保持一张有比例的预览占位，避免列表看起来像漏掉了图片。
                            placeholder: (BuildContext context, String url) =>
                                ColoredBox(
                                  color: colors.surfaceContainerHighest,
                                  child: const Center(
                                    child: SizedBox.square(
                                      dimension: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                ),
                            // 图片请求失败时明确显示占位图，用户仍可点击这项章节跳转。
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
