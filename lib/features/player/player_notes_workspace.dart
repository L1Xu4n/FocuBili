part of 'player_page.dart';

/// Storage-only state shared by an in-flight write and a departing editor.
class _PendingPlayerNoteWrite {
  _PendingPlayerNoteWrite(this.id, this.framesRevision);

  final String id;
  final int framesRevision;
  final result = Completer<VideoNote?>();
  Future<VideoNote?> get future => result.future;
}

/// 封装播放器内时间点笔记的状态、持久化、截图流程和响应式界面。
mixin _PlayerNotesWorkspace on State<PlayerPage> {
  /// 读取播放栏比例，让全屏笔记入口与其他操作保持同样大小。
  PlaybackPreferences get _playbackPreferences;
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
  List<VideoNoteFrame> _noteFrames = const <VideoNoteFrame>[];
  bool _fullscreenNoteListCollapsed = false;
  int _noteDraftRevision = 0;
  int _noteFramesRevision = 0;
  int _notesRequestGeneration = 0;
  StreamSubscription<String>? _noteChangesSubscription;
  _PendingPlayerNoteWrite? _noteSaveCompletion;
  VideoNote? _noteDraftIdentity;
  int _noteDraftAccountRevision = CacheLifecycle.account.value;
  String _noteDraftAccountScope = CacheLifecycle.accountScope;
  bool get _noteDraftMatchesAccount =>
      _noteDraftAccountRevision == CacheLifecycle.account.value &&
      _noteDraftAccountScope == CacheLifecycle.accountScope;
  static int _lastPlayerNoteIdentity = 0;
  String? _deletingPlayerNoteId;
  ({int draftRevision, VideoNoteFrame frame})? _provisionalLiveNoteFrame;
  Object? _pendingLiveNoteFrame;

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

  /// 播放导航代次也会在用户开始切换时变化，早于新视频真正替换旧视频。
  int get _partSwitchGeneration;

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
  Future<void> _seekNativeTo(
    Duration position, {
    bool temporaryCapture = false,
  });
  Future<int> _beginAbRepeatCapture();
  bool _isCurrentAbRepeatCapture(int serial);
  void _prepareAbRepeatCaptureRestore(Duration position);
  void _endAbRepeatCapture();
  bool get _canResumeAfterNoteCapture;
  int get _sourceGeneration;

  /// 使用播放器统一的短提示显示笔记操作结果。
  void _showTransientSnackBar(String message);

  /// 取消笔记计时器并释放输入控制器，供播放器 dispose 统一调用。
  void _disposePlayerNotesWorkspace() {
    _notesRequestGeneration++;
    unawaited(_noteChangesSubscription?.cancel());
    _notesPanelAnimationTimer?.cancel();
    _flushVideoNoteAutoSave(updateUi: false);
    _noteAutoSaveTimer?.cancel();
    _noteTitleController.dispose();
    _noteBodyController.dispose();
  }

  /// 读取当前 BV 的全部笔记，并按视频时间点更新播放器内列表。
  Future<void> _loadCurrentVideoNotes() async {
    final generation = ++_notesRequestGeneration;
    final bvid = _activeVideo.bvid;
    final cid = _currentPart.cid;
    try {
      final List<VideoNote> notes = await _videoNoteService.loadNotesForVideo(
        bvid,
      );
      if (!mounted ||
          generation != _notesRequestGeneration ||
          bvid != _activeVideo.bvid ||
          cid != _currentPart.cid) {
        return;
      }
      setState(() {
        _currentVideoNotes = notes;
        _notesLoading = false;
      });
    } catch (_) {
      if (!mounted ||
          generation != _notesRequestGeneration ||
          bvid != _activeVideo.bvid ||
          cid != _currentPart.cid) {
        return;
      }
      setState(() => _notesLoading = false);
      _showTransientSnackBar('暂时无法读取本机笔记。');
    }
  }

  /// 打开笔记工作区，并为新笔记锁定按钮按下时的视频位置。
  Future<void> _openVideoNotes({VideoNote? selectedNote}) async {
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
    if (selectedNote == null) {
      _startNewVideoNote();
    } else {
      _selectVideoNote(selectedNote);
    }
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
      _pendingLiveNoteFrame = null;
      _noteDraftRevision += 1;
      _noteDraftIdentity = null;
      _noteDraftAccountRevision = CacheLifecycle.account.value;
      _noteDraftAccountScope = CacheLifecycle.accountScope;
      _editingVideoNote = null;
      _noteTitleController.clear();
      _noteBodyController.clear();
      _notePosition = _playbackSnapshot.position;
      _notePartCid = _currentPart.cid;
      _includeCurrentFrame = false;
      _noteFrames = const <VideoNoteFrame>[];
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
      _pendingLiveNoteFrame = null;
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
      _pendingLiveNoteFrame = null;
      _noteDraftRevision += 1;
      _noteDraftIdentity = null;
      _noteDraftAccountRevision = CacheLifecycle.account.value;
      _noteDraftAccountScope = CacheLifecycle.accountScope;
      _editingVideoNote = note;
      _noteTitleController.text = note.title;
      _noteBodyController.text = note.body;
      _notePosition = note.position;
      _notePartCid = targetPart.cid;
      _includeCurrentFrame = note.allFrames.isNotEmpty;
      _noteFrames = note.allFrames;
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
    setState(() {
      _includeCurrentFrame = selected;
      _noteFramesRevision++;
    });
    _scheduleVideoNoteAutoSave();
  }

  void _setNoteFrames(List<VideoNoteFrame> frames) {
    setState(() {
      _noteFrames = List<VideoNoteFrame>.unmodifiable(frames);
      _noteFramesRevision++;
      _includeCurrentFrame = frames.isNotEmpty;
    });
    _scheduleVideoNoteAutoSave();
  }

  /// 取消本次读取，不阻塞切 P；原生晚返回的独占文件会被清理。
  void _cancelLiveNoteFrame() {
    if (_pendingLiveNoteFrame != null) {
      setState(() => _pendingLiveNoteFrame = null);
    }
  }

  /// 追加当前渲染帧；绝不借用需要暂停、跳转的历史锚点截图。
  Future<void> _appendCurrentNoteFrame() async {
    if (_pendingLiveNoteFrame != null ||
        _noteSaveCompletion != null ||
        !_noteDraftMatchesAccount) {
      return;
    }
    if (_noteTitleController.text.trim().isEmpty) {
      _showTransientSnackBar('请先填写笔记标题。');
      return;
    }
    if (_currentPart.cid != _notePartCid) {
      _showTransientSnackBar('请先回到这条笔记所属的分 P，再追加画面。');
      return;
    }
    final bvid = _activeVideo.bvid;
    final cid = _currentPart.cid;
    final draft = _noteDraftRevision;
    final navigation = _partSwitchGeneration;
    final source = _sourceGeneration;
    final operation = Object();
    bool isCurrent() =>
        mounted &&
        identical(_pendingLiveNoteFrame, operation) &&
        draft == _noteDraftRevision &&
        navigation == _partSwitchGeneration &&
        source == _sourceGeneration &&
        bvid == _activeVideo.bvid &&
        cid == _currentPart.cid &&
        cid == _notePartCid;
    setState(() => _pendingLiveNoteFrame = operation);
    LiveVideoFrame? captured;
    VideoNoteFrame? attachment;
    bool retained = false;
    try {
      final service = _playbackService;
      if (_playbackSnapshot.phase == PlaybackPhase.ready &&
          !_playbackSnapshot.isRestoringPosition &&
          !_playbackSnapshot.audioOnly &&
          service is LiveVideoFramePlaybackService) {
        try {
          captured = await (service as LiveVideoFramePlaybackService)
              .captureLiveVideoFrame();
        } catch (_) {
          // Optional capture failures must never interrupt or change playback.
        }
      }
      if (!isCurrent()) return;
      // Let text autosave continue while the device reads pixels. Only wait for
      // actual writes before attaching; a slow read must not hold navigation.
      await _noteSaveCompletion?.future;
      if (!isCurrent()) return;
      final frame = captured;
      final valid =
          frame != null &&
          frame.bvid == bvid &&
          frame.cid == cid &&
          frame.path.isNotEmpty &&
          !frame.position.isNegative &&
          (_playbackSnapshot.duration <= Duration.zero ||
              frame.position <= _playbackSnapshot.duration);
      _noteAutoSaveTimer?.cancel();
      _noteAutoSaveTimer = null;
      if (valid) {
        attachment = VideoNoteFrame(path: frame.path, position: frame.position);
        _provisionalLiveNoteFrame = (draftRevision: draft, frame: attachment);
        setState(() {
          _noteFrames = [..._noteFrames, attachment!];
          _includeCurrentFrame = true;
          _noteFramesRevision++;
        });
      }
      final saved = await _saveVideoNote(automatic: true);
      retained = attachment != null && saved;
      if (attachment != null &&
          !retained &&
          mounted &&
          draft == _noteDraftRevision &&
          bvid == _activeVideo.bvid) {
        setState(() {
          _noteFrames = _noteFrames
              .where((frame) => !identical(frame, attachment))
              .toList();
          _includeCurrentFrame = _noteFrames.isNotEmpty;
          _noteFramesRevision++;
        });
        // If the draft was still awaiting its first write, keep the text edit
        // eligible to save after stripping the uncommitted picture.
        if (isCurrent()) _scheduleVideoNoteAutoSave();
      } else if (!valid && saved && isCurrent()) {
        _showTransientSnackBar('当前画面无法截取，笔记文字已保存。');
      }
    } finally {
      if (identical(_provisionalLiveNoteFrame?.frame, attachment)) {
        _provisionalLiveNoteFrame = null;
      }
      if (identical(_pendingLiveNoteFrame, operation)) {
        if (mounted) setState(() => _pendingLiveNoteFrame = null);
      }
      if (captured != null && !retained) {
        await _videoNoteService.discardUnreferencedFrame(captured.path);
      }
    }
  }

  /// 在标题或正文停止输入片刻后自动保存，避免频繁写入本机偏好设置。
  void _handleVideoNoteDraftChanged(String value) {
    if (!_notesOpen) {
      return;
    }
    if (_noteSaveCompletion != null) {
      _noteAutoSavePending = true;
      return;
    }
    _scheduleVideoNoteAutoSave();
  }

  /// 重置输入去抖计时器；空白草稿不会创建无意义的本机笔记。
  void _scheduleVideoNoteAutoSave() {
    _noteAutoSaveTimer?.cancel();
    _noteAutoSaveTimer = null;
    if (_noteTitleController.text.trim().isEmpty &&
        _noteBodyController.text.trim().isEmpty) {
      return;
    }
    _noteAutoSaveTimer = Timer(_noteAutoSaveDelay, () {
      _noteAutoSaveTimer = null;
      unawaited(_saveVideoNote(automatic: true));
    });
  }

  /// Allocate a new identity on the first save attempt, not on its response.
  /// Subsequent snapshots of this draft must reuse its id and original anchor.
  VideoNote _snapshotPlayerNote(String title, String body) {
    final video = _activeVideo;
    final now = DateTime.now();
    final part = _findVideoNotePart(_notePartCid);
    final base =
        _editingVideoNote ??
        (_noteDraftIdentity ??= () {
          final time = now.microsecondsSinceEpoch;
          _lastPlayerNoteIdentity = time > _lastPlayerNoteIdentity
              ? time
              : _lastPlayerNoteIdentity + 1;
          return VideoNote(
            id: '${video.bvid}-$_lastPlayerNoteIdentity',
            bvid: video.bvid,
            videoTitle: video.title,
            ownerName: video.ownerName,
            partCid: part.cid,
            partPageNumber: part.pageNumber,
            partTitle: part.title,
            title: title,
            body: body,
            createdAt: now,
            updatedAt: now,
            position: _notePosition,
            videoCoverUrl: video.thumbnailUrl,
          );
        }());
    return base.copyWith(
      title: title.isEmpty ? '未命名笔记' : title,
      body: body,
      updatedAt: now,
      frames: _includeCurrentFrame ? List.of(_noteFrames) : const [],
      clearFrame: !_includeCurrentFrame,
    );
  }

  /// Freeze the final draft before a controller is cleared/disposed. A pending
  /// edit has no debounce timer while storage is already busy.
  void _flushVideoNoteAutoSave({bool updateUi = true}) {
    final dirty = _noteAutoSaveTimer != null || _noteAutoSavePending;
    _noteAutoSaveTimer?.cancel();
    _noteAutoSaveTimer = null;
    _noteAutoSavePending = false;
    if (!dirty || !_noteDraftMatchesAccount) {
      return;
    }
    final title = _noteTitleController.text.trim();
    final body = _noteBodyController.text;
    if (title.isEmpty && body.trim().isEmpty) return;
    if (_deletingPlayerNoteId != null &&
        _deletingPlayerNoteId == _editingVideoNote?.id) {
      return;
    }
    final draft = _snapshotPlayerNote(title, body);
    final previous = _noteSaveCompletion;
    final expected = _editingVideoNote;
    final account = _noteDraftAccountRevision;
    final accountScope = _noteDraftAccountScope;
    final draftRevision = _noteDraftRevision;
    final framesRevision = _noteFramesRevision;
    final includeFrames = _includeCurrentFrame;
    final liveFrame = _provisionalLiveNoteFrame;
    final provisional = liveFrame?.draftRevision == draftRevision
        ? liveFrame?.frame
        : null;
    final operation = _PendingPlayerNoteWrite(draft.id, framesRevision);
    final storage = _videoNoteService;
    _noteSaveCompletion = operation;
    unawaited(() async {
      VideoNote? committed;
      try {
        final preceding = await previous?.future;
        final matching = previous?.id == draft.id && preceding?.id == draft.id
            ? preceding
            : null;
        var finalDraft = draft;
        if (includeFrames &&
            matching != null &&
            previous?.framesRevision == framesRevision) {
          // A historical capture may have finished inside the preceding save.
          finalDraft = draft.copyWith(frames: matching.allFrames);
        } else if (provisional != null &&
            !(matching?.allFrames.contains(provisional) ?? false) &&
            draft.allFrames.contains(provisional)) {
          // An unwritten live attachment can be discarded by its capture owner.
          finalDraft = draft.copyWith(
            frames: draft.allFrames
                .where((frame) => frame != provisional)
                .toList(),
          );
        }
        if (await storage.finishPendingDraft(
          finalDraft,
          expected: matching ?? expected,
          accountRevision: account,
          accountScope: accountScope,
        )) {
          committed = finalDraft;
        }
      } catch (_) {
        if (updateUi &&
            mounted &&
            draftRevision == _noteDraftRevision &&
            account == CacheLifecycle.account.value &&
            accountScope == CacheLifecycle.accountScope) {
          _showTransientSnackBar('保存笔记失败，请稍后再试。');
        }
      } finally {
        if (identical(_noteSaveCompletion, operation)) {
          _noteSaveCompletion = null;
        }
        operation.result.complete(committed);
      }
      if (updateUi &&
          mounted &&
          draftRevision == _noteDraftRevision &&
          account == CacheLifecycle.account.value &&
          accountScope == CacheLifecycle.accountScope) {
        if (committed != null) {
          setState(() {
            _editingVideoNote = committed;
            if (framesRevision == _noteFramesRevision) {
              _noteFrames = committed!.allFrames;
            }
          });
        }
        if (_noteAutoSavePending && _noteSaveCompletion == null) {
          _noteAutoSavePending = false;
          _scheduleVideoNoteAutoSave();
        }
      }
    }());
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
    final bvid = _activeVideo.bvid;
    final draftRevision = _noteDraftRevision;
    var generation = _partSwitchGeneration;
    var sourceGeneration = _sourceGeneration;
    int? captureSerial;
    bool isCurrentCapture() =>
        mounted &&
        bvid == _activeVideo.bvid &&
        draftRevision == _noteDraftRevision &&
        generation == _partSwitchGeneration &&
        sourceGeneration == _sourceGeneration &&
        (captureSerial == null || _isCurrentAbRepeatCapture(captureSerial));
    final targetPosition = _notePosition;
    final VideoPart returnPart = _currentPart;
    final Duration returnPosition = _playbackSnapshot.position;
    final bool shouldResume = _playing;
    final VideoPart targetPart = _findVideoNotePart(_notePartCid);
    captureSerial = await _beginAbRepeatCapture();
    try {
      if (!isCurrentCapture()) return null;
      if (shouldResume) await _playbackService.pause();
      if (!isCurrentCapture()) return null;
      if (targetPart.cid != _currentPart.cid) {
        generation++;
        await _changePart(targetPart);
        if (generation == _partSwitchGeneration &&
            _currentPart.cid == targetPart.cid) {
          sourceGeneration = _sourceGeneration;
        }
        if (!isCurrentCapture() || _currentPart.cid != targetPart.cid) {
          return null;
        }
        await _playbackService.pause();
      }
      if (!isCurrentCapture()) return null;
      await _seekNativeTo(targetPosition, temporaryCapture: true);
      if (!isCurrentCapture()) return null;
      await _waitForNoteFramePosition(targetPosition);
      if (!isCurrentCapture()) return null;
      final path = await _playbackService.captureCurrentFrame();
      if (!isCurrentCapture()) {
        if (path != null) {
          await _videoNoteService.discardUnreferencedFrame(path);
        }
        return null;
      }
      return path;
    } finally {
      try {
        if (isCurrentCapture() && returnPart.cid != _currentPart.cid) {
          generation++;
          await _changePart(returnPart);
          if (generation == _partSwitchGeneration &&
              _currentPart.cid == returnPart.cid) {
            sourceGeneration = _sourceGeneration;
          }
          if (isCurrentCapture()) await _playbackService.pause();
        }
        if (isCurrentCapture() && returnPart.cid == _currentPart.cid) {
          _prepareAbRepeatCaptureRestore(returnPosition);
          await _seekNativeTo(returnPosition, temporaryCapture: true);
          if (isCurrentCapture() &&
              shouldResume &&
              _canResumeAfterNoteCapture) {
            await _playbackService.play();
          }
        }
      } finally {
        _endAbRepeatCapture();
      }
    }
  }

  /// 保存标题、正文、自动记录时间、视频位置和可选画面；自动保存不会反复弹出提示。
  Future<bool> _saveVideoNote({bool automatic = false}) async {
    if (_noteSaveCompletion != null || _noteSaving || _noteAutoSaving) {
      if (automatic) _noteAutoSavePending = true;
      return false;
    }
    if (!_noteDraftMatchesAccount) return false;
    final String enteredTitle = _noteTitleController.text.trim();
    final String body = _noteBodyController.text;
    if (enteredTitle.isEmpty && !automatic) {
      _showTransientSnackBar('请先填写笔记标题。');
      return false;
    }
    if (enteredTitle.isEmpty && body.trim().isEmpty) {
      return false;
    }
    if (automatic) {
      _noteAutoSaving = true;
    } else {
      _noteSaving = true;
    }
    _noteAutoSaveTimer?.cancel();
    _noteAutoSaveTimer = null;
    _noteAutoSavePending = false;
    final includeFrame = _includeCurrentFrame;
    final notePosition = _notePosition;
    final noteDraft = _snapshotPlayerNote(enteredTitle, body);
    final framesRevision = _noteFramesRevision;
    final draftRevision = _noteDraftRevision;
    final account = _noteDraftAccountRevision;
    final accountScope = _noteDraftAccountScope;
    final completion = _PendingPlayerNoteWrite(noteDraft.id, framesRevision);
    _noteSaveCompletion = completion;
    VideoNote? committed;
    final frames = noteDraft.allFrames.toList();
    // 自动保存只锁定保存按钮，不禁用输入框。
    setState(() {});
    bool frameFailed = false;
    try {
      if (includeFrame && frames.isEmpty && !automatic) {
        try {
          final framePath = await _captureFrameAtNotePosition();
          frameFailed = framePath == null;
          if (framePath != null) {
            frames.add(VideoNoteFrame(path: framePath, position: notePosition));
          }
        } catch (_) {
          // Optional screenshot failure must never discard a valid text note.
          frameFailed = true;
        }
      }
      final note = noteDraft.copyWith(frames: frames);
      if (account != CacheLifecycle.account.value ||
          accountScope != CacheLifecycle.accountScope) {
        // A manual historical capture may have waited across account changes.
        // Treat it as a failed save and let its owner clean up the new pixels.
        for (final frame in frames.where(
          (frame) => !noteDraft.allFrames.contains(frame),
        )) {
          await _videoNoteService.discardUnreferencedFrame(frame.path);
        }
        throw StateError('当前账号已变化，未保存旧笔记。');
      }
      await _videoNoteService.saveNote(note);
      committed = note;
      if (!mounted || note.bvid != _activeVideo.bvid) {
        return true;
      }
      setState(() {
        if (draftRevision == _noteDraftRevision &&
            account == CacheLifecycle.account.value &&
            accountScope == CacheLifecycle.accountScope) {
          _editingVideoNote = note;
          if (framesRevision == _noteFramesRevision) {
            _noteFrames = note.allFrames;
          }
        }
        _noteSaving = false;
        _noteAutoSaving = false;
        _notesLoading = true;
      });
      await _loadCurrentVideoNotes();
      if (mounted && !automatic) {
        _showTransientSnackBar(
          frameFailed ? '笔记文字已保存，截图未成功；可再次保存以重试截图。' : '笔记已保存到本机。',
        );
      }
    } on PlatformException catch (error) {
      if (!mounted) {
        return committed != null;
      }
      setState(() {
        _noteSaving = false;
        _noteAutoSaving = false;
      });
      _showTransientSnackBar(error.message ?? '截取当前视频画面失败。');
    } catch (_) {
      if (!mounted) {
        return committed != null;
      }
      setState(() {
        _noteSaving = false;
        _noteAutoSaving = false;
      });
      _showTransientSnackBar('保存笔记失败，请稍后再试。');
    } finally {
      completion.result.complete(committed);
      if (identical(_noteSaveCompletion, completion)) {
        _noteSaveCompletion = null;
        if (mounted && _noteAutoSavePending && _noteDraftMatchesAccount) {
          _noteAutoSavePending = false;
          _scheduleVideoNoteAutoSave();
        }
      }
    }
    return committed != null;
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
    _cancelLiveNoteFrame();
    if (_editingVideoNote?.id != note.id ||
        !_noteDraftMatchesAccount ||
        _deletingPlayerNoteId != null) {
      return;
    }
    // An accepted deletion owns this id from now on; leaving while an old
    // save is finishing must not cancel deletion or re-save the dirty draft.
    final revision = _noteDraftRevision;
    final account = _noteDraftAccountRevision;
    final accountScope = _noteDraftAccountScope;
    final storage = _videoNoteService;
    final previous = _noteSaveCompletion;
    final deletion = _PendingPlayerNoteWrite(note.id, _noteFramesRevision);
    _noteAutoSaveTimer?.cancel();
    _noteAutoSaveTimer = null;
    _noteAutoSavePending = false;
    _noteSaveCompletion = deletion;
    setState(() {
      _deletingPlayerNoteId = note.id;
      _noteSaving = true;
    });
    bool succeeded = false;
    try {
      await previous?.future;
      if (account != CacheLifecycle.account.value ||
          accountScope != CacheLifecycle.accountScope) {
        return;
      }
      await storage.deleteNote(note.id);
      succeeded = true;
    } catch (_) {
      if (mounted && account == CacheLifecycle.account.value) {
        _showTransientSnackBar('删除笔记失败，请稍后再试。');
      }
    } finally {
      if (identical(_noteSaveCompletion, deletion)) _noteSaveCompletion = null;
      deletion.result.complete(null);
      if (mounted) {
        setState(() {
          _deletingPlayerNoteId = null;
          _noteSaving = false;
        });
      }
    }
    if (succeeded &&
        mounted &&
        revision == _noteDraftRevision &&
        account == CacheLifecycle.account.value) {
      _startNewVideoNote();
      await _loadCurrentVideoNotes();
      if (mounted) _showTransientSnackBar('笔记已删除。');
    }
  }

  /// 创建播放器笔记编辑器，并把保存、删除、画面选择等操作连接到本机服务。
  Widget _buildVideoNoteComposer({required bool compact}) {
    return VideoNoteComposer(
      key: ValueKey<int>(_noteDraftRevision),
      titleController: _noteTitleController,
      bodyController: _noteBodyController,
      position: _notePosition,
      partPageNumber: _findVideoNotePart(_notePartCid).pageNumber,
      createdAt: _editingVideoNote?.createdAt,
      includeFrame: _includeCurrentFrame,
      frames: _noteFrames,
      onFramesChanged: _setNoteFrames,
      onAddFrame: () => unawaited(_appendCurrentNoteFrame()),
      addingFrame: _pendingLiveNoteFrame != null,
      saving: _noteSaving || _noteAutoSaving || _deletingPlayerNoteId != null,
      inputEnabled: !_noteSaving && _deletingPlayerNoteId == null,
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('这个视频还没有笔记，先写下第一条吧。'),
        ),
      );
    }
    final List<Size> tileSizes = _currentVideoNotes
        // 尺寸映射函数测量每条笔记的实际字体，避免大字号仍挤在固定高度内。
        .map(
          (VideoNote note) => measurePlayerNoteStripTile(
            context,
            title: note.title,
            positionLabel: formatVideoNotePosition(note.position),
            partLabel: 'P${note.partPageNumber}',
          ),
        )
        .toList();
    final double stripHeight = tileSizes.fold<double>(
      44,
      // 最大值函数让列表保留足够高度以容纳当前最高的卡片。
      (double height, Size size) => height > size.height ? height : size.height,
    );
    return SizedBox(
      height: stripHeight,
      child: HorizontalMouseScroll(
        child: ListView.separated(
          key: const Key('portrait-video-note-list'),
          scrollDirection: Axis.horizontal,
          itemCount: _currentVideoNotes.length,
          // 分隔函数给横向笔记卡片保留稳定间距。
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(width: 8),
          // 构建函数按测量宽度展示标题和时间点，点击仅选中编辑笔记。
          itemBuilder: (BuildContext context, int index) {
            final VideoNote note = _currentVideoNotes[index];
            return SizedBox(
              width: tileSizes[index].width,
              child: PlayerNoteTile(
                horizontal: true,
                title: note.title,
                positionLabel: formatVideoNotePosition(note.position),
                partLabel: 'P${note.partPageNumber}',
                selected: note.id == _editingVideoNote?.id,
                tapKey: Key('portrait-video-note-${note.id}'),
                partKey: Key('portrait-video-note-part-${note.id}'),
                // 选择函数仅载入笔记，视频跳转仍由编辑器独立按钮执行。
                onTap: () => _selectVideoNote(note),
              ),
            );
          },
        ),
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
        return PlayerNoteTile(
          title: note.title,
          positionLabel: formatVideoNotePosition(note.position),
          partLabel: 'P${note.partPageNumber}',
          selected: note.id == _editingVideoNote?.id,
          tapKey: Key('fullscreen-video-note-${note.id}'),
          // 选择函数只载入笔记内容，跳转仍需用户点击独立按钮。
          onTap: () => _selectVideoNote(note),
          scrollingTitle: SizedBox(
            height: measurePlayerNoteText(
              context,
              note.title,
              PlayerNoteTile.listTitleStyle,
            ).height.ceilToDouble(),
            child: _AutoScrollingText(
              text: note.title,
              style: PlayerNoteTile.listTitleStyle,
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

  /// 创建全屏侧边记笔记入口，放大控制栏时上移避开底部进度，打开后显示笔记本。
  Widget _buildFullscreenVideoNoteButton() {
    final size = PlayerControlSize(_playbackPreferences.controlScale);
    return Positioned(
      key: const Key('fullscreen-note-button'),
      right: 12,
      top: 0,
      bottom: 0,
      child: Align(
        alignment: Alignment(0, size.sideControlAlignmentY),
        child: Material(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            // 全屏记笔记按钮函数打开工作区并锁定当前播放时间点。
            onTap: () => unawaited(_openVideoNotes()),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12 * size.scale,
                vertical: 9 * size.scale,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.edit_note_rounded,
                    color: Colors.white,
                    size: 20 * size.scale,
                  ),
                  SizedBox(width: 5 * size.scale),
                  Text(
                    '记笔记',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14 * size.scale,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
