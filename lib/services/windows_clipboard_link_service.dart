import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/app_platform.dart';

/// 定义 Windows 剪贴板链接检测开关所需的可替换偏好读取器。
typedef WindowsClipboardPreferencesLoader =
    Future<SharedPreferences> Function();

/// 定义剪贴板纯文本读取函数，测试可替换系统 Clipboard 调用。
typedef ClipboardTextReader = Future<String?> Function();

/// 保存 Windows 是否允许焦点哔哩检查剪贴板中的 B站链接。
class WindowsClipboardLinkPreferencesService {
  /// 创建偏好服务；测试可以注入内存中的 SharedPreferences。
  WindowsClipboardLinkPreferencesService({
    WindowsClipboardPreferencesLoader? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const String _enabledKey = 'windows_clipboard_link_detection.enabled';
  final WindowsClipboardPreferencesLoader _preferencesLoader;

  /// 读取用户开关；旧版本没有记录时默认关闭，避免未经选择读取剪贴板。
  Future<bool> loadEnabled() async {
    final SharedPreferences preferences = await _preferencesLoader();
    return preferences.getBool(_enabledKey) ?? false;
  }

  /// 保存用户是否允许在 Windows 前台检测剪贴板链接。
  Future<bool> saveEnabled(bool enabled) async {
    final SharedPreferences preferences = await _preferencesLoader();
    return preferences.setBool(_enabledKey, enabled);
  }
}

/// 定义应用根组件需要的剪贴板监听能力，便于组件测试注入假事件源。
abstract interface class ClipboardLinkMonitor {
  /// 开始监听新的非空剪贴板文本，同一内容在变化前只报告一次。
  void start(ValueChanged<String> onTextChanged);

  /// 更新 App 是否在前台；后台时不得读取或报告剪贴板内容。
  void setForeground(bool foreground);

  /// 停止定时器并释放页面回调。
  void dispose();
}

/// 使用 Flutter 系统剪贴板 API 检查 Windows 或 Android 前台的新文本。
class WindowsClipboardLinkMonitor implements ClipboardLinkMonitor {
  /// 创建监听器；Windows 定时检查，Android 仅在进入前台时读取一次。
  WindowsClipboardLinkMonitor({
    WindowsClipboardLinkPreferencesService? preferencesService,
    AppPlatform? platform,
    Duration interval = const Duration(seconds: 1),
    ClipboardTextReader? clipboardTextReader,
    bool allowInFlutterTest = false,
  }) : _preferencesService =
           preferencesService ?? WindowsClipboardLinkPreferencesService(),
       _platform = platform ?? AppPlatformDetector.current,
       _interval = interval,
       _clipboardTextReader = clipboardTextReader ?? _readClipboardText,
       _allowInFlutterTest = allowInFlutterTest;

  final WindowsClipboardLinkPreferencesService _preferencesService;
  final AppPlatform _platform;
  final Duration _interval;
  final ClipboardTextReader _clipboardTextReader;
  final bool _allowInFlutterTest;
  Timer? _timer;
  ValueChanged<String>? _handler;
  bool _foreground = true;
  bool _reading = false;
  int _foregroundGeneration = 0;
  String? _lastObservedText;

  /// 启动平台适配监听；Android 不持续轮询，避免反复触发系统剪贴板访问提示。
  @override
  void start(ValueChanged<String> onTextChanged) {
    _handler = onTextChanged;
    if ((_platform != AppPlatform.windows &&
            _platform != AppPlatform.android) ||
        (AppPlatformDetector.isFlutterTest && !_allowInFlutterTest) ||
        _timer != null) {
      return;
    }
    unawaited(_checkClipboard());
    if (_platform == AppPlatform.windows) {
      _timer = Timer.periodic(_interval, (_) => unawaited(_checkClipboard()));
    }
  }

  /// 记录前后台状态；回到前台时立即检查一次用户刚复制的内容。
  @override
  void setForeground(bool foreground) {
    if (_foreground != foreground) {
      _foregroundGeneration += 1;
    }
    _foreground = foreground;
    if (foreground) {
      unawaited(_checkClipboard());
    }
  }

  /// 在开关开启且没有并发读取时读取一次纯文本，并对相同内容去重。
  Future<void> _checkClipboard() async {
    if (!_foreground || _reading || _handler == null) {
      return;
    }
    final int foregroundGeneration = _foregroundGeneration;
    _reading = true;
    try {
      if (!await _preferencesService.loadEnabled()) {
        return;
      }
      if (!_foreground || foregroundGeneration != _foregroundGeneration) {
        return;
      }
      final String text = (await _clipboardTextReader())?.trim() ?? '';
      if (!_foreground ||
          foregroundGeneration != _foregroundGeneration ||
          text.isEmpty ||
          text == _lastObservedText) {
        return;
      }
      _lastObservedText = text;
      _handler?.call(text);
    } catch (_) {
      // 系统暂时拒绝剪贴板读取时等待下一次前台轮询，不影响其他功能。
    } finally {
      _reading = false;
    }
  }

  /// 取消轮询并清理回调，避免根组件销毁后继续读取剪贴板。
  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _handler = null;
  }

  /// 通过 Flutter 系统通道读取当前剪贴板纯文本。
  static Future<String?> _readClipboardText() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }
}
