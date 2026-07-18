import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/video_note.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../../services/video_note_service.dart';
import 'video_note_composer.dart';
import 'video_note_detail_page.dart';

/// 在“我的”页面统一搜索、查看和删除保存在本机的时间点笔记。
class VideoNotesPage extends StatefulWidget {
  /// 创建笔记管理页；测试可以注入内存笔记服务和公开视频查询服务。
  const VideoNotesPage({super.key, this.noteService, this.videoService});

  final VideoNoteService? noteService;
  final BilibiliService? videoService;

  /// 创建负责读取、搜索和管理本地笔记的页面状态。
  @override
  State<VideoNotesPage> createState() => _VideoNotesPageState();
}

/// 管理全部笔记的加载、封面补齐、搜索、删除、刷新和错误状态。
class _VideoNotesPageState extends State<VideoNotesPage> {
  late final VideoNoteService _noteService;
  late final BilibiliService _videoService;
  late final TextEditingController _searchController;
  List<VideoNote> _notes = const <VideoNote>[];
  bool _loading = true;
  String? _errorMessage;
  String _query = '';

  /// 初始化本机笔记服务、公开视频服务和搜索输入控制器，再读取笔记。
  @override
  void initState() {
    super.initState();
    _noteService = widget.noteService ?? VideoNoteService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    _searchController = TextEditingController();
    _loadNotes();
  }

  /// 页面销毁时释放搜索输入控制器，避免输入资源泄漏。
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 返回与标题、正文、视频、UP、BV 或分P文字匹配的笔记列表。
  List<VideoNote> get _filteredNotes {
    final String keyword = _query.trim().toLowerCase();
    if (keyword.isEmpty) {
      return _notes;
    }
    return _notes
        .where((VideoNote note) {
          final String searchable = <String>[
            note.title,
            note.body,
            note.videoTitle,
            note.ownerName,
            note.bvid,
            note.partTitle,
          ].join('\n').toLowerCase();
          return searchable.contains(keyword);
        })
        .toList(growable: false);
  }

