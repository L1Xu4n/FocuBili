import 'dart:io';

import 'package:flutter/material.dart';

/// 将视频时间点格式化为 mm:ss 或 h:mm:ss。
String formatVideoNotePosition(Duration position) {
  final int seconds = position.inSeconds.clamp(0, 604800);
  final int hours = seconds ~/ 3600;
  final int minutes = (seconds % 3600) ~/ 60;
  final int rest = seconds % 60;
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
      : '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}

/// 将本机笔记时间格式化为容易阅读的完整日期和分钟。
String formatVideoNoteDateTime(DateTime dateTime) {
  final DateTime local = dateTime.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// 提供标题、正文、自动时间、视频位置和可选画面的通用笔记编辑器。
class VideoNoteComposer extends StatelessWidget {
  /// 创建播放器竖屏与全屏面板都能复用的时间点笔记编辑器。
  const VideoNoteComposer({
    super.key,
    required this.titleController,
    required this.bodyController,
    required this.position,
    required this.includeFrame,
    required this.saving,
    required this.onIncludeFrameChanged,
    required this.onSave,
    required this.onNew,
    required this.onClose,
    this.createdAt,
    this.framePath,
    this.onDelete,
    this.compact = false,
    this.borderless = false,
  });

  final TextEditingController titleController;
  final TextEditingController bodyController;
  final Duration position;
  final DateTime? createdAt;
  final bool includeFrame;
  final String? framePath;
  final bool saving;
  final ValueChanged<bool> onIncludeFrameChanged;
  final VoidCallback onSave;
  final VoidCallback onNew;
  final VoidCallback onClose;
  final VoidCallback? onDelete;
  final bool compact;
  final bool borderless;

  /// 创建全屏使用的单行紧凑头部，把标题、时间和操作压缩到同一行。
  Widget _buildCompactHeader(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String recordedText = createdAt == null
        ? '保存时记录'
        : formatVideoNoteDateTime(createdAt!);
    return Row(
      key: const Key('compact-note-header'),
      children: <Widget>[
        Text(
          '时间点笔记',
          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 18,
                  child: _VideoNoteOverflowMarquee(
                    key: const Key('note-recorded-time-marquee'),
                    text: recordedText,
                    style:
                        textTheme.labelSmall ?? const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '视频位置：${formatVideoNotePosition(position)}',
                key: const Key('note-position-label'),
                maxLines: 1,
                style: textTheme.labelSmall,
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('new-video-note'),
          // 紧凑新建按钮函数清空当前编辑内容并记录此刻的视频位置。
          onPressed: saving ? null : onNew,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          iconSize: 20,
          icon: const Icon(Icons.note_add_outlined),
          tooltip: '新建笔记',
        ),
        const SizedBox(width: 2),
        IconButton(
          key: const Key('close-video-notes'),
          // 紧凑关闭按钮函数退出笔记工作区。
          onPressed: saving ? null : onClose,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          iconSize: 20,
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭笔记',
        ),
      ],
    );
  }

  /// 创建竖屏使用的完整头部，分两行显示操作与自动记录信息。
  Widget _buildRegularHeader(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String recordedText = createdAt == null
        ? '保存时自动填写'
        : formatVideoNoteDateTime(createdAt!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '时间点笔记',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              key: const Key('new-video-note'),
              // 新建按钮函数清空当前编辑内容，并记录按钮按下时的视频位置。
              onPressed: saving ? null : onNew,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              iconSize: 21,
              icon: const Icon(Icons.note_add_outlined),
              tooltip: '新建笔记',
            ),
            const SizedBox(width: 2),
            IconButton(
              key: const Key('close-video-notes'),
              // 关闭按钮函数退出笔记面板，不会自动提交未保存的内容。
              onPressed: saving ? null : onClose,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              iconSize: 21,
              icon: const Icon(Icons.close_rounded),
              tooltip: '关闭笔记',
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: <Widget>[
            Icon(
              Icons.schedule_rounded,
              size: 15,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: SizedBox(
                height: 18,
                child: _VideoNoteOverflowMarquee(
                  text: recordedText,
                  style: textTheme.bodySmall ?? const TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  formatVideoNotePosition(position),
                  key: const Key('note-position-label'),
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 创建按图片原比例自适应宽高的画面预览，避免横屏截图两侧出现大块黑边。
  Widget _buildFramePreview(BuildContext context) {
    final String? path = framePath;
    if (!includeFrame || path == null || path.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: Alignment.centerRight,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width,
              maxHeight: compact ? 108 : 160,
            ),
            child: Image.file(
              File(path),
              key: const Key('note-frame-preview'),
              fit: BoxFit.contain,
              // 画面文件读取失败函数保留明确提示，文字笔记仍然可以继续保存。
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stackTrace) {
                    return Container(
                      width: compact ? 210 : 280,
                      height: compact ? 70 : 96,
                      alignment: Alignment.center,
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: const Text('已保存的画面文件不存在'),
                    );
                  },
            ),
          ),
        ),
      ),
    );
  }

  /// 构建笔记输入区以及新建、删除、关闭和保存操作。
  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final InputBorder fieldBorder = borderless
        ? InputBorder.none
        : const OutlineInputBorder();
    final EdgeInsetsGeometry fieldPadding = borderless
        ? const EdgeInsets.symmetric(vertical: 6)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 14);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (compact)
          _buildCompactHeader(context)
        else
          _buildRegularHeader(context),
        SizedBox(height: borderless ? 0 : 8),
        TextField(
          key: const Key('note-title-field'),
          controller: titleController,
          enabled: !saving,
          maxLength: 80,
          minLines: 1,
          maxLines: borderless ? 1 : 1,
          style: borderless
              ? textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  height: 1.2,
                )
              : null,
          decoration: InputDecoration(
            labelText: borderless ? null : '笔记标题',
            hintText: '例如：这个观点很重要',
            filled: !borderless,
            fillColor: borderless ? Colors.transparent : null,
            border: fieldBorder,
            enabledBorder: fieldBorder,
            focusedBorder: fieldBorder,
            counterText: '',
            contentPadding: fieldPadding,
          ),
        ),
        if (borderless) const Divider(height: 8) else const SizedBox(height: 8),
        TextField(
          key: const Key('note-body-field'),
          controller: bodyController,
          enabled: !saving,
          minLines: borderless ? (compact ? 4 : 3) : (compact ? 3 : 4),
          maxLines: borderless ? (compact ? 9 : 7) : (compact ? 5 : 8),
          maxLength: 6000,
          style: borderless
              ? textTheme.bodyLarge?.copyWith(height: 1.45)
              : null,
          decoration: InputDecoration(
            labelText: borderless ? null : '正文',
            hintText: '写下此刻的想法…',
            filled: !borderless,
            fillColor: borderless ? Colors.transparent : null,
            alignLabelWithHint: true,
            border: fieldBorder,
            enabledBorder: fieldBorder,
            focusedBorder: fieldBorder,
            contentPadding: fieldPadding,
          ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilterChip(
              key: const Key('include-current-frame'),
              selected: includeFrame,
              avatar: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('插入时间点画面'),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              // 画面选择函数只记录用户选择，真正截图会在保存时执行。
              onSelected: saving ? null : onIncludeFrameChanged,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (onDelete != null)
                  IconButton(
                    key: const Key('delete-video-note'),
                    // 删除按钮函数移除当前笔记及其独占的本机画面文件。
                    onPressed: saving ? null : onDelete,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline_rounded),
                    tooltip: '删除笔记',
                  ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  key: const Key('save-video-note'),
                  // 保存按钮函数由播放器写入自动时间、视频位置和可选画面。
                  onPressed: saving ? null : onSave,
                  icon: saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(saving ? '保存中' : '保存'),
                ),
              ],
            ),
          ],
        ),
        _buildFramePreview(context),
      ],
    );
  }
}

