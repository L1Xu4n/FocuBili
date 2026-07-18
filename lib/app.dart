import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/focus/focus_timer_controller.dart';
import 'features/focus/focus_timer_scope.dart';
import 'features/focus/focus_completion_dialog.dart';
import 'features/onboarding/first_launch_gate.dart';
import 'features/shell/main_shell.dart';
import 'models/focus_session.dart';
import 'services/app_update_service.dart';

/// 焦点哔哩的根组件，统一配置主题、路由和调试标记。
class FocuBiliApp extends StatefulWidget {
  /// 创建应用根组件；测试可以传入可控时钟的专注控制器。
  const FocuBiliApp({
    super.key,
    this.focusTimerController,
    this.appUpdateController,
    this.checkForUpdatesOnStart = false,
  });

  final FocusTimerController? focusTimerController;
  final AppUpdateController? appUpdateController;
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
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  String? _handledCompletionId;
  bool _completionDialogOpen = false;

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
    if (widget.checkForUpdatesOnStart) {
      unawaited(_initializeUpdateCheck());
    }
  }

  /// 每次真实应用启动按用户开关检查一次；新版本只显示一条短暂底部提示。
  Future<void> _initializeUpdateCheck() async {
    await _appUpdateController.initialize(checkOnStart: true);
    if (!mounted || !_appUpdateController.hasUpdate) {
      return;
    }
    _scaffoldMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '发现新版本 ${_appUpdateController.result.latestVersion}，可在“设置 - 关于”中查看。',
          ),
          duration: const Duration(seconds: 4),
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
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const FirstLaunchGate(child: MainShell()),
      onGenerateRoute: AppRouter.onGenerateRoute,
      // 根据实际主题在整棵页面树外层设置系统栏图标颜色，覆盖无 AppBar 的页面。
      builder: (BuildContext context, Widget? child) {
        return AppUpdateScope(
          controller: _appUpdateController,
          child: FocusTimerScope(
            controller: _focusTimerController,
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: AppTheme.systemOverlayStyle(Theme.of(context).brightness),
              child: child ?? const SizedBox.shrink(),
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
    super.dispose();
  }
}