  /// 重新读取全部笔记，并在展示列表后异步补齐旧笔记缺少的视频封面。
  Future<void> _loadNotes() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final List<VideoNote> notes = await _noteService.loadNotes();
      if (!mounted) {
        return;
      }
      setState(() {
        _notes = notes;
        _loading = false;
      });
      unawaited(_backfillMissingVideoCovers(notes));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _errorMessage = '暂时无法读取本机笔记，请稍后重试。';
      });
    }
  }

  /// 为旧版本笔记逐个查询公开视频封面，保存后立即刷新对应列表卡片。
  Future<void> _backfillMissingVideoCovers(List<VideoNote> sourceNotes) async {
    final List<String> missingBvids = sourceNotes
        .where((VideoNote note) => note.videoCoverUrl.isEmpty)
        .map((VideoNote note) => note.bvid)
        .toSet()
        .toList(growable: false);
    for (final String bvid in missingBvids) {
      final String? coverUrl = await _lookupVideoCover(bvid);
      if (coverUrl == null || coverUrl.isEmpty) {
        continue;
      }
      final List<VideoNote> matching = sourceNotes
          .where((VideoNote note) => note.bvid == bvid)
          .map((VideoNote note) => note.copyWith(videoCoverUrl: coverUrl))
          .toList(growable: false);
      for (final VideoNote updated in matching) {
        await _noteService.saveNote(updated);
      }
      if (!mounted) {
        return;
      }
      final Map<String, VideoNote> replacements = <String, VideoNote>{
        for (final VideoNote note in matching) note.id: note,
      };
      setState(() {
        _notes = _notes
            .map((VideoNote note) => replacements[note.id] ?? note)
            .toList(growable: false);
      });
    }
  }

  /// 查询一支公开视频的封面地址，接口失败时返回空值并保留占位图。
  Future<String?> _lookupVideoCover(String bvid) async {
    try {
      final VideoPreview video = await _videoService.lookupVideo(bvid);
      final String coverUrl = video.thumbnailUrl.trim();
      return coverUrl.isEmpty ? null : coverUrl;
    } catch (_) {
      return null;
    }
  }

  /// 更新搜索关键词并立即刷新列表筛选结果。
  void _updateQuery(String value) {
    setState(() => _query = value);
  }

  /// 清空搜索输入和筛选条件，恢复显示全部笔记。
  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  /// 把用户带到独立笔记详情页，并在返回后重新读取可能修改的数据。
  Future<void> _openNote(VideoNote note) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => VideoNoteDetailPage(
          note: note,
          noteService: _noteService,
          videoService: _videoService,
        ),
      ),
    );
    if (mounted) {
      await _loadNotes();
    }
  }

  /// 询问用户后删除一条笔记，并同步刷新列表。
  Future<void> _deleteNote(VideoNote note) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除“${note.title}”吗？'),
        actions: <Widget>[
          TextButton(
            // 取消删除函数关闭对话框并保留笔记。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认删除函数只返回确认结果，文件清理由笔记服务统一处理。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _noteService.deleteNote(note.id);
    await _loadNotes();
  }

  /// 创建固定为 16:9 的视频封面，而不是把笔记截图误当成列表封面。
  Widget _buildVideoCover(VideoNote note) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget placeholder = Container(
      color: colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: const Icon(Icons.ondemand_video_rounded),
    );
    if (note.videoCoverUrl.isEmpty) {
      return placeholder;
    }
    return CachedNetworkImage(
      key: Key('managed-video-note-cover-${note.id}'),
      imageUrl: note.videoCoverUrl,
      fit: BoxFit.cover,
      // 封面加载函数使用相同占位布局，避免图片出现前卡片跳动。
      placeholder: (BuildContext context, String url) => placeholder,
      // 封面错误函数回退到视频图标，搜索和详情入口仍保持可用。
      errorWidget: (BuildContext context, String url, Object error) =>
          placeholder,
    );
  }

  /// 创建包含视频封面、笔记标题、视频标题、时间信息和菜单的列表卡片。
  Widget _buildNoteCard(VideoNote note) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Card(
      key: Key('managed-video-note-${note.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // 笔记卡点击函数进入独立详情页，不再弹出底部编辑窗口。
        onTap: () => _openNote(note),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 132,
                  height: 74,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      _buildVideoCover(note),
                      Positioned(
                        right: 6,
                        bottom: 5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            formatVideoNotePosition(note.position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 74,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        note.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        note.videoTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        formatVideoNoteDateTime(note.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                key: Key('managed-video-note-menu-${note.id}'),
                tooltip: '笔记操作',
                // 菜单选择函数把删除操作交给带确认框的统一删除流程。
                onSelected: (String value) {
                  if (value == 'delete') {
                    _deleteNote(note);
                  }
                },
                itemBuilder: (BuildContext context) =>
                    const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
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
        ),
      ),
    );
  }

  /// 创建页面顶部的圆角搜索框，并在有输入时提供一键清空按钮。
  Widget _buildSearchField() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return TextField(
      key: const Key('video-notes-search-field'),
      controller: _searchController,
      onChanged: _updateQuery,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索笔记、视频或 UP 主',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                key: const Key('clear-video-notes-search'),
                // 清空按钮函数恢复全部笔记并保留当前页面位置。
                onPressed: _clearSearch,
                icon: const Icon(Icons.close_rounded),
                tooltip: '清空搜索',
              ),
        filled: true,
        fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
    );
  }

  /// 创建没有笔记或搜索无结果时的图标、标题和说明文字。
  Widget _buildEmptyState({required bool searchEmpty}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              searchEmpty ? Icons.search_off_rounded : Icons.edit_note_rounded,
              size: 54,
            ),
            const SizedBox(height: 12),
            Text(searchEmpty ? '没有匹配的笔记' : '还没有时间点笔记'),
            const SizedBox(height: 6),
            Text(
              searchEmpty ? '换个标题、视频名、UP 主或正文关键词试试。' : '在视频页点“记笔记”即可保存此刻的想法。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// 根据加载、错误、空列表、搜索和正常数据状态创建笔记管理页。
  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_errorMessage != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(_errorMessage!),
            const SizedBox(height: 12),
            OutlinedButton(
              // 错误重试函数重新读取本机笔记。
              onPressed: _loadNotes,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    } else if (_notes.isEmpty) {
      body = _buildEmptyState(searchEmpty: false);
    } else {
      final List<VideoNote> visibleNotes = _filteredNotes;
      body = Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: _buildSearchField(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Row(
              children: <Widget>[
                Text(
                  _query.isEmpty
                      ? '共 ${_notes.length} 条笔记'
                      : '找到 ${visibleNotes.length} 条笔记',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            child: visibleNotes.isEmpty
                ? _buildEmptyState(searchEmpty: true)
                : RefreshIndicator(
                    // 下拉刷新函数重新读取其他页面刚保存的本机笔记。
                    onRefresh: _loadNotes,
                    child: ListView.separated(
                      key: const Key('video-notes-list'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: visibleNotes.length,
                      // 分隔函数给相邻笔记卡片保留稳定间距。
                      separatorBuilder: (BuildContext context, int index) =>
                          const SizedBox(height: 10),
                      // 列表构建函数按最近更新时间展示筛选后的本机笔记。
                      itemBuilder: (BuildContext context, int index) =>
                          _buildNoteCard(visibleNotes[index]),
                    ),
                  ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('时间点笔记'),
        actions: <Widget>[
          IconButton(
            // 顶部刷新函数重新同步本机笔记列表。
            onPressed: _loadNotes,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
          ),
        ],
      ),
      body: body,
    );
  }
}
