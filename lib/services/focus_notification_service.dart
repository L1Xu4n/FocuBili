import 'dart:io';

import 'package:flutter/services.dart';

import 'windows_focus_notification_service.dart';

/// 汇总统一权限管理页需要的 Android 权限与后台运行状态。
class AndroidPermissionOverview {
  /// 创建一份不会包含设备标识符的权限状态快照。
  const AndroidPermissionOverview({
    required this.notificationAllowed,
    required this.exactAlarmAllowed,
    required this.doNotDisturbAllowed,
    required this.batteryOptimizationIgnored,
    required this.backgroundRestricted,
    required this.requiresAutostartGuide,
    required this.manufacturer,
    required this.apiLevel,
  });

  final bool notificationAllowed;
  final bool exactAlarmAllowed;
  final bool doNotDisturbAllowed;
  final bool batteryOptimizationIgnored;
  final bool backgroundRestricted;
  final bool requiresAutostartGuide;
  final String manufacturer;
  final int? apiLevel;

  /// 从 Android MethodChannel 字典读取状态，缺失字段统一使用保守默认值。
  factory AndroidPermissionOverview.fromPlatformMap(
    Map<Object?, Object?> values,
  ) {
    return AndroidPermissionOverview(
      notificationAllowed: values['notificationAllowed'] == true,
      exactAlarmAllowed: values['exactAlarmAllowed'] == true,
      doNotDisturbAllowed: values['doNotDisturbAllowed'] == true,
      batteryOptimizationIgnored: values['batteryOptimizationIgnored'] == true,
      backgroundRestricted: values['backgroundRestricted'] == true,
      requiresAutostartGuide: values['requiresAutostartGuide'] == true,
      manufacturer: (values['manufacturer'] as String? ?? '').trim(),
      apiLevel: (values['apiLevel'] as num?)?.toInt(),
    );
  }

  /// 创建原生通道不可用时使用的安全状态，页面仍可显示用途说明和系统入口。
  factory AndroidPermissionOverview.unavailable() {
    return const AndroidPermissionOverview(
      notificationAllowed: false,
      exactAlarmAllowed: false,
      doNotDisturbAllowed: false,
      batteryOptimizationIgnored: false,
      backgroundRestricted: false,
      requiresAutostartGuide: false,
      manufacturer: '',
      apiLevel: null,
    );
  }
}

/// 通过 Android 原生方法通道管理提醒通知、权限和系统设置入口。
class FocusNotificationService {
  /// 创建通知服务；测试可注入自定义方法通道。
  const FocusNotificationService({
    MethodChannel? channel,
    WindowsFocusNotificationBackend? windowsBackend,
  }) : _usesDefaultChannel = channel == null,
       _windowsBackend = windowsBackend,
       _channel =
           channel ??
           const MethodChannel('com.focubili.app/focus_notifications');

  final MethodChannel _channel;
  final bool _usesDefaultChannel;
  final WindowsFocusNotificationBackend? _windowsBackend;

  /// 判断本次服务是否应使用 Windows Toast，而不是 Android 方法通道。
  bool get _usesWindowsBackend =>
      _windowsBackend != null || (_usesDefaultChannel && Platform.isWindows);

  /// 返回注入的测试后端或进程内共享的生产 Windows 通知后端。
  WindowsFocusNotificationBackend get _resolvedWindowsBackend =>
      _windowsBackend ?? WindowsFocusNotificationBackend.instance;

  /// 供界面判断是否应展示 Windows 系统能力，而不是 Android 权限文案。
  bool get usesWindowsBackend => _usesWindowsBackend;

  /// 返回 Windows 是否已通过 MSIX 安装并获得完整通知查询与取消能力。
  bool get hasWindowsPackageIdentity =>
      _usesWindowsBackend && _resolvedWindowsBackend.hasPackageIdentity;

  /// Flutter 组件测试没有 Android 消息接收端，默认通道应直接使用安全返回值。
  bool get _skipDefaultChannelInFlutterTest =>
      _usesDefaultChannel &&
      _windowsBackend == null &&
      Platform.environment['FLUTTER_TEST'] == 'true';

