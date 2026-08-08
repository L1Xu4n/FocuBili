import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/focus/focus_timer_controller.dart';
import 'features/focus/focus_timer_scope.dart';
import 'features/focus/focus_completion_dialog.dart';
import 'features/onboarding/first_launch_gate.dart';
import 'features/player/player_page.dart';
import 'features/profile/app_theme_mode_controller.dart';
import 'features/shell/main_shell.dart';
import 'models/focus_session.dart';
import 'models/video_preview.dart';
import 'services/app_update_service.dart';
import 'services/bilibili_deep_link_service.dart';
import 'services/bilibili_service.dart';

/// 焦点哔哩的根组件，统一配置主题、路由和调试标记。
class FocuBiliApp extends StatefulWidget {
  /// 创建应用根组件；测试可以传入可控时钟的专注控制器。
  const FocuBiliApp({
    super.key,
    this.focusTimerController,
    this.appUpdateController,
    this.appThemeModeController,
    this.deepLinkService,
    this.videoService,
    this.checkForUpdatesOnStart = false,
  });

  final FocusTimerController? focusTimerController;
  final AppUpdateController? appUpdateController;
  final AppThemeModeController? appThemeModeController;
  final IncomingDeepLinkService? deepLinkService;
  final BilibiliService? videoService;
  final bool checkForUpdatesOnStart;

  /// 创建持有全应用专注状态的根组件状态。
  @override
  State<FocuBiliApp> createState() => _FocuBiliAppState();
}

/// 初始化并释放全应用唯一的专注计时控制器。
class _FocuBiliAppState extends State<FocuBiliApp> {
  late final FocusTimerController _focusTimerController;
  late final bool _ownsFocusTimerController;
  late final AppUpdateController _appUpdateController;
  late final bool _ownsAppUpdateController;
  late final AppThemeModeController _appThemeModeController;
  late final bool _ownsAppThemeModeController;
  late final IncomingDeepLinkService _deepLinkService;
  late final BilibiliService _videoService;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  String? _handledCompletionId;
  bool _completionDialogOpen = false;
  bool _firstLaunchReady = false;
  bool _deepLinkOpening = false;
  BilibiliVideoDeepLinkTarget? _pendingDeepLink;

  /// 初始化专注控制器并异步恢复本机未结束的计时。
  @override
  void initState() {
    super.initState();
    _ownsFocusTimerController = widget.focusTimerController == null;
    _focusTimerController =
        widget.focusTimerController ?? FocusTimerController();
    _focusTimerController.addListener(_handleFocusTimerChanged);
    unawaited(_focusTimerController.initialize());
    _ownsAppUpdateController = widget.appUpdateController == null;
    _appUpdateController = widget.appUpdateController ?? AppUpdateController();
    _ownsAppThemeModeController = widget.appThemeModeController == null;
    _appThemeModeController =
        widget.appThemeModeController ?? AppThemeModeController();
    _appThemeModeController.addListener(_handleThemeModeChanged);
    unawaited(_appThemeModeController.initialize());
    _deepLinkService = widget.deepLinkService ?? BilibiliDeepLinkService();
    _videoService = widget.videoService ?? BilibiliVideoInfoService();
    unawaited(_initializeDeepLinks());
    if (widget.checkForUpdatesOnStart) {
      unawaited(_initializeUpdateCheck());
    }
  }

  /// 主题控制器变化时重建 MaterialApp，让整套界面立即切换配色。
  void _handleThemeModeChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 注册运行期深链监听，并读取 Android 冷启动携带的一次性视频链接。
  Future<void> _initializeDeepLinks() async {
    _deepLinkService.setLinkHandler(_handleIncomingDeepLink);
    final String? initialLink = await _deepLinkService.takeInitialLink();
    if (mounted && initialLink != null) {
      _handleIncomingDeepLink(initialLink);
    }
  }

  /// 解析外部链接并保留最后一个有效视频目标，协议未同意前不会执行导航。
  void _handleIncomingDeepLink(String rawLink) {
    final BilibiliVideoDeepLinkTarget? target = BilibiliDeepLinkParser.parse(
      rawLink,
    );
    if (target == null) {
      if (_firstLaunchReady) {
        _showDeepLinkMessage('这条外部链接不是当前支持的 B站公开视频。');
      }
      return;
    }
    _pendingDeepLink = target;
    if (_firstLaunchReady) {
      unawaited(_openPendingDeepLink());
    }
  }

  /// 首次使用协议通过后开放外部导航，并继续处理冷启动时暂存的视频链接。
  void _handleFirstLaunchReady() {
    _firstLaunchReady = true;
    unawaited(_openPendingDeepLink());
  }

