part of 'player_page.dart';

/// 封装播放器内时间点笔记的状态、持久化、截图流程和响应式界面。
mixin _PlayerNotesWorkspace on State<PlayerPage> {
  static const Duration _notesPanelAnimationDuration = Duration(
    milliseconds: 280,
  );
  static const Duration _noteAutoSaveDelay = Duration(milliseconds: 800);

  final TextEditingController _noteTitleController = TextEditingController();
  final TextEditingController _noteBodyController = TextEditingController();
  Timer? _notesPanelAnimationTimer;
  Timer? _noteAutoSaveTimer;
  List<VideoNote> _currentVideoNotes = const <VideoNote>[];
  VideoNote? _editingVideoNote;
  Duration _notePosition = Duration.zero;
  int _notePartCid = 0;
  bool _notesOpen = false;
  bool _notesOverlayMounted = false;
  bool _notesLoading = false;
  bool _noteSaving = false;
  bool _noteAutoSaving = false;
  bool _noteAutoSavePending = false;
  bool _includeCurrentFrame = false;
  String? _noteFramePath;
  bool _fullscreenNoteListCollapsed = false;
  int _noteDraftRevision = 0;

  /// 由播放器状态类提供当前笔记的本机持久化服务。
  VideoNoteService get _videoNoteService;

  /// 由播放器状态类提供当前正在展示的视频资料。
  VideoPreview get _activeVideo;

  /// 由播放器状态类提供当前正在播放的分 P。
  VideoPart get _currentPart;

  /// 由播放器状态类提供最近一次真实播放状态。
  PlaybackSnapshot get _playbackSnapshot;

  /// 由播放器状态类提供当前平台的播放服务。
  PlaybackService get _playbackService;

  /// 由播放器状态类说明视频当前是否真实播放。
  bool get _playing;

  /// 由播放器状态类说明当前是否处于全屏。
  bool get _fullscreen;

  /// 更新播放器控制层可见状态。
  set _showControls(bool value);

  /// 停止控制层自动隐藏计时器，保证编辑笔记时按钮保持可见。
  void _stopControlsAutoHideTimer();

  /// 重新启动控制层自动隐藏计时器。
  void _restartControlsAutoHideTimer();

  /// 在笔记面板开关后重新同步播放器方向。
  void _scheduleOrientationSync();

  /// 切换到笔记所属分 P，并保留播放器既有切 P 流程。
  Future<void> _changePart(VideoPart part);

  /// 跳转到笔记记录的真实播放位置。
  Future<void> _seekNativeTo(Duration position);

  /// 使用播放器统一的短提示显示笔记操作结果。
  void _showTransientSnackBar(String message);

  /// 取消笔记计时器并释放输入控制器，供播放器 dispose 统一调用。
  void _disposePlayerNotesWorkspace() {
    _notesPanelAnimationTimer?.cancel();
    _flushVideoNoteAutoSave();
    _noteAutoSaveTimer?.cancel();
    _noteTitleController.dispose();
    _noteBodyController.dispose();
  }

  /// 读取当前 BV 的全部笔记，并按视频时间点更新播放器内列表。
  Future<void> _loadCurrentVideoNotes() async {
    try {
      final List<VideoNote> notes = await _videoNoteService.loadNotesForVideo(
        _activeVideo.bvid,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _currentVideoNotes = notes;
        _notesLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _notesLoading = false);
      _showTransientSnackBar('暂时无法读取本机笔记。');
    }
  }

  /// 打开笔记工作区，并为新笔记锁定按钮按下时的视频位置。
  Future<void> _openVideoNotes() async {
    _stopControlsAutoHideTimer();
    _notesPanelAnimationTimer?.cancel();
    if (_fullscreen) {
      setState(() {
        _notesOverlayMounted = true;
        _notesOpen = false;
        _notesLoading = true;
        _showControls = true;
        _fullscreenNoteListCollapsed = false;
      });
      // 下一帧打开函数让面板先在屏幕右侧完成布局，再平滑滑入可见区域。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _notesOverlayMounted) {
          setState(() => _notesOpen = true);
        }
      });
    } else {
      setState(() {
        _notesOverlayMounted = false;
        _notesOpen = true;
        _notesLoading = true;
        _showControls = true;
        _fullscreenNoteListCollapsed = false;
      });
    }
    _startNewVideoNote();
    await _loadCurrentVideoNotes();
    _restartControlsAutoHideTimer();
  }

  /// 清空编辑器并把当前真实播放位置作为下一条笔记的时间点。
  void _startNewVideoNote() {
    if (!mounted) {
      return;
    }
    _flushVideoNoteAutoSave();
    setState(() {
      _noteDraftRevision += 1;
      _editingVideoNote = null;
      _noteTitleController.clear();
      _noteBodyController.clear();
      _notePosition = _playbackSnapshot.position;
      _notePartCid = _currentPart.cid;
      _includeCurrentFrame = false;
      _noteFramePath = null;
    });
  }

  /// 关闭播放器内笔记工作区；全屏时等待右滑动画完成后再移除面板。
  void _closeVideoNotes() {
    if (!_notesOpen && !_notesOverlayMounted) {
      return;
    }
    _flushVideoNoteAutoSave();
    _notesPanelAnimationTimer?.cancel();
    setState(() {
      _notesOpen = false;
      _noteSaving = false;
      _showControls = true;
      _fullscreenNoteListCollapsed = false;
    });
    if (_fullscreen && _notesOverlayMounted) {
      _notesPanelAnimationTimer = Timer(_notesPanelAnimationDuration, () {
        if (mounted && !_notesOpen) {
          setState(() => _notesOverlayMounted = false);
        }
      });
    } else if (_notesOverlayMounted) {
      setState(() => _notesOverlayMounted = false);
    }
    _restartControlsAutoHideTimer();
    _scheduleOrientationSync();
  }

  /// 按 CID 查找笔记锁定的分P；旧数据缺失时退回当前分P。
  VideoPart _findVideoNotePart(int cid) {
    for (final VideoPart part in _activeVideo.parts) {
      if (part.cid == cid) {
        return part;
      }
    }
    return _currentPart;
  }

  /// 选择已有笔记并填入编辑器；播放位置只会由显式跳转按钮改变。
  void _selectVideoNote(VideoNote note) {
    final VideoPart targetPart = _findVideoNotePart(note.partCid);
    _noteAutoSaveTimer?.cancel();
    _noteAutoSaveTimer = null;
    setState(() {
      _noteDraftRevision += 1;
      _editingVideoNote = note;
      _noteTitleController.text = note.title;
      _noteBodyController.text = note.body;
      _notePosition = note.position;
      _notePartCid = targetPart.cid;
      _includeCurrentFrame = note.framePath != null;
      _noteFramePath = note.framePath;
    });
  }

  /// 只在用户点击显式按钮时跳转到当前编辑笔记的分P和时间点。
  Future<void> _jumpToSelectedVideoNotePosition() async {
    final VideoNote? note = _editingVideoNote;
    if (note == null) {
      _showTransientSnackBar('请先选择一条笔记。');
      return;
    }
    final VideoPart targetPart = _findVideoNotePart(note.partCid);
    try {
      if (targetPart.cid != _currentPart.cid) {
        await _changePart(targetPart);
      }
      await _seekNativeTo(note.position);
    } catch (_) {
      if (mounted) {
        _showTransientSnackBar('暂时无法跳转到这个笔记的时间点。');
      }
    }
  }

  /// 更新“插入当前画面”选择，取消时只影响本次保存，不立即删除旧文件。
  void _setIncludeCurrentFrame(bool selected) {
    setState(() => _includeCurrentFrame = selected);
    _scheduleVideoNoteAutoSave();
  }

  /// 在标题或正文停止输入片刻后自动保存，避免频繁写入本机偏好设置。
  void _handleVideoNoteDraftChanged(String value) {
    if (!_notesOpen) {
      return;
    }
    if (_noteAutoSaving || _noteSaving) {
      _noteAutoSavePending = true;
      return;
    }
    _scheduleVideoNoteAutoSave();
  }

  /// 重置输入去抖计时器；空白草稿不会创建无意义的本机笔记。
  void _scheduleVideoNoteAutoSave() {
    _noteAutoSaveTimer?.cancel();
    if (_noteTitleController.text.trim().isEmpty &&
        _noteBodyController.text.trim().isEmpty) {
      return;
    }
    _noteAutoSaveTimer = Timer(_noteAutoSaveDelay, () {
      _noteAutoSaveTimer = null;
      unawaited(_saveVideoNote(automatic: true));
    });
  }

  /// 立即提交仍在等待去抖的草稿，供新建、关闭、换视频和离开播放器前调用。
  void _flushVideoNoteAutoSave() {
    final Timer? timer = _noteAutoSaveTimer;
    if (timer == null) {
      return;
    }
    timer.cancel();
    _noteAutoSaveTimer = null;
    if (_noteTitleController.text.trim().isNotEmpty ||
        _noteBodyController.text.trim().isNotEmpty) {
      unawaited(_saveVideoNote(automatic: true));
    }
  }

  /// 等待原生播放器把目标时间点真正渲染到 Surface，再执行截图。
  Future<void> _waitForNoteFramePosition(Duration target) async {
    for (int attempt = 0; attempt < 30; attempt += 1) {
      final int difference = (_playbackSnapshot.position - target)
          .inMilliseconds
          .abs();
      if (_playbackSnapshot.phase == PlaybackPhase.ready && difference <= 350) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 暂停并跳到笔记锁定的分P和时间点截图，完成后恢复用户原来的播放位置。
  Future<String?> _captureFrameAtNotePosition() async {
    final VideoPart returnPart = _currentPart;
    final Duration returnPosition = _playbackSnapshot.position;
    final bool shouldResume = _playing;
    final VideoPart targetPart = _findVideoNotePart(_notePartCid);
    if (shouldResume) {
      await _playbackService.pause();
    }
    try {
      if (targetPart.cid != _currentPart.cid) {
        await _changePart(targetPart);
        await _playbackService.pause();
      }
      await _seekNativeTo(_notePosition);
      await _waitForNoteFramePosition(_notePosition);
      return await _playbackService.captureCurrentFrame();
    } finally {
      if (returnPart.cid != _currentPart.cid) {
        await _changePart(returnPart);
        await _playbackService.pause();
      }
      await _seekNativeTo(returnPosition);
      if (shouldResume) {
        await _playbackService.play();
      }
    }
  }

  /// 保存标题、正文、自动记录时间、视频位置和可选画面；自动保存不会反复弹出提示。
  Future<void> _saveVideoNote({bool automatic = false}) async {
    if (automatic) {
      if (_noteSaving || _noteAutoSaving) {
        _noteAutoSavePending = true;
        return;
      }
    } else {
      if (_noteSaving || _noteAutoSaving) {
        return;
      }
    }
    final String enteredTitle = _noteTitleController.text.trim();
    final String body = _noteBodyController.text.trim();
    if (enteredTitle.isEmpty && !automatic) {
      _showTransientSnackBar('请先填写笔记标题。');
      return;
    }
    if (enteredTitle.isEmpty && body.isEmpty) {
      return;
    }
    if (automatic) {
      _noteAutoSaving = true;
    } else {
      _noteSaving = true;
    }
    final String title = enteredTitle.isEmpty ? '未命名笔记' : enteredTitle;
    final VideoNote? existing = _editingVideoNote;
    final int draftRevision = _noteDraftRevision;
    final bool includeFrame = _includeCurrentFrame;
    final int notePartCid = _notePartCid;
    final Duration notePosition = _notePosition;
    // 自动保存只锁定保存按钮，不禁用输入框，避免输入过程中键盘失去焦点。
    setState(() {});
    String? framePath = includeFrame ? _noteFramePath : null;
    try {
      if (includeFrame && framePath == null && !automatic) {
        framePath = await _captureFrameAtNotePosition();
        if (framePath == null) {
          throw PlatformException(
            code: 'frame_capture_failed',
            message: '没有取得当前视频画面。',
          );
        }
      }
      final DateTime now = DateTime.now();
      final VideoPart notePart = _findVideoNotePart(notePartCid);
      final VideoNote note = existing == null
          ? VideoNote(
              id: '${_activeVideo.bvid}-${now.microsecondsSinceEpoch}',
              bvid: _activeVideo.bvid,
              videoTitle: _activeVideo.title,
              ownerName: _activeVideo.ownerName,
              partCid: notePart.cid,
              partPageNumber: notePart.pageNumber,
              partTitle: notePart.title,
              title: title,
              body: body,
              createdAt: now,
              updatedAt: now,
              position: notePosition,
              videoCoverUrl: _activeVideo.thumbnailUrl,
              framePath: framePath,
            )
          : existing.copyWith(
              title: title,
              body: body,
              updatedAt: now,
              position: notePosition,
              framePath: framePath,
              clearFrame: !includeFrame,
            );
      await _videoNoteService.saveNote(note);
      if (!mounted) {
        return;
      }
      final bool retryAutomaticSave = _noteAutoSavePending;
      setState(() {
        if (draftRevision == _noteDraftRevision) {
          _editingVideoNote = note;
          _noteFramePath = note.framePath;
        }
        _noteSaving = false;
        _noteAutoSaving = false;
        _noteAutoSavePending = false;
        _notesLoading = true;
      });
      await _loadCurrentVideoNotes();
      if (retryAutomaticSave && mounted) {
        _scheduleVideoNoteAutoSave();
      }
      if (mounted && !automatic) {
        _showTransientSnackBar('笔记已保存到本机。');
      }
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      final bool retryAutomaticSave = _noteAutoSavePending;
      setState(() {
        _noteSaving = false;
        _noteAutoSaving = false;
        _noteAutoSavePending = false;
      });
      if (retryAutomaticSave && mounted) {
        _scheduleVideoNoteAutoSave();
      }
      _showTransientSnackBar(error.message ?? '截取当前视频画面失败。');
    } catch (_) {
      if (!mounted) {
        return;
      }
      final bool retryAutomaticSave = _noteAutoSavePending;
      setState(() {
        _noteSaving = false;
        _noteAutoSaving = false;
        _noteAutoSavePending = false;
      });
      if (retryAutomaticSave && mounted) {
        _scheduleVideoNoteAutoSave();
      }
      _showTransientSnackBar('保存笔记失败，请稍后再试。');
    }
  }

  /// 删除正在编辑的笔记及其画面文件，并回到新的当前时间点草稿。
  Future<void> _deleteEditingVideoNote() async {
    final VideoNote? note = _editingVideoNote;
    if (note == null) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除“${note.title}”吗？此操作无法撤销。'),
        actions: <Widget>[
          TextButton(
            // 取消删除函数关闭确认框并保留播放器中的笔记。
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            // 确认删除函数把决定返回播放器，再由本机服务清理笔记和截图。
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _noteSaving = true);
    try {
      await _videoNoteService.deleteNote(note.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _noteDraftRevision += 1;
        _noteSaving = false;
        _notesLoading = true;
      });
      _startNewVideoNote();
      await _loadCurrentVideoNotes();
      if (mounted) {
        _showTransientSnackBar('笔记已删除。');
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _noteSaving = false);
      _showTransientSnackBar('删除笔记失败，请稍后再试。');
    }
  }

  /// 创建播放器笔记编辑器，并把保存、删除、画面选择等操作连接到本机服务。
  Widget _buildVideoNoteComposer({required bool compact}) {
    return VideoNoteComposer(
      titleController: _noteTitleController,
      bodyController: _noteBodyController,
      position: _notePosition,
      partPageNumber: _findVideoNotePart(_notePartCid).pageNumber,
      createdAt: _editingVideoNote?.createdAt,
      includeFrame: _includeCurrentFrame,
      framePath: _noteFramePath,
      saving: _noteSaving || _noteAutoSaving,
      inputEnabled: !_noteSaving,
      onIncludeFrameChanged: _setIncludeCurrentFrame,
      // 保存函数自动写入记录时间、视频时间点和用户选择的当前画面。
      onSave: () => unawaited(_saveVideoNote()),
      // 标题和正文变化函数安排去抖自动保存，避免每次按键都立即写本机存储。
      onTitleChanged: _handleVideoNoteDraftChanged,
      onBodyChanged: _handleVideoNoteDraftChanged,
      onNew: _startNewVideoNote,
      onClose: _closeVideoNotes,
      // 跳转函数只在用户点击独立按钮后才改变视频分P和时间点。
      onJumpToPosition: _editingVideoNote == null
          ? null
          : () => unawaited(_jumpToSelectedVideoNotePosition()),
      onDelete: _editingVideoNote == null
          ? null
          : () => unawaited(_deleteEditingVideoNote()),
      compact: compact,
      borderless: true,
    );
  }

  /// 创建竖屏笔记顶部的横向时间点列表，点按后只切换编辑内容。
  Widget _buildPortraitVideoNoteStrip() {
    if (_notesLoading) {
      return const SizedBox(
        height: 52,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_currentVideoNotes.isEmpty) {
      return const SizedBox(
        height: 52,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('这个视频还没有笔记，先写下第一条吧。'),
        ),
      );
    }
    return SizedBox(
      height: 56,
      child: ListView.separated(
        key: const Key('portrait-video-note-list'),
        scrollDirection: Axis.horizontal,
        itemCount: _currentVideoNotes.length,
        // 分隔函数给横向笔记卡片保留稳定间距。
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 8),
        // 构建函数显示笔记标题与视频时间点，并标出当前编辑项。
        itemBuilder: (BuildContext context, int index) {
          final VideoNote note = _currentVideoNotes[index];
          final bool selected = note.id == _editingVideoNote?.id;
          return SizedBox(
            width: 146,
            child: Card(
              margin: EdgeInsets.zero,
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: InkWell(
                key: Key('portrait-video-note-${note.id}'),
                borderRadius: BorderRadius.circular(12),
                // 竖屏笔记卡点击函数只载入笔记，跳转需要用户使用编辑器按钮确认。
                onTap: () => _selectVideoNote(note),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              formatVideoNotePosition(note.position),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'P${note.partPageNumber}',
                            key: Key('portrait-video-note-part-${note.id}'),
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 创建播放器下方的竖屏笔记工作区，打开后页面不再使用可折叠播放器。
  Widget _buildPortraitVideoNotesPanel() {
    return Material(
      key: const Key('portrait-video-notes-panel'),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Column(
          children: <Widget>[
            _buildPortraitVideoNoteStrip(),
            const SizedBox(height: 5),
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: _buildVideoNoteComposer(compact: false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 创建全屏笔记本左侧的竖向笔记列表，标题溢出时自动横向滚动。
  Widget _buildFullscreenVideoNoteList() {
    if (_notesLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_currentVideoNotes.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(12), child: Text('暂无笔记')),
      );
    }
    return ListView.separated(
      key: const Key('fullscreen-video-note-list'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      itemCount: _currentVideoNotes.length,
      // 分隔函数给全屏笔记时间线保留紧凑间距。
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 6),
      // 构建函数显示可自动滚动的标题和视频时间点，点击只切换编辑内容。
      itemBuilder: (BuildContext context, int index) {
        final VideoNote note = _currentVideoNotes[index];
        final bool selected = note.id == _editingVideoNote?.id;
        final ColorScheme colors = Theme.of(context).colorScheme;
        return Material(
          color: selected
              ? colors.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            key: Key('fullscreen-video-note-${note.id}'),
            borderRadius: BorderRadius.circular(9),
            // 全屏笔记点击函数只载入标题、正文和画面，跳转由单独按钮执行。
            onTap: () => _selectVideoNote(note),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 3,
                    height: 32,
                    decoration: BoxDecoration(
                      color: selected ? colors.primary : colors.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          height: 18,
                          child: _AutoScrollingText(
                            text: note.title,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: selected
                                ? colors.primary.withValues(alpha: 0.22)
                                : colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              'P${note.partPageNumber} ${formatVideoNotePosition(note.position)}',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 收起或展开全屏笔记列表，让用户按需要把横向空间让给正文编辑器。
  void _toggleFullscreenNoteList() {
    setState(() {
      _fullscreenNoteListCollapsed = !_fullscreenNoteListCollapsed;
    });
  }

  /// 创建约占播放器三分之二宽度的笔记本，保留左侧视频画面供边看边记。
  Widget _buildFullscreenVideoNotesPanel(double playerWidth) {
    final double panelWidth = playerWidth * 0.64;
    final double expandedListWidth = playerWidth * 0.17;
    return Positioned(
      key: const Key('fullscreen-video-notes-panel'),
      top: 10,
      right: 10,
      bottom: 10,
      width: panelWidth,
      child: AnimatedSlide(
        key: const Key('fullscreen-video-notes-slide'),
        offset: _notesOpen ? Offset.zero : const Offset(1.08, 0),
        duration: _notesPanelAnimationDuration,
        curve: _notesOpen ? Curves.easeOutCubic : Curves.easeInCubic,
        child: Material(
          key: const Key('fullscreen-video-notes-material'),
          elevation: 18,
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            bottom: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: _fullscreenNoteListCollapsed ? 46 : expandedListWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (_fullscreenNoteListCollapsed) ...<Widget>[
                        const SizedBox(height: 6),
                        IconButton(
                          key: const Key('expand-fullscreen-note-list'),
                          // 展开按钮函数恢复左侧笔记标题和时间点列表。
                          onPressed: _toggleFullscreenNoteList,
                          icon: const Icon(Icons.chevron_right_rounded),
                          tooltip: '展开笔记列表',
                        ),
                        Text(
                          '${_currentVideoNotes.length}',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ] else ...<Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(5, 6, 8, 3),
                          child: Row(
                            children: <Widget>[
                              IconButton(
                                key: const Key('collapse-fullscreen-note-list'),
                                // 收起按钮函数仅保留一条窄边栏，为标题和正文增加空间。
                                onPressed: _toggleFullscreenNoteList,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(
                                  width: 32,
                                  height: 32,
                                ),
                                padding: EdgeInsets.zero,
                                iconSize: 20,
                                icon: const Icon(Icons.chevron_left_rounded),
                                tooltip: '收起笔记列表',
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  '笔记',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ),
                              Text(
                                '${_currentVideoNotes.length}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                        Expanded(child: _buildFullscreenVideoNoteList()),
                      ],
                    ],
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: _buildVideoNoteComposer(compact: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 创建全屏右侧中部的半透明记笔记按钮，打开后由半屏笔记本替代。
  Widget _buildFullscreenVideoNoteButton() {
    return Positioned(
      key: const Key('fullscreen-note-button'),
      right: 12,
      top: 0,
      bottom: 0,
      child: Center(
        child: Material(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            // 全屏记笔记按钮函数打开工作区并锁定当前播放时间点。
            onTap: () => unawaited(_openVideoNotes()),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.edit_note_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 5),
                  Text('记笔记', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
