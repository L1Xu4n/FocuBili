import 'package:flutter/material.dart';

import '../../services/app_theme_mode_service.dart';

/// 管理全应用外观模式，并在切换后通知根组件立即换色。
class AppThemeModeController extends ChangeNotifier {
  /// 创建主题控制器；测试可注入只使用内存的主题存储服务。
  AppThemeModeController({AppThemeModeService? service})
    : _service = service ?? const AppThemeModeService();

  final AppThemeModeService _service;
  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;
  bool _saving = false;
  bool _disposed = false;
  Future<void>? _loadingFuture;

  /// 返回当前实际选择，首次读取前也默认跟随系统。
  ThemeMode get mode => _mode;

  /// 返回本地偏好是否已经读取完毕。
  bool get loaded => _loaded;

  /// 返回当前是否正在把新选择写入设备。
  bool get saving => _saving;

  /// 只执行一次本地读取；多个页面同时请求时共用同一个异步任务。
  Future<void> initialize() async {
    if (_loaded) {
      return;
    }
    _loadingFuture ??= _loadInitialMode();
    await _loadingFuture;
    _loadingFuture = null;
  }

  /// 立即应用用户选择并持久化；保存失败时恢复旧主题并返回 false。
  Future<bool> setMode(ThemeMode mode) async {
    if (!_loaded) {
      await initialize();
    }
    if (_saving || mode == _mode) {
      return !_saving;
    }
    final ThemeMode previous = _mode;
    _mode = mode;
    _saving = true;
    _notify();
    try {
      await _service.save(mode);
      return true;
    } on Object {
      _mode = previous;
      return false;
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// 从设备恢复主题；读取异常时继续使用默认“跟随系统”，保证应用可启动。
  Future<void> _loadInitialMode() async {
    try {
      _mode = await _service.load();
    } on Object {
      _mode = ThemeMode.system;
    }
    _loaded = true;
    _notify();
  }

  /// 控制器未释放时才通知界面，避免异步读取完成后访问失效对象。
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// 标记控制器已释放，并停止后续异步任务刷新界面。
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 把全应用唯一的主题控制器提供给设置页及其后续子页面。
class AppThemeModeScope extends InheritedNotifier<AppThemeModeController> {
  /// 创建主题作用域，让依赖页面在主题选择变化时自动重建。
  const AppThemeModeScope({
    super.key,
    required AppThemeModeController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 尝试读取主题控制器；独立组件测试缺少作用域时返回 null。
  static AppThemeModeController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AppThemeModeScope>()
        ?.notifier;
  }

  /// 读取必需的主题控制器，缺少根作用域时在开发模式给出明确提示。
  static AppThemeModeController of(BuildContext context) {
    final AppThemeModeController? controller = maybeOf(context);
    assert(controller != null, 'No AppThemeModeScope found in context.');
    return controller!;
  }
}
