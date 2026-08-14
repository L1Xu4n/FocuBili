part of 'player_page.dart';

/// 区分关闭定时、按分钟倒计时和按完整播放次数暂停三种选择。
enum _SleepTimerChoiceKind { off, durationMinutes, playCount }

/// 保存定时关闭对话框的选择；value 为空表示用户还需要输入自定义数值。
class _SleepTimerChoice {
  /// 创建带明确类型和可选数值的定时关闭选择，避免再用正负数暗示业务含义。
  const _SleepTimerChoice(this.kind, [this.value]);

  final _SleepTimerChoiceKind kind;
  final int? value;
}

/// 在独立状态对象中管理自定义定时输入，确保控制器跟随弹窗动画完整释放。
class _CustomSleepTimerValueDialog extends StatefulWidget {
  /// 创建分钟数或播放次数输入弹窗。
  const _CustomSleepTimerValueDialog({required this.kind});

  final _SleepTimerChoiceKind kind;

  /// 创建持有输入控制器和校验错误的弹窗状态。
  @override
  State<_CustomSleepTimerValueDialog> createState() =>
      _CustomSleepTimerValueDialogState();
}

/// 管理自定义定时输入、范围校验和输入控制器生命周期。
class _CustomSleepTimerValueDialogState
    extends State<_CustomSleepTimerValueDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  /// 判断当前输入的是分钟数而不是播放次数。
  bool get _durationMode =>
      widget.kind == _SleepTimerChoiceKind.durationMinutes;

  /// 返回当前模式允许的最大正整数。
  int get _maximum => _durationMode ? 10080 : 9999;

  /// 释放输入控制器；此时弹窗退场动画已经不再使用它。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 校验输入并返回结果；非法输入只更新范围提示，不关闭弹窗。
  void _submit() {
    final int? value = int.tryParse(_controller.text.trim());
    if (value == null || value < 1 || value > _maximum) {
      setState(() => _errorText = '请输入 1～$_maximum 之间的整数');
      return;
    }
    Navigator.of(context).pop(value);
  }

  /// 创建数字输入框与取消、确定按钮。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_durationMode ? '自定义定时时长' : '自定义播放次数'),
      content: TextField(
        key: Key(
          _durationMode
              ? 'sleep-timer-custom-duration-input'
              : 'sleep-timer-custom-play-count-input',
        ),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          labelText: _durationMode ? '分钟数' : '播放次数',
          hintText: _durationMode ? '例如：25' : '例如：3',
          helperText: _durationMode
              ? '可输入 1～10080 分钟（最长 7 天）'
              : '当前这一轮也计入次数，可输入 1～9999 次',
          errorText: _errorText,
        ),
        // 键盘提交函数复用确认按钮的校验，输入无效时不会关闭对话框。
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          // 取消按钮函数关闭输入框并保留原来的定时设置。
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('sleep-timer-custom-confirm'),
          // 确认按钮函数只在输入为允许范围内的正整数时返回结果。
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 封装播放器控制层、播放命令、选集状态、桌面快捷键和设备状态栏刷新。
mixin _PlayerControlsCoordinator
    on
        State<PlayerPage>,
        _PlayerPlaybackSession,
        _PlayerFocusCoordinator,
        _PlayerGestureCoordinator,
        _PlayerNotesWorkspace,
        _PlayerViewportCoordinator,
        _PlayerOverlayCoordinator {
  static const Duration _controlsAutoHideDelay = Duration(seconds: 5);
  static const Duration _transientHintDuration = Duration(seconds: 3);
  static const AnimationStyle _playerPopupMenuAnimationStyle = AnimationStyle(
    duration: Duration(milliseconds: 100),
    reverseDuration: Duration(milliseconds: 80),
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  static const double _expandedPartItemHeight = 76;
  static const List<double> _playbackSpeeds = <double>[
    0.75,
    1,
    1.25,
    1.5,
    2,
    3,
  ];

  /// 说明控制层已经安排自动隐藏，供播放快照协调器避免重复创建计时器。
  @override
  bool get _controlsAutoHideScheduled => _controlsTimer != null;

  /// 根据当前真实播放状态向原生播放器发送播放或暂停命令。
  @override
  void _togglePlayback() {
    _showPlayerControls();
    unawaited(_setPlaybackActive(!_playing));
  }

  /// 执行原生播放或暂停命令，并把平台异常转换为页面可读的错误。
  @override
  Future<void> _setPlaybackActive(bool shouldPlay) async {
    _finishFocusSeekTransition(syncCurrentSnapshot: false);
    try {
      if (shouldPlay) {
        await _playbackService.play();
      } else {
        await _playbackService.pause();
      }
    } on PlatformException catch (error) {
      _showPlaybackError('无法控制播放：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法控制播放：$error');
    }
  }

  /// 响应画面单击：只显示或隐藏控制层，不直接改变播放状态。
  void _toggleControls() {
    if (_controlsLocked) {
      return;
    }
    if (_showControls) {
      _hideControls();
    } else {
      _showPlayerControls();
    }
  }

  /// 显示控制层并在播放状态下重新开始自动收起倒计时。
  @override
  void _showPlayerControls() {
    if (_controlsLocked) {
      return;
    }
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    _restartControlsAutoHideTimer();
  }

  /// 隐藏控制层并停止自动收起倒计时。
  void _hideControls() {
    _stopControlsAutoHideTimer();
    if (_showControls) {
      setState(() => _showControls = false);
    }
  }

  /// 在视频播放且控制层可见时，安排五秒后自动隐藏控制层。
  @override
  void _restartControlsAutoHideTimer() {
    _stopControlsAutoHideTimer();
    if (!_showControls ||
        !_playing ||
        _playbackSnapshot.isInPictureInPicture ||
        _isDraggingProgress ||
        _temporarySpeedActive ||
        _horizontalScrubbing) {
      return;
    }
    _controlsTimer = Timer(_controlsAutoHideDelay, () {
      if (mounted &&
          _showControls &&
          _playing &&
          !_playbackSnapshot.isInPictureInPicture &&
          !_isDraggingProgress &&
          !_temporarySpeedActive &&
          !_horizontalScrubbing) {
        setState(() {
          _showControls = false;
          _controlsTimer = null;
        });
      } else {
        _controlsTimer = null;
      }
    });
  }

  /// 取消已有控制层倒计时，避免多个计时器同时修改页面状态。
  @override
  void _stopControlsAutoHideTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
  }

  /// 请求原生播放器按相对时长跳转；成功后从目标位置重新生成弹幕，历史内容不会从中间补画。
  @override
  Future<void> _seekNativeBy(Duration offset) async {
    final int targetMilliseconds = (_playbackSnapshot.position + offset)
        .inMilliseconds
        .clamp(0, _displayDuration.inMilliseconds);
    _beginFocusSeekTransition();
    try {
      await _playbackService.seekBy(offset);
      _restartDanmakuPresentationFrom(
        Duration(milliseconds: targetMilliseconds),
      );
    } on PlatformException catch (error) {
      _showPlaybackError('无法跳转进度：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法跳转进度：$error');
    }
  }

  /// 执行绝对跳转并从目标时间重新生成弹幕，确保跳转前的历史弹幕不会出现在屏幕中段。
  @override
  Future<void> _seekNativeTo(Duration position) async {
    _beginFocusSeekTransition();
    await _playbackService.seekTo(position);
    _restartDanmakuPresentationFrom(position);
  }

  /// 把进度条比例换算为真实毫秒位置，再请求原生播放器跳转。
  @override
  Future<void> _seekToProgress(double progress) async {
    final Duration target = Duration(
      milliseconds: (_displayDuration.inMilliseconds * progress).round(),
    );
    try {
      await _seekNativeTo(target);
    } on PlatformException catch (error) {
      _showPlaybackError('无法跳转进度：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法跳转进度：$error');
    }
  }

  /// 请求原生播放器切换倍速，并让控制层继续显示以便用户确认选择。
  Future<void> _changePlaybackSpeed(double speed) async {
    _showPlayerControls();
    try {
      await _playbackService.setPlaybackSpeed(speed);
      if (mounted) {
        setState(() => _playbackSpeed = speed);
        _syncDanmakuAnimation(_playbackSnapshot.copyWith(speed: speed));
      }
    } on PlatformException catch (error) {
      _showPlaybackError('无法切换倍速：${error.message ?? error.code}');
    } catch (error) {
      _showPlaybackError('无法切换倍速：$error');
    }
  }

  /// 请求原生播放器保留当前进度并切换到所选清晰度。
  @override
  Future<void> _changeQuality(int quality) async {
    if (quality == _currentQuality || _pendingQualitySelection == quality) {
      return;
    }
    _showPlayerControls();
    setState(() {
      _pendingQualitySelection = quality;
      _qualitySelectionSawLoading = false;
      _playerNotice = null;
    });
    _playerNoticeTimer?.cancel();
    try {
      await _playbackService.selectQuality(quality);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _pendingQualitySelection = null);
      }
      _showMembershipQualityNotice(error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _pendingQualitySelection = null);
      }
      _showMembershipQualityNotice(error.toString());
    }
  }

  /// 用播放器内三秒悬浮提示说明高画质切换失败通常与大会员权限有关。
  @override
  void _showMembershipQualityNotice([String? details]) {
    if (!mounted) {
      return;
    }
    final String suffix = details == null || details.trim().isEmpty
        ? ''
        : '（${details.trim()}）';
    _showPlayerNotice('画质切换失败：可能未开通大会员或当前账号无此画质权限$suffix');
  }

  /// 在播放器画面内部显示三秒悬浮提示，避免系统 SnackBar 遮住底部播放栏。
  @override
  void _showPlayerNotice(String message) {
    _playerNoticeTimer?.cancel();
    setState(() => _playerNotice = message);
    _playerNoticeTimer = Timer(_transientHintDuration, () {
      if (mounted) {
        setState(() => _playerNotice = null);
      }
    });
  }

  /// 标记进度条正被手指拖动，并暂停自动隐藏以方便精确调整。
  void _startProgressDrag(double value) {
    _isDraggingProgress = true;
    _stopControlsAutoHideTimer();
  }

  /// 只更新拖动过程中的本地显示，避免每一像素都向原生播放器发网络无关的命令。
  void _updateProgressDrag(double value) {
    setState(() => _progress = value);
  }

  /// 结束进度条拖动后把最终位置发送给原生播放器，并恢复自动隐藏策略。
  void _finishProgressDrag(double value) {
    _isDraggingProgress = false;
    setState(() => _progress = value);
    unawaited(_seekToProgress(value));
    _restartControlsAutoHideTimer();
  }

  /// 根据当前进度生成“当前时间 / 总时长”的播放器文字。
  String _formatProgress() {
    final int current = (_progress * _displayDuration.inSeconds).round();
    return '${_formatSeconds(current)} / ${_formatSeconds(_displayDuration.inSeconds)}';
  }

  /// 把秒数转换成分秒格式；超过一小时后自动显示“时:分:秒”。
  @override
  String _formatSeconds(int totalSeconds) {
    final int safeSeconds = totalSeconds < 0 ? 0 : totalSeconds;
    final int hours = safeSeconds ~/ 3600;
    final int minutes = (safeSeconds % 3600) ~/ 60;
    final int seconds = safeSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// 把倍速数字格式化为播放器按钮使用的简短文字。
  String _formatSpeed(double speed) {
    return speed == speed.roundToDouble()
        ? '${speed.toInt()}x'
        : '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '')}x';
  }

  /// 返回当前清晰度的用户可读名称，未知编号时显示原始质量编号。
  String _currentQualityLabel() {
    for (final PlaybackQuality quality in _availableQualities) {
      if (quality.id == _currentQuality) {
        return quality.label;
      }
    }
    return 'Q$_currentQuality';
  }

  /// 按当前正序或倒序设置返回用于界面的分P列表副本。
  List<VideoPart> _orderedParts() {
    final List<VideoPart> parts = List<VideoPart>.of(_activeVideo.parts)
      ..sort(
        (VideoPart left, VideoPart right) =>
            left.pageNumber.compareTo(right.pageNumber),
      );
    return _partsAscending ? parts : parts.reversed.toList(growable: false);
  }

  /// 打开铺满播放器下方空间的双列选集面板并定位当前分P。
  void _openPartSelector() {
    _stopControlsAutoHideTimer();
    setState(() {
      _partSelectorExpanded = true;
      _showControls = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateCurrentPart());
  }

  /// 关闭展开选集面板，恢复视频信息和单行横向选集。
  void _closePartSelector() {
    setState(() => _partSelectorExpanded = false);
    _restartControlsAutoHideTimer();
  }

  /// 切换选集正序或倒序，并保持当前分P仍在可见区域。
  void _setPartOrdering(bool ascending) {
    setState(() => _partsAscending = ascending);
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateCurrentPart());
  }

  /// 按当前排序计算目标行，将双列列表滚动到正在播放的分P。
  void _locateCurrentPart() {
    if (!_partScrollController.hasClients) {
      return;
    }
    final List<VideoPart> parts = _orderedParts();
    final int index = parts.indexWhere(
      (VideoPart part) => part.cid == _currentPart.cid,
    );
    if (index < 0) {
      return;
    }
    final double target = (index ~/ 2) * (_expandedPartItemHeight + 8);
    _partScrollController.animateTo(
      target.clamp(0, _partScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  /// 处理桌面播放器快捷键；文本输入框获得焦点时完全交还键盘事件。
  KeyEventResult _handlePlayerKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || _isTextEditingFocused()) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _togglePlayback();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-5, showFeedback: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(5, showFeedback: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _adjustDesktopVolume(0.05);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _adjustDesktopVolume(-0.05);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_controlsLocked) {
        _toggleControlsLock();
      } else if (_notesOpen) {
        _closeVideoNotes();
      } else if (_partSelectorExpanded) {
        setState(() => _partSelectorExpanded = false);
      } else if (_fullscreen) {
        unawaited(_toggleFullscreen());
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 判断当前主焦点是否位于文本编辑器内部，避免空格和方向键破坏笔记输入。
  bool _isTextEditingFocused() {
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    return focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// 按五个百分点调整桌面音量，并复用播放器中央反馈提示。
  void _adjustDesktopVolume(double delta) {
    _volume = (_volume + delta).clamp(0, 1).toDouble();
    unawaited(_playbackService.setMediaVolume(_volume));
    _showAdjustmentFeedback('音量 ${(_volume * 100).round()}%');
    _scheduleSeekFeedbackClear();
  }

  /// 锁定或解锁全屏控制层；锁定后仅保留左侧解锁按钮并停用画面手势。
  void _toggleControlsLock() {
    if (!_fullscreen) {
      return;
    }
    _stopControlsAutoHideTimer();
    setState(() {
      _controlsLocked = !_controlsLocked;
      _showControls = !_controlsLocked;
      if (_controlsLocked) {
        _partSelectorExpanded = false;
      }
    });
    if (!_controlsLocked) {
      _restartControlsAutoHideTimer();
    }
  }

  /// 在本帧布局确定后按顶部栏真实可见性启停状态刷新，避免用平台尺寸猜测布局。
  void _schedulePlayerStatusVisibility(bool visible) {
    _pendingPlayerStatusVisible = visible;
    if (!visible) {
      _stopPlayerStatusUpdates();
      return;
    }
    if (_playerStatusSyncScheduled) {
      return;
    }
    _playerStatusSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playerStatusSyncScheduled = false;
      if (!mounted) {
        return;
      }
      if (_pendingPlayerStatusVisible && _playerStatusTimer == null) {
        _startPlayerStatusUpdates();
      }
    });
  }

  /// 播放器顶部可见期间每分钟刷新时间和电量，横屏工作台与全屏直接复用结果。
  void _startPlayerStatusUpdates() {
    _stopPlayerStatusUpdates();
    _playerClock = DateTime.now();
    unawaited(_refreshPlayerDeviceStatus());
    _playerStatusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _refreshPlayerStatus();
    });
  }

  /// 停止播放器设备状态定时器，避免退出页面后仍保留回调。
  void _stopPlayerStatusUpdates() {
    _playerStatusTimer?.cancel();
    _playerStatusTimer = null;
  }

  /// 立即刷新显示时间，并异步读取 Android 提供的当前电量百分比。
  void _refreshPlayerStatus() {
    if (!mounted) {
      return;
    }
    setState(() => _playerClock = DateTime.now());
    unawaited(_refreshPlayerDeviceStatus());
  }

  /// 读取电量和网络类型后确认页面仍存在，再更新顶部小型状态栏。
  Future<void> _refreshPlayerDeviceStatus() async {
    final int? batteryPercent = await _loadBatteryPercentSafely();
    final DeviceNetworkType networkType = await _loadNetworkTypeSafely();
    if (!mounted) {
      return;
    }
    setState(() {
      _batteryPercent = batteryPercent;
      _networkType = networkType;
    });
  }

  /// 处理顶部返回按钮：先关闭笔记，再退出全屏或返回上一支合集视频。
  void _handleBackPressed() {
    if (_controlsLocked) {
      _toggleControlsLock();
    } else if (_notesOpen) {
      _closeVideoNotes();
    } else if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_collectionVideoBackStack.isNotEmpty) {
      unawaited(_restorePreviousCollectionVideo());
    } else {
      unawaited(_requestLeavePlayer());
    }
  }

  /// 接收系统返回结果：依次关闭笔记、全屏和合集内部页面，再允许离开播放页。
  void _handlePopInvoked(bool didPop, Object? result) {
    if (didPop) {
      return;
    }
    if (_controlsLocked) {
      _toggleControlsLock();
    } else if (_notesOpen) {
      _closeVideoNotes();
    } else if (_fullscreen) {
      unawaited(_toggleFullscreen());
    } else if (_collectionVideoBackStack.isNotEmpty) {
      unawaited(_restorePreviousCollectionVideo());
    } else {
      unawaited(_requestLeavePlayer());
    }
  }

  /// 根据菜单操作打开字幕或弹幕设置，或切换播放器画面比例。
  void _handleMoreSettingsSelection(_PlayerMoreMenuAction action) {
    switch (action) {
      case _PlayerMoreMenuAction.subtitles:
        unawaited(_showSubtitleSelector());
        return;
      case _PlayerMoreMenuAction.danmakuSettings:
        unawaited(_showDanmakuSettings());
        return;
      case _PlayerMoreMenuAction.playbackLoop:
        _togglePlaybackLoop();
        return;
      case _PlayerMoreMenuAction.sleepTimer:
        unawaited(_showSleepTimerDialog());
        return;
      case _PlayerMoreMenuAction.fitContain:
        _changeVideoFitMode(_VideoFitMode.contain);
        return;
      case _PlayerMoreMenuAction.fitCover:
        _changeVideoFitMode(_VideoFitMode.cover);
        return;
      case _PlayerMoreMenuAction.fitStretch:
        _changeVideoFitMode(_VideoFitMode.stretch);
        return;
    }
  }

  /// 切换当前播放页的无限循环，不写入全局偏好设置。
  void _togglePlaybackLoop() {
    setState(() {
      _playbackLoopEnabled = !_playbackLoopEnabled;
      if (_playbackLoopEnabled) {
        _completedPlayCount = 0;
      }
    });
    _showTransientSnackBar(_playbackLoopEnabled ? '已开启当前分P循环播放' : '已关闭循环播放');
    _showPlayerControls();
  }

  /// 返回当前定时关闭设置的简短菜单文字。
  String get _sleepTimerSummary {
    if (_pauseAfterPlayCount != null) {
      return '定时关闭：播放 $_pauseAfterPlayCount 次后';
    }
    final DateTime? deadline = _sleepTimerDeadline;
    if (deadline != null && deadline.isAfter(DateTime.now())) {
      final int minutes = deadline.difference(DateTime.now()).inMinutes + 1;
      return '定时关闭：约 $minutes 分钟后';
    }
    return '定时关闭';
  }

  /// 显示快捷选项与自定义入口；“关闭”统一表示到点后暂停播放器。
  Future<void> _showSleepTimerDialog() async {
    _SleepTimerChoice? selected = await showDialog<_SleepTimerChoice>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: const Text('定时关闭（到时暂停）'),
        children: <Widget>[
          SimpleDialogOption(
            key: const Key('sleep-timer-off'),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(const _SleepTimerChoice(_SleepTimerChoiceKind.off, 0)),
            child: const Text('关闭定时'),
          ),
          for (final int minutes in <int>[15, 30, 60, 90])
            SimpleDialogOption(
              key: Key('sleep-timer-$minutes-minutes'),
              onPressed: () => Navigator.of(dialogContext).pop(
                _SleepTimerChoice(
                  _SleepTimerChoiceKind.durationMinutes,
                  minutes,
                ),
              ),
              child: Text('$minutes 分钟后暂停'),
            ),
          SimpleDialogOption(
            key: const Key('sleep-timer-custom-duration'),
            onPressed: () => Navigator.of(dialogContext).pop(
              const _SleepTimerChoice(_SleepTimerChoiceKind.durationMinutes),
            ),
            child: const Text('自定义时长…'),
          ),
          for (final int count in <int>[1, 2, 3, 5])
            SimpleDialogOption(
              key: Key('sleep-timer-$count-plays'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_SleepTimerChoice(_SleepTimerChoiceKind.playCount, count)),
              child: Text('播放 $count 次后暂停'),
            ),
          SimpleDialogOption(
            key: const Key('sleep-timer-custom-play-count'),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(const _SleepTimerChoice(_SleepTimerChoiceKind.playCount)),
            child: const Text('自定义播放次数…'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) {
      return;
    }
    if (selected.value == null) {
      final int? customValue = await _showCustomSleepTimerValueDialog(
        selected.kind,
      );
      if (!mounted || customValue == null) {
        return;
      }
      selected = _SleepTimerChoice(selected.kind, customValue);
    }
    _applySleepTimerChoice(selected);
  }

  /// 请求一个正整数的自定义分钟数或播放次数，并在输入非法或过大时留在对话框提示。
  Future<int?> _showCustomSleepTimerValueDialog(
    _SleepTimerChoiceKind kind,
  ) async {
    return showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _CustomSleepTimerValueDialog(kind: kind),
    );
  }

  /// 将已经校验的选择写入播放器状态，并保证时长与次数两种模式互斥。
  void _applySleepTimerChoice(_SleepTimerChoice selected) {
    final int value = selected.value ?? 0;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (selected.kind == _SleepTimerChoiceKind.off) {
      setState(() {
        _sleepTimerDeadline = null;
        _pauseAfterPlayCount = null;
        _completedPlayCount = 0;
      });
      _showTransientSnackBar('已关闭定时暂停');
      return;
    }
    if (selected.kind == _SleepTimerChoiceKind.playCount) {
      setState(() {
        _sleepTimerDeadline = null;
        _pauseAfterPlayCount = value;
        _completedPlayCount = 0;
        _playbackLoopEnabled = value > 1;
      });
      _showTransientSnackBar('将在播放 $value 次后暂停');
      return;
    }
    final Duration duration = Duration(minutes: value);
    setState(() {
      _sleepTimerDeadline = DateTime.now().add(duration);
      _pauseAfterPlayCount = null;
      _completedPlayCount = 0;
    });
    _sleepTimer = Timer(duration, _pauseForSleepTimer);
    _showTransientSnackBar('将在 $value 分钟后暂停');
  }

  /// 倒计时到期后暂停播放器并清除本次定时状态。
  void _pauseForSleepTimer() {
    if (!mounted) {
      return;
    }
    setState(() {
      _sleepTimerDeadline = null;
      _pauseAfterPlayCount = null;
    });
    unawaited(_setPlaybackActive(false));
    _showTransientSnackBar('定时关闭时间已到，视频已暂停');
  }

  /// 保存用户选择的画面比例，并用三秒提示确认该设置只作用于渲染层。
  void _changeVideoFitMode(_VideoFitMode mode) {
    if (_videoFitMode != mode) {
      setState(() => _videoFitMode = mode);
    }
    _showAdjustmentFeedback('画面比例：${_videoFitModeLabel(mode)}');
    _scheduleSeekFeedbackClear();
    _showPlayerControls();
  }

  /// 将内部画面比例枚举转换为菜单和提示中使用的中文名称。
  String _videoFitModeLabel(_VideoFitMode mode) {
    switch (mode) {
      case _VideoFitMode.contain:
        return '适应画面';
      case _VideoFitMode.cover:
        return '填充画面';
      case _VideoFitMode.stretch:
        return '拉伸铺满';
    }
  }

  /// 请求 Android 原生画中画；失败时用三秒提示说明系统或播放状态限制。
  Future<void> _enterPictureInPicture() async {
    final double aspectRatio = _playbackSnapshot.videoAspectRatio > 0
        ? _playbackSnapshot.videoAspectRatio
        : 16 / 9;
    try {
      final bool entered = await _playbackService.enterPictureInPicture(
        aspectRatio,
      );
      if (!mounted) {
        return;
      }
      if (entered) {
        _hideControls();
      } else {
        _showTransientSnackBar('无法进入画中画，请检查系统是否允许画中画。');
      }
    } on PlatformException catch (error) {
      _showTransientSnackBar(error.message ?? '当前设备暂不支持画中画。');
    } catch (_) {
      _showTransientSnackBar('无法进入画中画，请稍后重试。');
    }
  }

  /// 显示统一持续三秒的系统临时提示。
  @override
  void _showTransientSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: _transientHintDuration),
      );
  }

  /// 由页面状态类提供控制层自动隐藏计时器。
  Timer? get _controlsTimer;
  set _controlsTimer(Timer? value);

  /// 由页面状态类提供播放器内短消息计时器。
  Timer? get _playerNoticeTimer;
  set _playerNoticeTimer(Timer? value);

  /// 由页面状态类提供播放器顶部状态刷新计时器。
  Timer? get _playerStatusTimer;
  set _playerStatusTimer(Timer? value);

  /// 由页面状态类提供倒计时暂停计时器。
  Timer? get _sleepTimer;
  set _sleepTimer(Timer? value);

  /// 由页面状态类提供倒计时暂停的绝对截止时间。
  DateTime? get _sleepTimerDeadline;
  set _sleepTimerDeadline(DateTime? value);

  /// 由播放会话提供循环播放开关。
  @override
  bool get _playbackLoopEnabled;
  @override
  set _playbackLoopEnabled(bool value);

  /// 由播放会话提供播放次数暂停目标。
  @override
  int? get _pauseAfterPlayCount;
  @override
  set _pauseAfterPlayCount(int? value);

  /// 由播放会话提供已经完整播放的次数。
  @override
  int get _completedPlayCount;
  @override
  set _completedPlayCount(int value);

  /// 由页面状态类提供播放器内短消息文字。
  set _playerNotice(String? value);

  /// 由页面状态类提供展开选集面板状态。
  bool get _partSelectorExpanded;
  set _partSelectorExpanded(bool value);

  /// 由页面状态类提供分 P 排序方向。
  bool get _partsAscending;
  set _partsAscending(bool value);

  /// 由页面状态类提供当前画面比例模式。
  _VideoFitMode get _videoFitMode;
  set _videoFitMode(_VideoFitMode value);

  /// 由页面状态类提供展开选集的滚动控制器。
  ScrollController get _partScrollController;

  /// 由页面状态类提供播放器顶部显示的当前时间。
  set _playerClock(DateTime value);

  /// 由页面状态类提供播放器顶部显示的电量。
  set _batteryPercent(int? value);

  /// 由页面状态类提供播放器顶部显示的网络类型。
  set _networkType(DeviceNetworkType value);

  /// 由页面状态类更新进度条是否正在拖动。
  set _isDraggingProgress(bool value);

  /// 由页面状态类标记状态栏同步回调是否已经排队。
  bool get _playerStatusSyncScheduled;
  set _playerStatusSyncScheduled(bool value);

  /// 由页面状态类提供下一帧要求的顶部状态栏可见性。
  bool get _pendingPlayerStatusVisible;
  set _pendingPlayerStatusVisible(bool value);

  /// 由页面状态类提供安全读取设备电量的入口。
  Future<int?> _loadBatteryPercentSafely();

  /// 由视频协调器切换到用户选择的分 P。
  @override
  Future<void> _changePart(VideoPart part);

  /// 由视频协调器恢复合集返回栈中的上一支视频。
  Future<void> _restorePreviousCollectionVideo();

  /// 由视频协调器提供当前合集内部的视频返回栈。
  List<VideoPreview> get _collectionVideoBackStack;

  /// 取消控制层计时器并释放选集滚动控制器。
  void _disposePlayerControlsCoordinator() {
    _controlsTimer?.cancel();
    _playerNoticeTimer?.cancel();
    _playerStatusTimer?.cancel();
    _sleepTimer?.cancel();
    _partScrollController.dispose();
  }
}