/// 在可用宽度不足时自动横向滚动笔记信息，短文字保持静止。
class _VideoNoteOverflowMarquee extends StatefulWidget {
  /// 创建只在文字溢出时启动的单行滚动文本。
  const _VideoNoteOverflowMarquee({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  /// 创建并管理文字宽度测量与循环动画状态。
  @override
  State<_VideoNoteOverflowMarquee> createState() =>
      _VideoNoteOverflowMarqueeState();
}

/// 管理笔记信息的无缝横向滚动动画。
class _VideoNoteOverflowMarqueeState extends State<_VideoNoteOverflowMarquee>
    with SingleTickerProviderStateMixin {
  static const double _textGap = 28;
  late final AnimationController _controller;
  double _travelDistance = 0;
  String? _animationSignature;
  bool _elementActive = true;

  /// 创建动画控制器；只有测量出文字溢出后才会真正启动。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  /// 文字或样式改变时停止旧动画，等待下一次布局重新测量。
  @override
  void didUpdateWidget(covariant _VideoNoteOverflowMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _stopAnimation();
    }
  }

  /// 组件重新进入页面时恢复活动状态。
  @override
  void activate() {
    super.activate();
    _elementActive = true;
  }

  /// 组件暂时离开页面时停止动画，避免后台继续刷新。
  @override
  void deactivate() {
    _elementActive = false;
    _controller.stop();
    _animationSignature = null;
    super.deactivate();
  }

  /// 停止并清空当前滚动距离，供新内容重新计算。
  void _stopAnimation() {
    _controller.stop();
    _controller.reset();
    _animationSignature = null;
    _travelDistance = 0;
  }

  /// 在本帧结束后按文字长度启动匀速循环动画。
  void _scheduleAnimation(double travelDistance) {
    final String signature = '${widget.text}:$travelDistance';
    if (_animationSignature == signature) {
      return;
    }
    _animationSignature = signature;
    _travelDistance = travelDistance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_elementActive || _animationSignature != signature) {
        return;
      }
      final int milliseconds = (travelDistance / 26 * 1000)
          .round()
          .clamp(4200, 18000)
          .toInt();
      _controller
        ..duration = Duration(milliseconds: milliseconds)
        ..repeat();
    });
  }

  /// 释放动画控制器，避免离开笔记页后继续占用资源。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 测量文字宽度并构建静态文本或两份首尾相接的滚动文本。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        if (!constraints.hasBoundedWidth ||
            painter.width <= constraints.maxWidth) {
          if (_animationSignature != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _elementActive) {
                _stopAnimation();
              }
            });
          }
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        _scheduleAnimation(painter.width + _textGap);
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            // 动画构建函数同时移动两份文字，形成首尾连续的滚动效果。
            builder: (BuildContext context, Widget? child) {
              final double offset = _travelDistance * _controller.value;
              return Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: -offset,
                    top: 0,
                    child: Text(widget.text, maxLines: 1, style: widget.style),
                  ),
                  Positioned(
                    left: painter.width + _textGap - offset,
                    top: 0,
                    child: Text(widget.text, maxLines: 1, style: widget.style),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
