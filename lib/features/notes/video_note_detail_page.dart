import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../features/player/player_page.dart';
import '../../models/video_note.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../../services/video_note_service.dart';
import 'video_note_composer.dart';

/// 允许测试替换播放器目标页，同时保留视频、分P和时间点三项跳转参数。
typedef VideoNotePlayerBuilder = Widget Function(
  VideoPreview video,
  int initialPartCid,
  Duration initialPosition,
);

/// 在独立页面中阅读和编辑一条时间点笔记，并在正文末尾展示可选视频截图。
class VideoNoteDetailPage extends StatefulWidget {
  /// 创建笔记详情页，并复用列表持有的本机笔记服务完成保存和删除。
  const VideoNoteDetailPage({
    super.key,
    required this.note,
    required this.noteService,
    this.videoService,
    this.playerBuilder,
  });

  final VideoNote note;
  final VideoNoteService noteService;
  final BilibiliService? videoService;
  final VideoNotePlayerBuilder? playerBuilder;

  /// 创建负责详情编辑、截图预览和保存状态的页面状态。
  @override
  State<VideoNoteDetailPage> createState() => _VideoNoteDetailPageState();
}

/// 管理单条笔记的输入控制器、保存、删除和全屏截图浏览。
class _VideoNoteDetailPageState extends State<VideoNoteDetailPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final BilibiliService _videoService;
  late VideoNote _note;
  bool _saving = false;
  bool _openingVideo = false;
  bool _allowPop = false;

  /// 用当前笔记内容初始化标题和正文输入控制器。
  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _titleController = TextEditingController(text: _note.title);
    _bodyController = TextEditingController(text: _note.body);
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _titleController.addListener(_handleDraftChanged);
    _bodyController.addListener(_handleDraftChanged);
  }

  /// 页面销毁时释放两个输入控制器，避免它们继续占用系统输入资源。
  @override
  void dispose() {
    _titleController.removeListener(_handleDraftChanged);
    _bodyController.removeListener(_handleDraftChanged);
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  /// 判断当前输入是否与最后一次保存内容不同，用于拦截误退出。
  bool get _hasUnsavedChanges {
    return _titleController.text.trim() != _note.title ||
        _bodyController.text.trim() != _note.body;
  }

  /// 输入变化时刷新 PopScope，让返回按钮立即知道是否需要提醒保存。
  void _handleDraftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 校验标题并把详情页中的修改保存回本机笔记服务。
  Future<void> _saveNote() async {
    final String title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请填写笔记标题。')));
      return;
    }
    setState(() => _saving = true);
    try {
      final VideoNote updated = _note.copyWith(
        title: title,
        body: _bodyController.text.trim(),
        updatedAt: DateTime.now(),
      );
      await widget.noteService.saveNote(updated);
      if (!mounted) {
        return;
      }
      setState(() {
        _note = updated;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('笔记已保存。')));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('保存失败，请稍后重试。')));
    }
  }

  /// 二次确认后删除当前笔记和它独占的视频截图，并返回笔记列表。
  Future<void> _deleteNote() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除“${_note.title}”吗？'),
        actions: <Widget>[
          TextButton(
            // 取消函数关闭确认框并保留当前笔记。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认函数把删除意图返回详情页，由服务统一清理文字和截图。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.noteService.deleteNote(_note.id);
    if (mounted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop(true);
    }
  }

  /// 在存在未保存修改时询问用户，确认后才允许离开详情页。
  Future<bool> _confirmDiscardChanges() async {
    if (!_hasUnsavedChanges) {
      return true;
    }
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('退出后，本次修改会丢失。确定不保存并退出吗？'),
        actions: <Widget>[
          TextButton(
            // 继续编辑函数关闭提醒并留在当前详情页。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            // 放弃修改函数确认退出，原笔记内容保持最后一次保存状态。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('不保存并退出'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  /// 处理系统和顶部返回操作，脏数据必须确认后才真正退出页面。
  Future<void> _handlePopInvoked(bool didPop) async {
    if (didPop || _allowPop) {
      return;
    }
    final bool discard = await _confirmDiscardChanges();
    if (!mounted || !discard) {
      return;
    }
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  /// 从公开视频信息中优先匹配原 cid，失效时按分P序号匹配，最后回退默认分P。
  VideoPart _findNotePart(VideoPreview video) {
    for (final VideoPart part in video.parts) {
      if (part.cid == _note.partCid) {
        return part;
      }
    }
    for (final VideoPart part in video.parts) {
      if (part.pageNumber == _note.partPageNumber) {
        return part;
      }
    }
    return video.initialPart;
  }

  /// 查询笔记视频的最新分P信息，并打开对应分P和记录时间点。
  Future<void> _openSourceVideo() async {
    if (_openingVideo) {
      return;
    }
    setState(() => _openingVideo = true);
    try {
      final VideoPreview video = await _videoService.lookupVideo(_note.bvid);
      final VideoPart part = _findNotePart(video);
      if (!mounted) {
        return;
      }
      final Widget destination = widget.playerBuilder?.call(
            video,
            part.cid,
            _note.position,
          ) ??
          PlayerPage(
            video: video,
            bilibiliService: _videoService,
            initialPartCid: part.cid,
            initialPosition: _note.position,
          );
      setState(() => _openingVideo = false);
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          // 播放页构建函数带上笔记记录的分P编号和绝对时间点。
          builder: (BuildContext context) => destination,
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _openingVideo = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('暂时无法打开这条笔记对应的视频。')));
    }
  }

  /// 打开黑色全屏画面浏览页，支持双指缩放和平移查看细节。
  Future<void> _openFrameFullscreen(String framePath) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            VideoNoteFrameViewerPage(framePath: framePath),
      ),
    );
  }

  /// 构建视频来源卡片中的 16:9 封面；缺失或加载失败时显示稳定占位图。
  Widget _buildVideoCover() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (_note.videoCoverUrl.isEmpty) {
      return Container(
        key: const Key('note-detail-cover-placeholder'),
        color: colors.surfaceVariant,
        alignment: Alignment.center,
        child: const Icon(Icons.ondemand_video_rounded),
      );
    }
    return CachedNetworkImage(
      key: const Key('note-detail-video-cover'),
      imageUrl: _note.videoCoverUrl,
      fit: BoxFit.cover,
      // 封面加载函数使用轻量进度指示，不阻塞笔记正文阅读。
      placeholder: (BuildContext context, String url) => Container(
        color: colors.surfaceVariant,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(strokeWidth: 2),
      ),
      // 封面错误函数回退到视频图标，避免网络问题破坏详情页结构。
      errorWidget: (BuildContext context, String url, Object error) =>
          Container(
        color: colors.surfaceVariant,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined),
      ),
    );
  }

  /// 构建正文末尾的自适应截图；保持原始比例并允许点击进入全屏浏览。
  Widget _buildFrameSection() {
    final String? framePath = _note.framePath;
    if (framePath == null || framePath.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('note-detail-frame-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 28),
        Row(
          children: <Widget>[
            Text(
              '视频截图',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const Spacer(),
            const Icon(Icons.open_in_full_rounded, size: 18),
            const SizedBox(width: 6),
            Text(
              '点击放大',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.center,
          child: Material(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('open-note-frame-fullscreen'),
              // 截图点击函数进入支持缩放的全屏浏览页。
              onTap: () => _openFrameFullscreen(framePath),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width - 40,
                  maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                ),
                child: Image.file(
                  File(framePath),
                  fit: BoxFit.contain,
                  // 截图错误函数显示明确说明，仍保留笔记的文字内容。
                  errorBuilder: (
                    BuildContext context,
                    Object error,
                    StackTrace? stackTrace,
                  ) {
                    return const SizedBox(
                      width: 280,
                      height: 180,
                      child: Center(child: Text('截图文件不存在')),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 构建视频来源、无边框标题正文、时间信息和末尾截图组成的详情页。
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return PopScope(
      canPop: _allowPop || !_hasUnsavedChanges,
      // 返回处理函数在有未保存修改时先显示确认提示。
      onPopInvoked: _handlePopInvoked,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('笔记详情'),
          actions: <Widget>[
            IconButton(
              key: const Key('delete-note-from-detail'),
              // 顶部删除函数启动二次确认，避免误删本机笔记。
              onPressed: _saving ? null : _deleteNote,
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: '删除笔记',
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonalIcon(
                key: const Key('save-note-detail'),
                // 顶部保存函数提交标题和正文，但保持用户停留在详情页。
                onPressed: _saving ? null : _saveNote,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
        body: ListView(
          key: const Key('video-note-detail-scroll-view'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
          children: <Widget>[
            Material(
              key: const Key('note-video-source-card'),
              color: colors.surfaceVariant.withOpacity(0.7),
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                // 视频来源卡点击函数打开对应视频、分P和笔记时间点。
                onTap: _openingVideo ? null : _openSourceVideo,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 132,
                          height: 74,
                          child: _buildVideoCover(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              _note.videoTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              _note.ownerName.isEmpty
                                  ? _note.bvid
                                  : '${_note.ownerName} · ${_note.bvid}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_openingVideo)
                        const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.play_circle_outline_rounded),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                _NoteMetadataChip(
                  icon: Icons.schedule_rounded,
                  label: formatVideoNotePosition(_note.position),
                ),
                _NoteMetadataChip(
                  icon: Icons.calendar_today_outlined,
                  label: formatVideoNoteDateTime(_note.createdAt),
                ),
                if (_note.partTitle.isNotEmpty)
                  _NoteMetadataChip(
                    icon: Icons.video_library_outlined,
                    label: 'P${_note.partPageNumber} ${_note.partTitle}',
                  ),
              ],
            ),
            const SizedBox(height: 24),
            TextField(
              key: const Key('note-detail-title-field'),
              controller: _titleController,
              enabled: !_saving,
              maxLength: 80,
              minLines: 1,
              maxLines: 3,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                height: 1.25,
              ),
              decoration: const InputDecoration(
                hintText: '笔记标题',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const Divider(height: 28),
            TextField(
              key: const Key('note-detail-body-field'),
              controller: _bodyController,
              enabled: !_saving,
              minLines: 5,
              maxLines: null,
              maxLength: 6000,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
              decoration: const InputDecoration(
                hintText: '写下此刻的想法…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            _buildFrameSection(),
          ],
        ),
      ),
    );
  }
}

/// 用图标和短文字显示笔记时间、记录日期或分P来源。
class _NoteMetadataChip extends StatelessWidget {
  /// 创建一枚紧凑的详情元数据标签。
  const _NoteMetadataChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  /// 构建弱背景、圆角且可随文字宽度伸缩的元数据标签。
  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 40,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withOpacity(0.72),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 以黑色背景全屏显示一张笔记视频截图，并允许缩放和平移。
class VideoNoteFrameViewerPage extends StatelessWidget {
  /// 创建只读取本机截图文件的全屏浏览页。
  const VideoNoteFrameViewerPage({super.key, required this.framePath});

  final String framePath;

  /// 构建覆盖整个页面的可缩放截图和左上角关闭按钮。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return InteractiveViewer(
                  key: const Key('fullscreen-note-frame-viewer'),
                  minScale: 1,
                  maxScale: 5,
                  alignment: Alignment.center,
                  child: SizedBox(
                    key: const Key('fullscreen-note-frame-viewport'),
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Image.file(
                      File(framePath),
                      fit: BoxFit.contain,
                      // 全屏截图错误函数在文件缺失时显示说明并保留返回能力。
                      errorBuilder: (
                        BuildContext context,
                        Object error,
                        StackTrace? stackTrace,
                      ) {
                        return const Center(
                          child: Text(
                            '截图文件不存在',
                            style: TextStyle(color: Colors.white),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: IconButton.filledTonal(
                  key: const Key('close-fullscreen-note-frame'),
                  // 关闭函数返回笔记详情页，不修改截图或文字笔记。
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