  /// 查询外部视频详情并打开播放器；网络失败时保留应用主页并显示明确提示。
  Future<void> _openPendingDeepLink() async {
    if (!_firstLaunchReady || _deepLinkOpening || _pendingDeepLink == null) {
      return;
    }
    final BilibiliVideoDeepLinkTarget target = _pendingDeepLink!;
    _pendingDeepLink = null;
    _deepLinkOpening = true;
    _showDeepLinkMessage('正在打开外部视频…');
    try {
      final video = await _videoService.lookupVideo(target.bvid);
      if (!mounted) {
        return;
      }
      final NavigatorState? navigator = _navigatorKey.currentState;
      if (navigator == null) {
        _pendingDeepLink = target;
        return;
      }
      final int? initialPartCid =
          target.partCid ?? _partCidForPage(video, target.partPageNumber);
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            // 深链播放器构建函数复用正常播放器，并传入分P与网页时间点。
            builder: (BuildContext context) => PlayerPage(
              video: video,
              initialPartCid: initialPartCid,
              initialPosition: target.initialPosition,
              initialPositionSource: PlayerInitialPositionSource.externalLink,
            ),
          ),
        ),
      );
    } on BilibiliLookupException catch (error) {
      if (mounted) {
        _showDeepLinkMessage(error.message);
      }
    } catch (_) {
      if (mounted) {
        _showDeepLinkMessage('暂时无法打开外部视频，请检查网络后重试。');
      }
    } finally {
      _deepLinkOpening = false;
      if (mounted && _pendingDeepLink != null) {
        unawaited(_openPendingDeepLink());
      }
    }
  }

  /// 根据外部链接的一起始分P序号查找详情中的真实 CID。
  int? _partCidForPage(VideoPreview video, int? pageNumber) {
    if (pageNumber == null) {
      return null;
    }
    for (final part in video.parts) {
      if (part.pageNumber == pageNumber) {
        return part.cid;
      }
    }
    return null;
  }

  /// 通过应用级 Snackbar 展示深链加载进度或失败原因。
  void _showDeepLinkMessage(String message) {
    _scaffoldMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// 每次真实应用启动按用户开关检查一次；新版本提示会优先带上第一条简短更新内容。
  Future<void> _initializeUpdateCheck() async {
    await _appUpdateController.initialize(checkOnStart: true);
    if (!mounted || !_appUpdateController.hasUpdate) {
      return;
    }
    final AppUpdateResult result = _appUpdateController.result;
    final String updateMessage = result.releaseHighlights.isEmpty
        ? '发现新版本 ${result.latestVersion}，可在“设置 - 关于”中查看。'
        : '发现新版本 ${result.latestVersion}：${result.releaseHighlights.first}';
    _scaffoldMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            updateMessage,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '查看',
            onPressed: () =>
                _navigatorKey.currentState?.pushNamed(AppRoutes.about),
          ),
        ),
      );
  }

  /// 监听正常完成记录，并在根导航器就绪后只显示一次庆祝弹窗。
  void _handleFocusTimerChanged() {
    final FocusSession? finished = _focusTimerController.lastFinishedSession;
    if (finished == null ||
        finished.status != FocusSessionStatus.completed ||
        finished.id == _handledCompletionId ||
        _completionDialogOpen) {
      return;
    }
    _handledCompletionId = finished.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showCompletionDialog(finished));
    });
  }

  /// 显示全局完成礼花；用户选择续时后重新打开同一条任务。
  Future<void> _showCompletionDialog(FocusSession session) async {
    final BuildContext? navigatorContext = _navigatorKey.currentContext;
    if (!mounted || navigatorContext == null || _completionDialogOpen) {
      return;
    }
    _completionDialogOpen = true;
    final Duration? extension = await showFocusCompletionDialog(
      navigatorContext,
      session,
    );
    _completionDialogOpen = false;
    if (extension != null) {
      await _focusTimerController.extendCompletedFocus(extension);
    }
  }

  /// 创建整套应用界面，并把页面导航交给统一路由处理。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: '焦点哔哩',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _appThemeModeController.mode,
      home: FirstLaunchGate(
        onReady: _handleFirstLaunchReady,
        child: const MainShell(),
      ),
      onGenerateRoute: AppRouter.onGenerateRoute,
      // 根据实际主题在整棵页面树外层设置系统栏图标颜色，覆盖无 AppBar 的页面。
      builder: (BuildContext context, Widget? child) {
        return AppThemeModeScope(
          controller: _appThemeModeController,
          child: AppUpdateScope(
            controller: _appUpdateController,
            child: FocusTimerScope(
              controller: _focusTimerController,
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: AppTheme.systemOverlayStyle(
                  Theme.of(context).brightness,
                ),
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 仅释放由应用自己创建的控制器，测试注入实例仍由测试负责回收。
  @override
  void dispose() {
    _focusTimerController.removeListener(_handleFocusTimerChanged);
    if (_ownsFocusTimerController) {
      _focusTimerController.dispose();
    }
    if (_ownsAppUpdateController) {
      _appUpdateController.dispose();
    }
    _appThemeModeController.removeListener(_handleThemeModeChanged);
    if (_ownsAppThemeModeController) {
      _appThemeModeController.dispose();
    }
    _deepLinkService.dispose();
    super.dispose();
  }
}
