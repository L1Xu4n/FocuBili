import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// 抽象 Windows Toast 插件调用，测试可记录请求而不弹出真实系统通知。
abstract interface class WindowsNotificationClient {
  /// 返回当前进程是否具有 MSIX 包身份，以判断系统是否支持完整通知取消能力。
  bool get hasPackageIdentity;

  /// 初始化固定应用名称、AUMID 和 GUID 的 Windows 通知提供程序。
  Future<bool> initialize();

  /// 立即显示一条 Windows Toast。
  Future<void> show({
    required int id,
    required String title,
    required String body,
  });

  /// 在指定绝对时间安排一条 Windows Toast。
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  });

  /// 取消指定稳定编号的待触发或已显示通知。
  Future<void> cancel(int id);

  /// 打开 Windows 通知系统设置页面。
  Future<void> openSettings();
}

/// 使用 flutter_local_notifications 连接 Windows 原生 Toast 平台。
class FlutterWindowsNotificationClient implements WindowsNotificationClient {
  /// 创建生产通知客户端；测试也可传入插件实例验证初始化参数以外的逻辑。
  FlutterWindowsNotificationClient({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const WindowsInitializationSettings _initializationSettings =
      WindowsInitializationSettings(
        appName: '焦点哔哩',
        appUserModelId: 'com.focubili.app',
        guid: '6c1d7306-919c-45c9-bb1d-3dad171a43ef',
      );
  final FlutterLocalNotificationsPlugin _plugin;

  /// 通过 Windows 包 API 判断当前是普通 exe 还是已安装的 MSIX 应用。
  @override
  bool get hasPackageIdentity => MsixUtils.hasPackageIdentity();

  /// 注册 Windows 通知身份；当前不处理点击深链，点击通知仍会由系统激活应用。
  @override
  Future<bool> initialize() async {
    return await _plugin.initialize(
          settings: const InitializationSettings(
            windows: _initializationSettings,
          ),
        ) ??
        false;
  }

  /// 显示带默认提示音和较长停留时间的专注完成通知。
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) {
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        windows: WindowsNotificationDetails(
          duration: WindowsNotificationDuration.long,
          audio: WindowsNotificationAudio.preset(
            sound: WindowsNotificationSound.defaultSound,
          ),
        ),
      ),
    );
  }

  /// 使用 UTC 绝对时间安排一次性 Windows 提醒，避免本地时区名称映射差异改变触发时刻。
  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
  }) {
    return _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(scheduledAt.toUtc(), tz.UTC),
      notificationDetails: NotificationDetails(
        windows: WindowsNotificationDetails(
          duration: WindowsNotificationDuration.long,
          audio: WindowsNotificationAudio.preset(
            sound: WindowsNotificationSound.reminder,
          ),
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// 取消稳定编号通知；未安装为 MSIX 时 Windows 可能忽略此系统操作。
  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  /// 使用固定系统 URI 打开 Windows 通知设置，不拼接用户输入或执行脚本。
  @override
  Future<void> openSettings() async {
    await Process.start('explorer.exe', <String>['ms-settings:notifications']);
  }
}

/// 管理 Windows 专注完成 Toast、未来继续提醒、取消和脱敏诊断状态。
class WindowsFocusNotificationBackend {
  /// 创建 Windows 通知后端；生产环境使用真实 Toast 客户端。
  WindowsFocusNotificationBackend({WindowsNotificationClient? client})
    : _client = client ?? FlutterWindowsNotificationClient();

  static final WindowsFocusNotificationBackend instance =
      WindowsFocusNotificationBackend();
  static const int _maximumTextCodePoints = 80;
  static const int _maximumDiagnosticEvents = 20;

  final WindowsNotificationClient _client;
  Future<bool>? _initialization;
  final Map<String, DateTime> _pendingReminders = <String, DateTime>{};
  final List<Map<String, Object?>> _diagnosticEvents = <Map<String, Object?>>[];
  int _lastScheduledAtMilliseconds = 0;

  /// 返回当前 Windows 进程是否具有完整通知查询与取消所需的 MSIX 包身份。
  bool get hasPackageIdentity => _client.hasPackageIdentity;

  /// 初始化并返回当前 Toast 提供程序是否可用，重复调用共享同一个初始化任务。
  Future<bool> isAvailable() {
    return _initialization ??= _initializeSafely();
  }

  /// 显示专注完成 Toast；失败仅影响系统提示，不影响已保存的专注记录。
  Future<void> showFocusCompleted({
    required String sessionId,
    required String goal,
    required int focusedMinutes,
  }) async {
    if (!await isAvailable()) {
      return;
    }
    try {
      await _client.show(
        id: _stableNotificationId('completed:$sessionId'),
        title: '专注已完成，做得好！',
        body:
            '“${_limitText(goal, fallback: '本次任务')}”已专注 '
            '${focusedMinutes.clamp(1, 180)} 分钟。',
      );
    } catch (_) {
      // Toast 暂时不可用时保持安静，专注历史已经由控制器独立保存。
    }
  }

  /// 安排一次未来提醒，并只在内存诊断中记录时间、结果和模式，不保存目标或原因。
  Future<bool> scheduleReminder({
    required String sessionId,
    required String goal,
    required String reason,
    required DateTime reminderAt,
  }) async {
    if (sessionId.trim().isEmpty || !reminderAt.isAfter(DateTime.now())) {
      _recordEvent(type: 'schedule', result: 'invalid_request');
      return false;
    }
    if (!await isAvailable()) {
      _recordEvent(type: 'schedule', result: 'system_rejected');
      return false;
    }
    try {
      await _client.schedule(
        id: _stableNotificationId('reminder:$sessionId'),
        title: '该继续专注了',
        body:
            '${_limitText(goal, fallback: '上次任务')} · '
            '上次暂停：${_limitText(reason, fallback: '未填写原因')}',
        scheduledAt: reminderAt,
      );
      _pendingReminders[sessionId] = reminderAt;
      _lastScheduledAtMilliseconds = DateTime.now().millisecondsSinceEpoch;
      _recordEvent(
        type: 'schedule',
        result: 'scheduled',
        mode: 'windows_toast',
      );
      return true;
    } catch (_) {
      _recordEvent(type: 'schedule', result: 'system_rejected');
      return false;
    }
  }

  /// 使用跨进程稳定编号取消指定任务提醒，并从当前进程的待触发诊断中移除。
  Future<void> cancelReminder(String sessionId) async {
    final String normalizedId = sessionId.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    _pendingReminders.remove(normalizedId);
    if (!await isAvailable()) {
      return;
    }
    try {
      await _client.cancel(_stableNotificationId('reminder:$normalizedId'));
      _recordEvent(type: 'cancel', result: 'cancelled');
    } catch (_) {
      // 普通 exe 没有 MSIX 包身份时系统可能拒绝取消，业务状态仍可继续使用。
    }
  }

  /// 打开 Windows 系统通知设置，失败时保持应用当前页面可操作。
  Future<void> openSettings() async {
    try {
      await _client.openSettings();
    } catch (_) {
      // 系统设置 URI 被策略禁用时无需让设置页崩溃。
    }
  }

  /// 返回与现有诊断模型兼容的 Windows 提醒快照，不包含任务内容和会话编号。
  Future<Map<Object?, Object?>> getDiagnostics() async {
    final DateTime now = DateTime.now();
    _pendingReminders.removeWhere(
      (String _, DateTime triggerAt) => !triggerAt.isAfter(now),
    );
    return <Object?, Object?>{
      'pendingCount': _pendingReminders.length,
      'lastScheduledAtMs': _lastScheduledAtMilliseconds,
      'lastTriggeredAtMs': 0,
      'lastRestoredAtMs': 0,
      'lastTriggerResult': 'windows_system_managed',
      'lastScheduleMode': 'windows_toast',
      'exactAlarmAllowed': await isAvailable(),
      'notificationsEnabled': await isAvailable(),
      'batteryOptimizationIgnored': true,
      'backgroundRestricted': false,
      'manufacturer': 'Microsoft Windows',
      'events': List<Map<String, Object?>>.unmodifiable(_diagnosticEvents),
    };
  }

  /// 清除 Windows 诊断事件与时间戳，但保留仍由系统等待触发的真实提醒。
  Future<void> clearDiagnostics() async {
    _diagnosticEvents.clear();
    _lastScheduledAtMilliseconds = 0;
  }

  /// 捕获插件初始化异常并转换为布尔结果，禁止异常正文进入用户界面。
  Future<bool> _initializeSafely() async {
    try {
      return await _client.initialize();
    } catch (_) {
      return false;
    }
  }

  /// 使用 FNV-1a 生成跨启动稳定的正整数通知编号，避免 Dart hashCode 随进程变化。
  int _stableNotificationId(String value) {
    int hash = 0x811C9DC5;
    for (final int codePoint in value.runes) {
      hash ^= codePoint;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return hash == 0 ? 1 : hash;
  }

  /// 去除换行并按 Unicode 码点裁剪通知文字，空值使用不敏感的明确回退文案。
  String _limitText(String value, {required String fallback}) {
    final String normalized = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    final String safeValue = normalized.isEmpty ? fallback : normalized;
    return String.fromCharCodes(safeValue.runes.take(_maximumTextCodePoints));
  }

  /// 追加一条不含任务资料的诊断事件，并限制总数避免进程内列表无限增长。
  void _recordEvent({
    required String type,
    required String result,
    String mode = '',
  }) {
    _diagnosticEvents.insert(0, <String, Object?>{
      'timeMs': DateTime.now().millisecondsSinceEpoch,
      'type': type,
      'result': result,
      'mode': mode,
    });
    if (_diagnosticEvents.length > _maximumDiagnosticEvents) {
      _diagnosticEvents.removeRange(
        _maximumDiagnosticEvents,
        _diagnosticEvents.length,
      );
    }
  }
}
