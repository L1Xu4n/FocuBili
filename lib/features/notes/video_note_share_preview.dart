import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/video_note.dart';
import '../../services/video_note_share_service.dart';
import 'video_note_composer.dart';
import 'video_note_frames_view.dart';

/// 打开笔记长图预览；截图会在预览中加载，缺失时仍分享完整文字。
Future<void> showVideoNoteSharePreview(
  BuildContext context,
  VideoNote note, {
  VideoNoteShareService shareService = const VideoNoteShareService(),
}) async {
  if (!context.mounted) {
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        VideoNoteSharePreviewDialog(note: note, shareService: shareService),
  );
}

enum VideoNoteShareStyle {
  paper('纸页'),
  classic('经典');

  const VideoNoteShareStyle(this.label);
  final String label;
}

/// 显示完整长图预览，并只在用户确认后调用系统分享。
class VideoNoteSharePreviewDialog extends StatefulWidget {
  /// 创建冻结当前笔记草稿内容的分享预览。
  const VideoNoteSharePreviewDialog({
    super.key,
    required this.note,
    this.shareService = const VideoNoteShareService(),
  });

  final VideoNote note;
  final VideoNoteShareService shareService;

  /// 创建管理长图捕获和系统分享状态的页面状态。
  @override
  State<VideoNoteSharePreviewDialog> createState() =>
      _VideoNoteSharePreviewDialogState();
}