  /// 检查当前平台是否已经允许应用发送通知。
  Future<bool> hasPermission() async {
    if (_skipDefaultChannelInFlutterTest) {
      return false;
    }
    if (_usesWindowsBackend) {
      return _resolvedWindowsBackend.isAvailable();
    }
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 请求 Android 13 及以上通知权限，旧系统直接返回可用状态。
  Future<bool> requestPermission() async {
    if (_skipDefaultChannelInFlutterTest) {
      return false;
    }
    if (_usesWindowsBackend) {
      return _resolvedWindowsBackend.isAvailable();
    }
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 检查 Android 12 及以上是否允许应用安排可在待机和进程退出后准点触发的精确闹钟。
  Future<bool> hasExactAlarmPermission() async {
    if (_skipDefaultChannelInFlutterTest) {
      return false;
    }
    if (_usesWindowsBackend) {
      return _resolvedWindowsBackend.isAvailable();
    }
    try {
      return await _channel.invokeMethod<bool>('hasExactAlarmPermission') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开 Android 的“闹钟和提醒”特殊访问页面，让用户亲自授予精确闹钟权限。
  Future<void> openExactAlarmSettings() async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    if (_usesWindowsBackend) {
      await _resolvedWindowsBackend.openSettings();
      return;
    }
    try {
      await _channel.invokeMethod<void>('openExactAlarmSettings');
    } on PlatformException {
      // 个别系统没有独立权限页面时，原生层已经尝试回退应用详情，此处保持流程可退出。
    } on MissingPluginException {
      // 非 Android 或测试环境没有原生实现时安全忽略。
    }
  }

  /// 检查 Android 是否允许应用在专注期间切换系统勿扰模式。
  Future<bool> hasDoNotDisturbAccess() async {
    if (_skipDefaultChannelInFlutterTest) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('hasDoNotDisturbAccess') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开 Android 勿扰模式特殊访问设置；用户必须亲自在系统页面授权。
  Future<void> openDoNotDisturbSettings() async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openDoNotDisturbSettings');
    } on PlatformException {
      // 系统没有对应设置页时保持当前应用可用，不中断已经创建的专注任务。
    } on MissingPluginException {
      // 非 Android 或测试环境没有原生实现时安全忽略。
    }
  }

  /// 开启专注勿扰或恢复进入专注前的系统模式，并返回原生层是否成功执行。
  Future<bool> setFocusDoNotDisturb(bool enabled) async {
    if (_skipDefaultChannelInFlutterTest) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'setFocusDoNotDisturb',
            <String, Object?>{'enabled': enabled},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 一次读取通知、精确闹钟、勿扰、电量与厂商后台自启动状态。
  Future<AndroidPermissionOverview> getPermissionOverview() async {
    if (_skipDefaultChannelInFlutterTest) {
      return AndroidPermissionOverview.unavailable();
    }
    if (_usesWindowsBackend) {
      return AndroidPermissionOverview.unavailable();
    }
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        'getPermissionOverview',
      );
      if (result is Map) {
        return AndroidPermissionOverview.fromPlatformMap(
          Map<Object?, Object?>.from(result),
        );
      }
    } on PlatformException {
      // 厂商系统拒绝读取后台状态时回退为保守状态。
    } on MissingPluginException {
      // 非 Android 平台没有原生权限通道时回退为保守状态。
    }
    return AndroidPermissionOverview.unavailable();
  }

  /// 打开小米后台自启动管理；其他系统会回退到当前应用详情页面。
  Future<void> openBackgroundAutostartSettings() async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openBackgroundAutostartSettings');
    } on PlatformException {
      // 厂商移除直达入口时不让权限页崩溃。
    } on MissingPluginException {
      // 非 Android 平台没有对应系统设置入口时安全忽略。
    }
  }

  /// 打开当前应用详情和电量管理入口，让用户自行选择无限制后台运行或取消。
  Future<void> openBatterySettings() async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } on PlatformException {
      // 系统设置入口不可用时保持当前页面可操作。
    } on MissingPluginException {
      // 非 Android 平台没有对应系统设置入口时安全忽略。
    }
  }

  /// 读取原生闹钟安排、恢复和触发事件，结果只包含脱敏状态字段。
  Future<Map<Object?, Object?>> getReminderDiagnostics() async {
    if (_skipDefaultChannelInFlutterTest) {
      return const <Object?, Object?>{};
    }
    if (_usesWindowsBackend) {
      return _resolvedWindowsBackend.getDiagnostics();
    }
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        'getReminderDiagnostics',
      );
      return result is Map
          ? Map<Object?, Object?>.from(result)
          : const <Object?, Object?>{};
    } on PlatformException {
      return const <Object?, Object?>{};
    } on MissingPluginException {
      return const <Object?, Object?>{};
    }
  }

  /// 清除原生闹钟诊断历史，但保留仍待触发的真实提醒。
  Future<void> clearReminderDiagnostics() async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    if (_usesWindowsBackend) {
      await _resolvedWindowsBackend.clearDiagnostics();
      return;
    }
    try {
      await _channel.invokeMethod<void>('clearReminderDiagnostics');
    } on PlatformException {
      // 清理失败不能影响现有闹钟或其他诊断记录。
    } on MissingPluginException {
      // 非 Android 平台没有原生记录时无需处理。
    }
  }

  /// 打开当前应用的系统通知设置页，方便用户手动恢复权限。
  Future<void> openSettings() async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    if (_usesWindowsBackend) {
      await _resolvedWindowsBackend.openSettings();
      return;
    }
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on PlatformException {
      // 系统设置不可用时保持当前页面，不让提醒设置导致应用崩溃。
    } on MissingPluginException {
      // 非 Android 或测试环境没有原生实现时安全忽略。
    }
  }

  /// 播放一次短促上扬的完成音效；不支持原生通道的平台会安静跳过。
  Future<void> playCelebrationSound() async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    if (_usesWindowsBackend) {
      // Windows 专注完成 Toast 已播放系统提示音，避免庆祝弹窗再次发出重复声音。
      return;
    }
    try {
      await _channel.invokeMethod<void>('playCelebrationSound');
    } on PlatformException {
      // 音效不可用不能影响完成记录和庆祝弹窗。
    } on MissingPluginException {
      // 非 Android 或测试环境没有音效实现时安全忽略。
    }
  }

  /// 安排一次专注继续提醒；Android 可能为省电稍微延后送达。
  Future<bool> scheduleReminder({
    required String sessionId,
    required String goal,
    required String reason,
    required DateTime reminderAt,
  }) async {
    if (_skipDefaultChannelInFlutterTest) {
      return false;
    }
    if (_usesWindowsBackend) {
      return _resolvedWindowsBackend.scheduleReminder(
        sessionId: sessionId,
        goal: goal,
        reason: reason,
        reminderAt: reminderAt,
      );
    }
    try {
      return await _channel
              .invokeMethod<bool>('scheduleReminder', <String, Object?>{
                'sessionId': sessionId,
                'goal': goal,
                'reason': reason,
                'triggerAtMs': reminderAt.millisecondsSinceEpoch,
              }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 取消指定专注任务尚未触发的继续提醒。
  Future<void> cancelReminder(String sessionId) async {
    if (_skipDefaultChannelInFlutterTest) {
      return;
    }
    if (_usesWindowsBackend) {
      await _resolvedWindowsBackend.cancelReminder(sessionId);
      return;
    }
    try {
      await _channel.invokeMethod<void>('cancelReminder', <String, Object?>{
        'sessionId': sessionId,
      });
    } on PlatformException {
      // 已触发或不存在的提醒无需再向用户报告错误。
    } on MissingPluginException {
      // 非 Android 或测试环境没有原生实现时安全忽略。
    }
  }

  /// 在 Windows 显示专注完成 Toast；Android 继续使用现有弹窗、震动和原生完成音效。
  Future<void> showFocusCompleted({
    required String sessionId,
    required String goal,
    required int focusedMinutes,
  }) async {
    if (_skipDefaultChannelInFlutterTest || !_usesWindowsBackend) {
      return;
    }
    await _resolvedWindowsBackend.showFocusCompleted(
      sessionId: sessionId,
      goal: goal,
      focusedMinutes: focusedMinutes,
    );
  }
}
