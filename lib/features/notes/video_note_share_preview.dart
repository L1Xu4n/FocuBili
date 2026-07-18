import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/video_note.dart';
import '../../services/video_note_share_service.dart';
import 'video_note_composer.dart';

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
  bool _sharing = false;

  /// 将完整卡片捕获为 PNG 并唤起系统分享面板。
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
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('笔记分享预览', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    onPressed: _sharing
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                  ),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: RepaintBoundary(
                      key: _boundaryKey,
                      child: VideoNoteShareCard(note: widget.note),
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
                      : const Icon(Icons.ios_share_rounded),
                  label: Text(_sharing ? '正在生成长图…' : '分享图片'),
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
  const VideoNoteShareCard({super.key, required this.note});

  final VideoNote note;

  /// 绘制固定宽度、动态高度的长图内容。
  @override
  Widget build(BuildContext context) {
    final File? frame = _existingFrame(note.framePath);
    final String body = note.body.trim();
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
                if (frame != null) ...<Widget>[
                  const SizedBox(height: 28),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.file(
                      frame,
                      key: const Key('video-note-share-frame'),
                      width: double.infinity,
                      fit: BoxFit.fitWidth,
                      // 单张旧截图损坏时显示稳定占位，不影响文字长图继续分享。
                      errorBuilder:
                          (
                            BuildContext context,
                            Object error,
                            StackTrace? stackTrace,
                          ) => const SizedBox(
                            height: 160,
                            child: Center(
                              child: Text(
                                '截图无法读取',
                                style: TextStyle(color: Colors.white54),
                              ),
                            ),
                          ),
                    ),
                  ),
                ],
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

/// 统计正文中除空白外的 Unicode 字符数，中文、英文和表情都按可读字符计数。
int videoNoteCharacterCount(String value) {
  return value.runes.where((int rune) {
    final String character = String.fromCharCode(rune);
    return character.trim().isNotEmpty;
  }).length;
}

/// 截图路径存在且可读取时返回文件，否则让分享卡只展示文字。
File? _existingFrame(String? path) {
  if (path == null || path.isEmpty) {
    return null;
  }
  final File file = File(path);
  return file.existsSync() ? file : null;
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