/// 管理分享边界，分享失败时保留预览供用户重试。
class _VideoNoteSharePreviewDialogState
    extends State<VideoNoteSharePreviewDialog> {
  final GlobalKey _boundaryKey = GlobalKey();
  final ScrollController _scroll = ScrollController();
  VideoNoteShareStyle _style = VideoNoteShareStyle.paper;
  bool _sharing = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _selectStyle(VideoNoteShareStyle style) {
    if (_sharing || style == _style) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _style = style);
  }

  /// Copies the rendered note on Windows and uses the system share sheet elsewhere.
  Future<void> _share() async {
    if (_sharing) {
      return;
    }
    setState(() => _sharing = true);
    try {
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      final Rect? origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await widget.shareService.shareBoundary(
        boundaryKey: _boundaryKey,
        fileName: 'focubili_note_${widget.note.id}',
        text: '来自焦点哔哩的时间点笔记：${widget.note.title}',
        sharePositionOrigin: origin,
      );
      if (mounted && widget.shareService.copiesToClipboard) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('图片已复制到剪贴板'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('笔记分享图片生成失败，请稍后重试。')));
      }
    } finally {
      if (mounted) {
        setState(() => _sharing = false);
      }
    }
  }

  /// 用可滚动缩放预览承载任意高度的笔记卡，不裁掉长正文或截图。
  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '笔记分享预览',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: _sharing
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final style in VideoNoteShareStyle.values)
                      ChoiceChip(
                        key: ValueKey('video-note-share-style-${style.name}'),
                        label: Text(style.label),
                        selected: _style == style,
                        onSelected: _sharing
                            ? null
                            : (_) => _selectStyle(style),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topCenter,
                      child: RepaintBoundary(
                        key: _boundaryKey,
                        child: MediaQuery.withNoTextScaling(
                          child: VideoNoteShareCard(
                            note: widget.note,
                            style: _style,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('share-video-note-card'),
                  onPressed: _sharing ? null : () => unawaited(_share()),
                  icon: _sharing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          widget.shareService.copiesToClipboard
                              ? Icons.copy
                              : Icons.ios_share_rounded,
                        ),
                  label: Text(
                    _sharing
                        ? '正在生成长图…'
                        : widget.shareService.copiesToClipboard
                        ? '复制图片'
                        : '分享图片',
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

/// 生成正文自适应高度的精美笔记卡，包含来源、时间点、截图与字数。
class VideoNoteShareCard extends StatelessWidget {
  /// 创建只读取本地笔记快照的长图卡片。
  const VideoNoteShareCard({
    super.key,
    required this.note,
    this.style = VideoNoteShareStyle.classic,
  });

  final VideoNote note;
  final VideoNoteShareStyle style;

  /// 绘制固定宽度、动态高度的长图内容。
  @override
  Widget build(BuildContext context) {
    final body = note.body.trim();
    final frames = note.allFrames;
    if (style == VideoNoteShareStyle.paper) {
      return _PaperNoteShareCard(note: note, body: body, frames: frames);
    }
    return Container(
      key: const Key('video-note-share-card'),
      width: 420,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF111A36),
            Color(0xFF243F78),
            Color(0xFF4A376D),
          ],
        ),
      ),
      child: Stack(
        children: <Widget>[
          const Positioned(
            top: -70,
            right: -55,
            child: _NoteShareGlow(size: 190, color: Color(0x334FC3F7)),
          ),
          const Positioned(
            bottom: -85,
            left: -70,
            child: _NoteShareGlow(size: 210, color: Color(0x33FF8A65)),
          ),
          Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _NoteShareBrand(),
                const SizedBox(height: 34),
                Text(
                  note.title.trim().isEmpty ? '未命名笔记' : note.title.trim(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 29,
                    height: 1.22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _NoteShareTag(
                      icon: Icons.schedule_rounded,
                      label: '时间点 · ${formatVideoNotePosition(note.position)}',
                    ),
                    _NoteShareTag(
                      icon: Icons.video_library_outlined,
                      label: 'BV · ${note.bvid}',
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '来自视频',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        note.videoTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (note.partTitle.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(
                          'P${note.partPageNumber} · ${note.partTitle}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  body.isEmpty ? '这条笔记还没有正文。' : body,
                  style: TextStyle(
                    color: body.isEmpty
                        ? Colors.white54
                        : Colors.white.withValues(alpha: 0.94),
                    fontSize: 17,
                    height: 1.68,
                  ),
                ),
                for (final (index, frame) in frames.indexed)
                  _NoteShareFrame(
                    index: index,
                    frame: frame,
                    captionColor: Colors.white70,
                    placeholderColor: Colors.transparent,
                    classic: true,
                  ),
                const SizedBox(height: 30),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        formatVideoNoteDateTime(note.createdAt),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Text(
                      '笔记 ${videoNoteCharacterCount(note.body)} 字',
                      key: const Key('video-note-share-character-count'),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The paper palette is fixed so the PNG isn't affected by the app theme.
class _PaperNoteShareCard extends StatelessWidget {
  const _PaperNoteShareCard({
    required this.note,
    required this.body,
    required this.frames,
  });

  final VideoNote note;
  final String body;
  final List<VideoNoteFrame> frames;

  static const _paper = Color(0xFFF8FAFE);
  static const _ink = Color(0xFF18243C);
  static const _muted = Color(0xFF526078);
  static const _blue = Color(0xFF244F9D);
  static const _line = Color(0xFFDCE5F4);

  @override
  Widget build(BuildContext context) {
    final title = note.title.trim();
    final partTitle = note.partTitle.trim();
    final sourceId = note.bvid.trim();
    return Container(
      key: const Key('video-note-share-card'),
      width: 420,
      color: _paper,
      padding: const EdgeInsets.fromLTRB(28, 27, 28, 25),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: _ink, fontSize: 14, height: 1.4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Image.asset(
                    'assets/icon/focubili_icon.png',
                    width: 26,
                    height: 26,
                  ),
                ),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    '焦点哔哩',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const Text(
                  '时间点笔记',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(height: 1, color: _line),
            const SizedBox(height: 22),
            Text(
              title.isEmpty ? '未命名笔记' : title,
              style: const TextStyle(
                fontSize: 32,
                height: 1.22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF1FD),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.schedule_rounded,
                        size: 15,
                        color: _blue,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          formatVideoNotePosition(note.position),
                          style: const TextStyle(
                            color: _blue,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    note.videoTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  if (partTitle.isNotEmpty || sourceId.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 12,
                      runSpacing: 2,
                      children: [
                        if (partTitle.isNotEmpty)
                          Text(
                            'P${note.partPageNumber} · $partTitle',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        if (sourceId.isNotEmpty)
                          Text(
                            sourceId,
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(body, style: const TextStyle(fontSize: 17, height: 1.72)),
            ] else if (frames.isEmpty) ...[
              const SizedBox(height: 24),
              const Text('这条笔记还没有正文。', style: TextStyle(color: _muted)),
            ],
            for (final (index, frame) in frames.indexed)
              _NoteShareFrame(
                index: index,
                frame: frame,
                captionColor: _muted,
                placeholderColor: const Color(0xFFEAF1FD),
              ),
            const SizedBox(height: 24),
            const Divider(height: 1, color: _line),
            const SizedBox(height: 13),
            Text(
              formatVideoNoteDateTime(note.createdAt),
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteShareFrame extends StatelessWidget {
  const _NoteShareFrame({
    required this.index,
    required this.frame,
    required this.captionColor,
    required this.placeholderColor,
    this.classic = false,
  });

  final int index;
  final VideoNoteFrame frame;
  final Color captionColor;
  final Color placeholderColor;
  final bool classic;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: classic ? 28 : 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '画面 ${index + 1} · ${formatVideoNoteFramePosition(frame.position)}',
          style: TextStyle(color: captionColor, fontSize: classic ? null : 12),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(classic ? 18 : 12),
          child: Image.file(
            File(frame.path),
            key: index == 0
                ? const Key('video-note-share-frame')
                : ValueKey('video-note-share-frame-$index'),
            width: double.infinity,
            fit: BoxFit.fitWidth,
            errorBuilder: (context, error, stackTrace) => ColoredBox(
              color: placeholderColor,
              child: SizedBox(
                height: classic ? 160 : 84,
                child: Center(
                  child: Text(
                    '截图无法读取',
                    style: TextStyle(
                      color: classic ? Colors.white54 : captionColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// 统计正文中除空白外的 Unicode 字符数，中文、英文和表情都按可读字符计数。
int videoNoteCharacterCount(String value) {
  return value.runes.where((int rune) {
    final String character = String.fromCharCode(rune);
    return character.trim().isNotEmpty;
  }).length;
}

/// 分享卡左上角的应用图标、名称与类型标记。
class _NoteShareBrand extends StatelessWidget {
  /// 创建固定品牌头。
  const _NoteShareBrand();

  /// 组合图标、应用名称与卡片类型。
  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset(
            'assets/icon/focubili_icon.png',
            width: 38,
            height: 38,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 11),
        const Expanded(
          child: Text(
            '焦点哔哩',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const Text(
          '时间点笔记',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

/// 分享卡的时间点或 BV 小标签。
class _NoteShareTag extends StatelessWidget {
  /// 创建一枚半透明标签。
  const _NoteShareTag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  /// 绘制小图标和单行文字。
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: const Color(0xFFAFCBFF), size: 15),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// 分享卡背景中的装饰光斑。
class _NoteShareGlow extends StatelessWidget {
  /// 创建指定大小和颜色的圆形光斑。
  const _NoteShareGlow({required this.size, required this.color});

  final double size;
  final Color color;

  /// 绘制不响应触摸的圆形色块。
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
