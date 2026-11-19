import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/layout/adaptive_page_frame.dart';
import '../../core/layout/adaptive_two_column_list.dart';
import '../../models/video_note.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../../services/video_note_service.dart';
import '../../services/video_note_export_service.dart';
import '../../services/video_note_share_service.dart';
import '../../services/local_export_service.dart';
import 'video_note_list_tile.dart';
import 'video_note_detail_page.dart';

/// 在“我的”页面统一搜索、查看和删除保存在本机的时间点笔记。
class VideoNotesPage extends StatefulWidget {
  /// 创建笔记管理页；测试可以注入内存笔记服务和公开视频查询服务。
  const VideoNotesPage({
    super.key,
    this.noteService,
    this.videoService,
    this.exportService = const VideoNoteExportService(),
    this.shareService = const VideoNoteShareService(),
    this.localExportService = const LocalExportService(),
  });

  final VideoNoteService? noteService;
  final BilibiliService? videoService;
  final VideoNoteExportService exportService;
  final VideoNoteShareService shareService;
  final LocalExportService localExportService;

  /// 创建负责读取、搜索和管理本地笔记的页面状态。
  @override
  State<VideoNotesPage> createState() => _VideoNotesPageState();
}

/// 管理全部笔记的加载、封面补齐、搜索、删除、刷新和错误状态。
class _VideoNotesPageState extends State<VideoNotesPage> {
  late final VideoNoteService _noteService;
  late final BilibiliService _videoService;
  late final TextEditingController _searchController;
  final _listFocus = FocusNode(debugLabel: '时间点笔记');
  List<VideoNote> _notes = const <VideoNote>[];
  bool _loading = true;
  String? _errorMessage;
  String _query = '';
  final Set<String> _selectedNoteIds = <String>{};
  bool _selectionMode = false;
  bool _exporting = false;

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
    _listFocus.dispose();
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
        _loading = _notes.isEmpty;
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
        _retainVisibleSelection();
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
        _selectionMode = false;
        _selectedNoteIds.clear();
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
      if (!mounted) return;
      try {
        final changed = await _noteService.fillMissingCovers(bvid, coverUrl);
        if (!mounted) return;
        if (changed.isEmpty) continue;
        setState(() {
          _notes = [
            for (final note in _notes)
              if (note.bvid == bvid &&
                  note.videoCoverUrl.isEmpty &&
                  changed.contains(note.id))
                note.copyWith(videoCoverUrl: coverUrl)
              else
                note,
          ];
        });
      } catch (_) {
        // 补图是可选操作，本机存储暂不可写时继续显示原笔记。
      }
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
    setState(() {
      _query = value;
      _retainVisibleSelection();
    });
  }

  void _retainVisibleSelection() {
    if (_selectedNoteIds.isNotEmpty) {
      final visible = _filteredNotes.map((note) => note.id).toSet();
      _selectedNoteIds.retainAll(visible);
    }
  }

  /// 清空搜索输入和筛选条件，恢复显示全部笔记。
  void _clearSearch() {
    _searchController.clear();
    _updateQuery('');
  }

  /// 进入选择模式并选中长按的第一条笔记。
  void _startSelection([VideoNote? note]) {
    _listFocus.requestFocus();
    setState(() {
      _selectionMode = true;
      if (note != null) _selectedNoteIds.add(note.id);
    });
  }

  /// 切换一条笔记的选中状态；最后一条取消后仍保留选择模式供继续挑选。
  void _toggleNoteSelection(VideoNote note) {
    setState(() {
      if (!_selectedNoteIds.add(note.id)) {
        _selectedNoteIds.remove(note.id);
      }
    });
  }

  /// 选中当前搜索结果里的全部笔记，避免误把隐藏结果一起导出。
  void _selectAllVisibleNotes() {
    setState(() {
      _selectionMode = true;
      _selectedNoteIds.addAll(_filteredNotes.map((VideoNote note) => note.id));
    });
  }

  /// 退出选择模式并清空所有临时选择，不修改任何笔记数据。
  void _leaveSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedNoteIds.clear();
    });
  }

  /// 打开格式选择面板，并把用户选择交给统一导出流程。
  Future<void> _chooseExportFormat({required bool share}) async {
    if (_selectedNoteIds.isEmpty || _exporting) {
      return;
    }
    final VideoNoteExportFormat? format =
        await showModalBottomSheet<VideoNoteExportFormat>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (BuildContext context) => SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('导出为 Markdown'),
                    subtitle: const Text('适合 Obsidian、Notion 等笔记软件读取'),
                    // Markdown 选择函数只返回格式，生成和保存由外层统一处理。
                    onTap: () => Navigator.of(
                      context,
                    ).pop(VideoNoteExportFormat.markdown),
                  ),
                  ListTile(
                    leading: const Icon(Icons.data_object_rounded),
                    title: const Text('导出为 JSON'),
                    subtitle: const Text('保留焦点哔哩字段，便于后续回导'),
                    // JSON 选择函数只返回格式，避免底部面板直接执行耗时文件操作。
                    onTap: () =>
                        Navigator.of(context).pop(VideoNoteExportFormat.json),
                  ),
                ],
              ),
            ),
          ),
        );
    if (format != null && mounted) {
      if (share) {
        await _shareSelectedNotes(format);
      } else {
        await _exportSelectedNotes(format);
      }
    }
  }

  /// 生成与导出相同的笔记文件，并交给系统分享面板选择目标 App。
  Future<void> _shareSelectedNotes(VideoNoteExportFormat format) async {
    final List<VideoNote> selectedNotes = _notes
        .where((VideoNote note) => _selectedNoteIds.contains(note.id))
        .toList(growable: false);
    if (selectedNotes.isEmpty) {
      return;
    }
    setState(() => _exporting = true);
    try {
      final VideoNoteExportPackage package = await widget.exportService
          .buildPackage(selectedNotes, format);
      final shared = await widget.shareService.shareExportPackage(package);
      if (!mounted || !shared) {
        return;
      }
      _leaveSelectionMode();
      if (widget.shareService.savesExportPackageLocally) {
        _showExportedNotes(package);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is LocalExportException ? error.message : '笔记文件分享失败，请稍后重试。',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  /// 生成导出文件并调用系统“另存为”；取消选择位置不会误报成功。
  Future<void> _exportSelectedNotes(VideoNoteExportFormat format) async {
    final List<VideoNote> selectedNotes = _notes
        .where((VideoNote note) => _selectedNoteIds.contains(note.id))
        .toList(growable: false);
    if (selectedNotes.isEmpty) {
      return;
    }
    setState(() => _exporting = true);
    try {
      final VideoNoteExportPackage package = await widget.exportService
          .buildPackage(selectedNotes, format);
      final String? savedPath = await widget.localExportService.save(
        dialogTitle: '保存焦点哔哩笔记',
        fileName: package.fileName,
        bytes: package.bytes,
      );
      if (!mounted || savedPath == null) {
        return;
      }
      _leaveSelectionMode();
      _showExportedNotes(package);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is LocalExportException ? error.message : '笔记文件生成失败，请稍后重试。',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  void _showExportedNotes(VideoNoteExportPackage package) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          package.missingImageCount > 0
              ? '已导出 ${package.noteCount} 条笔记和 ${package.imageCount} 张图片；${package.missingImageCount} 张画面缺失或无法读取。'
              : package.imageCount > 0
              ? '已导出 ${package.noteCount} 条笔记和 ${package.imageCount} 张图片。'
              : '已导出 ${package.noteCount} 条笔记。',
        ),
      ),
    );
  }

  /// 把用户带到独立笔记详情页，并在返回后重新读取可能修改的数据。
  Future<void> _openNote(VideoNote note) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => VideoNoteDetailPage(
          note: note,
          noteService: _noteService,
          videoService: _videoService,
          localExportService: widget.localExportService,
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
    if (confirmed != true || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    try {
      await _noteService.deleteNote(note.id);
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('删除笔记失败，请稍后重试。')));
      }
      return;
    }
    await _loadNotes();
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
      child: SingleChildScrollView(
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

  /// 选择模式下在底部同时提供保存文件和分享文件，避免两个动作隐藏在菜单里。
  Widget _buildSelectionActions() {
    final bool enabled = _selectedNoteIds.isNotEmpty && !_exporting;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final short =
                      (constraints.maxWidth - 12) / 2 <
                      MediaQuery.textScalerOf(context).scale(14) * 4 + 72;
                  final save = enabled
                      ? () => _chooseExportFormat(share: false)
                      : null;
                  final share = enabled
                      ? () => _chooseExportFormat(share: true)
                      : null;
                  return Row(
                    children: [
                      Expanded(
                        child: short
                            ? OutlinedButton(
                                key: const Key('save-selected-video-notes'),
                                onPressed: save,
                                child: const Text('导出', semanticsLabel: '导出文件'),
                              )
                            : OutlinedButton.icon(
                                key: const Key('save-selected-video-notes'),
                                onPressed: save,
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('导出文件'),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: short
                            ? FilledButton(
                                key: const Key('share-selected-video-notes'),
                                onPressed: share,
                                child: Text(
                                  _exporting ? '处理中' : '分享',
                                  semanticsLabel: _exporting ? '处理中' : '分享文件',
                                ),
                              )
                            : FilledButton.icon(
                                key: const Key('share-selected-video-notes'),
                                onPressed: share,
                                icon: _exporting
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.ios_share_rounded),
                                label: Text(_exporting ? '处理中…' : '分享文件'),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
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
      body = RefreshIndicator(
        onRefresh: _loadNotes,
        child: AdaptiveTwoColumnList(
          key: const PageStorageKey<String>('video-notes-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSearchField(),
              Padding(
                padding: const EdgeInsets.only(left: 2, top: 10),
                child: Text(
                  _query.trim().isEmpty
                      ? '共 ${_notes.length} 条笔记'
                      : '找到 ${visibleNotes.length} 条笔记',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          itemCount: visibleNotes.length,
          footer: visibleNotes.isEmpty
              ? _buildEmptyState(searchEmpty: true)
              : null,
          mainAxisSpacing: 10,
          itemBuilder: (context, index) {
            final note = visibleNotes[index];
            return VideoNoteListTile(
              key: Key('managed-video-note-${note.id}'),
              note: note,
              query: _query,
              selecting: _selectionMode,
              selected: _selectedNoteIds.contains(note.id),
              onTap: _selectionMode
                  ? () => _toggleNoteSelection(note)
                  : () => _openNote(note),
              onLongPress: () => _startSelection(note),
              onDelete: () => _deleteNote(note),
            );
          },
        ),
      );
    }
    final compactTitle =
        MediaQuery.sizeOf(context).width <
        210 + MediaQuery.textScalerOf(context).scale(22) * 5;
    final page = Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(
                // 选择模式关闭函数放弃临时勾选并回到普通浏览。
                onPressed: _leaveSelectionMode,
                icon: const Icon(Icons.close_rounded),
                tooltip: '取消选择',
              )
            : null,
        title: Text(
          _selectionMode
              ? (compactTitle
                    ? '已选 ${_selectedNoteIds.length}'
                    : '已选择 ${_selectedNoteIds.length} 条')
              : compactTitle
              ? '笔记'
              : '时间点笔记',
          semanticsLabel: _selectionMode
              ? '已选择 ${_selectedNoteIds.length} 条'
              : '时间点笔记',
        ),
        actions: <Widget>[
          if (_selectionMode) ...<Widget>[
            IconButton(
              // 全选按钮函数只勾选当前搜索结果中的可见笔记。
              onPressed: _filteredNotes.isEmpty ? null : _selectAllVisibleNotes,
              icon: const Icon(Icons.select_all_rounded),
              tooltip: '全选当前结果',
            ),
          ] else ...<Widget>[
            TextButton(
              key: const Key('select-video-notes'),
              // “导出”文字按钮进入批量选择模式，避免含义不明的清单图标。
              onPressed: _notes.isEmpty || _errorMessage != null || _loading
                  ? null
                  : () => _startSelection(),
              child: const Text('导出'),
            ),
            IconButton(
              // 顶部刷新函数重新同步本机笔记列表。
              onPressed: _loadNotes,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
            ),
          ],
        ],
      ),
      body: AdaptivePageFrame(maxWidth: 1180, child: body),
      bottomNavigationBar: _selectionMode ? _buildSelectionActions() : null,
    );
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _leaveSelectionMode();
      },
      child: CallbackShortcuts(
        bindings: {
          if (_selectionMode)
            const SingleActivator(LogicalKeyboardKey.escape):
                _leaveSelectionMode,
        },
        child: Focus(focusNode: _listFocus, skipTraversal: true, child: page),
      ),
    );
  }
}
