part of 'player_page.dart';

/// 协调笔记旗标的初始读取、身份切换与保护草稿的打开流程。
mixin _PlayerNoteFlagsCoordinator on State<PlayerPage>, _PlayerNotesWorkspace {
  /// 页面创建时读取已有笔记，并监听任何页面对同一视频笔记的增删改。
  void _initializePlayerNoteFlags() {
    _noteChangesSubscription = VideoNoteService.changes.listen((bvid) {
      if (mounted && bvid == _activeVideo.bvid) {
        unawaited(_loadCurrentVideoNotes());
      }
    });
    unawaited(_loadCurrentVideoNotes());
  }

  /// 切视频或分 P 后立即撤销旧请求并清理标记，再读取当前身份的列表。
  void _refreshPlayerNoteIdentity() {
    _notesRequestGeneration++;
    _currentVideoNotes = const [];
    unawaited(_loadCurrentVideoNotes());
  }

  /// 先保存当前草稿，再打开旗标所选的已有笔记；取消选择不触碰草稿。
  Future<void> _openPlayerNoteFlag(List<VideoNote> notes) async {
    final bvid = _activeVideo.bvid;
    final cid = _currentPart.cid;
    _stopControlsAutoHideTimer();
    VideoNote? selected = notes.length == 1
        ? notes.single
        : await showDialog<VideoNote>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('选择笔记'),
              content: SizedBox(
                width: 360,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final note in notes)
                        ListTile(
                          key: ValueKey('choose-note-${note.id}'),
                          title: Text(note.title),
                          subtitle: Text(
                            formatVideoNotePosition(note.position),
                          ),
                          // 列表选择只返回笔记，随后由工作区安全保存草稿。
                          onTap: () => Navigator.of(dialogContext).pop(note),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  // 关闭选择列表后保留全部未保存输入。
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
    if (!mounted) return;
    _restartControlsAutoHideTimer();
    if (selected == null ||
        !mounted ||
        bvid != _activeVideo.bvid ||
        cid != _currentPart.cid) {
      return;
    }
    await _noteSaveCompletion?.future;
    if (!mounted || bvid != _activeVideo.bvid || cid != _currentPart.cid) {
      return;
    }
    final title = _noteTitleController.text.trim();
    final body = _noteBodyController.text.trim();
    if (title.isNotEmpty || body.isNotEmpty) {
      _noteAutoSaveTimer?.cancel();
      _noteAutoSaveTimer = null;
      final revision = _noteDraftRevision;
      await _saveVideoNote(automatic: true);
      if (!mounted ||
          !_noteLastSaveSucceeded ||
          bvid != _activeVideo.bvid ||
          cid != _currentPart.cid ||
          revision != _noteDraftRevision ||
          _editingVideoNote?.title != (title.isEmpty ? '未命名笔记' : title) ||
          _editingVideoNote?.body != body ||
          _noteTitleController.text.trim() != title ||
          _noteBodyController.text.trim() != body) {
        return;
      }
    }
    selected = _currentVideoNotes
        .where((note) => note.id == selected!.id)
        .firstOrNull;
    if (selected == null) return;
    await _openVideoNotes(selectedNote: selected);
  }
}
