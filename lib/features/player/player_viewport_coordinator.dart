part of 'player_page.dart';

/// 标识播放页希望 Android 系统栏采用的三种可见状态。
enum _PlayerSystemUiLayout { standard, landscapePlayer, fullscreen }

/// 封装播放器方向策略、系统栏模式、移动端自动全屏和桌面窗口全屏。
mixin _PlayerViewportCoordinator
    on State<PlayerPage>, _PlayerGestureCoordinator, _PlayerNotesWorkspace {
  @override
  bool _fullscreen = false;
  bool _controlsLocked = false;
  bool _fullscreenEnteredByOrientation = false;
  bool _suppressAutoFullscreenUntilPortrait = false;
  bool _restoreOrientationChoicesOnPortrait = false;
  bool _orientationSyncScheduled = false;
  bool _systemUiSyncScheduled = false;
  _PlayerSystemUiLayout? _pendingSystemUiLayout;
  _PlayerSystemUiLayout? _appliedSystemUiLayout;

  /// 由播放器状态类重新锚定弹幕，使尺寸变化前后的弹幕位置保持连续。
  void _reanchorDanmakuForViewportChange();

  /// 播放页存活期间让手机可旋转全屏，并让 Android 平板继续保持横屏工作台。
  Future<void> _allowPlayerOrientations() async {
    final List<FlutterView> views = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .toList();
    if (views.isEmpty) {
      return;
    }
    final List<DeviceOrientation> orientations =
        DeviceOrientationPolicy.playerOrientations(
          logicalSize: DeviceOrientationPolicy.logicalSizeForView(views.first),
          isAndroid: AppPlatformDetector.current == AppPlatform.android,
        );
    if (orientations.isNotEmpty) {
      await SystemChrome.setPreferredOrientations(orientations);
    }
  }

  /// 把多次系统尺寸变化合并到一帧处理，避免旋转动画中反复进出全屏。
  @override
  void _scheduleOrientationSync() {
    if (widget.playbackService != null || _orientationSyncScheduled) {
      return;
    }
    _orientationSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _orientationSyncScheduled = false;
      _syncFullscreenWithOrientation();
    });
  }

  /// 把构建期得到的横屏状态延后到帧末同步，避免在 build 中直接修改 Android 系统栏。
  void _schedulePlayerSystemUiSync({required bool landscapeLayout}) {
    if (widget.playbackService != null) {
      return;
    }
    _pendingSystemUiLayout = _fullscreen
        ? _PlayerSystemUiLayout.fullscreen
        : landscapeLayout
        ? _PlayerSystemUiLayout.landscapePlayer
        : _PlayerSystemUiLayout.standard;
    if (_systemUiSyncScheduled) {
      return;
    }
    _systemUiSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _systemUiSyncScheduled = false;
      final _PlayerSystemUiLayout? target = _pendingSystemUiLayout;
      if (target != null) {
        unawaited(_applyPlayerSystemUiLayout(target));
      }
    });
  }

  /// 应用播放页系统栏模式：横屏仅隐藏顶部状态栏，全屏同时隐藏顶部和底部系统栏。
  Future<void> _applyPlayerSystemUiLayout(_PlayerSystemUiLayout target) async {
    if (!mounted || _appliedSystemUiLayout == target) {
      return;
    }
    switch (target) {
      case _PlayerSystemUiLayout.standard:
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      case _PlayerSystemUiLayout.landscapePlayer:
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: const <SystemUiOverlay>[SystemUiOverlay.bottom],
        );
      case _PlayerSystemUiLayout.fullscreen:
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (mounted) {
      _appliedSystemUiLayout = target;
    }
  }

  /// 临时打开普通系统栏供下层页面使用，并让播放页返回后重新计算横屏系统栏状态。
  Future<void> _showStandardSystemUiForNestedRoute() async {
    if (widget.playbackService != null) {
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _appliedSystemUiLayout = null;
  }

  /// 横屏自动进入全屏、竖屏退出自动全屏；笔记打开时不自动改变布局。
  void _syncFullscreenWithOrientation() {
    if (!mounted) {
      return;
    }
    if (AdaptiveLayout.usesWorkspace(MediaQuery.sizeOf(context))) {
      _suppressAutoFullscreenUntilPortrait = false;
      _restoreOrientationChoicesOnPortrait = false;
      if (_fullscreen && _fullscreenEnteredByOrientation) {
        unawaited(
          _setFullscreen(
            false,
            updateOrientation: false,
            enteredByOrientation: true,
          ),
        );
      }
      return;
    }
    final Orientation orientation = MediaQuery.orientationOf(context);
    if (orientation == Orientation.portrait) {
      _suppressAutoFullscreenUntilPortrait = false;
      if (_restoreOrientationChoicesOnPortrait) {
        _restoreOrientationChoicesOnPortrait = false;
        unawaited(_allowPlayerOrientations());
      }
      if (_fullscreen && _fullscreenEnteredByOrientation) {
        unawaited(
          _setFullscreen(
            false,
            updateOrientation: false,
            enteredByOrientation: true,
          ),
        );
      }
      return;
    }
    if (!_fullscreen && !_notesOpen && !_suppressAutoFullscreenUntilPortrait) {
      unawaited(
        _setFullscreen(
          true,
          updateOrientation: false,
          enteredByOrientation: true,
        ),
      );
    }
  }

  /// 响应全屏按钮；手动退出时先要求设备回到竖屏，再重新允许后续自动旋转。
  Future<void> _toggleFullscreen() async {
    final bool nextFullscreen = !_fullscreen;
    if (!nextFullscreen) {
      _suppressAutoFullscreenUntilPortrait = true;
      _restoreOrientationChoicesOnPortrait = true;
    }
    await _setFullscreen(nextFullscreen);
  }

  /// 统一切换全屏布局，并区分按钮触发和设备旋转触发的方向控制行为。
  Future<void> _setFullscreen(
    bool nextFullscreen, {
    bool updateOrientation = true,
    bool enteredByOrientation = false,
  }) async {
    if (!mounted || _fullscreen == nextFullscreen) {
      return;
    }
    _reanchorDanmakuForViewportChange();
    setState(() {
      _fullscreen = nextFullscreen;
      _fullscreenEnteredByOrientation = nextFullscreen && enteredByOrientation;
      _controlsLocked = nextFullscreen ? _controlsLocked : false;
      _showControls = true;
      // 从竖屏笔记本进入全屏时直接挂载全屏工作区；退出时保留笔记打开状态给竖屏布局继续使用。
      _notesOverlayMounted = nextFullscreen && _notesOpen;
    });
    _restartControlsAutoHideTimer();
    if (_playbackService is PlaybackVideoSurface) {
      try {
        await windowManager.setFullScreen(nextFullscreen);
      } on MissingPluginException {
        // 组件测试或插件暂不可用时仍保留播放器内部全屏布局。
      } on PlatformException {
        // Windows 拒绝窗口全屏切换时仍允许用户使用应用内全屏控制层。
      }
    }
    if (nextFullscreen) {
      if (updateOrientation) {
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _appliedSystemUiLayout = _PlayerSystemUiLayout.fullscreen;
    } else if (updateOrientation) {
      await _restoreSystemUi();
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _appliedSystemUiLayout = _PlayerSystemUiLayout.standard;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      _reanchorDanmakuForViewportChange();
    }
  }

  /// 离开全屏后恢复手机竖屏或平板横屏，并重新启用 edge-to-edge 系统栏。
  Future<void> _restoreSystemUi() async {
    if (_playbackService is PlaybackVideoSurface) {
      try {
        await windowManager.setFullScreen(false);
      } on MissingPluginException {
        // 组件测试没有窗口插件时无需恢复系统窗口状态。
      } on PlatformException {
        // 窗口已经销毁时恢复请求可能失败，不影响播放器资源释放。
      }
    }
    final List<FlutterView> views = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .toList();
    if (views.isNotEmpty) {
      final List<DeviceOrientation> orientations =
          DeviceOrientationPolicy.startupOrientations(
            logicalSize: DeviceOrientationPolicy.logicalSizeForView(
              views.first,
            ),
            isAndroid: AppPlatformDetector.current == AppPlatform.android,
          );
      if (orientations.isNotEmpty) {
        await SystemChrome.setPreferredOrientations(orientations);
      }
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _appliedSystemUiLayout = _PlayerSystemUiLayout.standard;
  }

  /// 返回播放页后重新隐藏横屏状态栏，并立即执行一次布局对应的系统栏同步。
  void _resumePlayerSystemUiAfterNestedRoute() {
    _appliedSystemUiLayout = null;
    final Size size = MediaQuery.sizeOf(context);
    _schedulePlayerSystemUiSync(landscapeLayout: size.width > size.height);
  }
}
