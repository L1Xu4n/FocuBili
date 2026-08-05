import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'focus_notification_service.dart';

/// 定义读取问题诊断本机存储的可替换入口，便于单元测试使用内存偏好设置。
typedef ProblemDiagnosticsPreferencesLoader =
    Future<SharedPreferences> Function();

/// 定义读取应用版本的可替换入口，便于测试固定版本文本。
typedef ProblemDiagnosticsAppVersionLoader = Future<String> Function();

/// 定义读取 Android 系统和设备型号的可替换入口，便于测试不依赖原生通道。
typedef ProblemDiagnosticsDeviceInfoLoader =
    Future<DiagnosticDeviceInfo> Function();

/// 定义读取原生提醒诊断状态的可替换入口，测试可以固定闹钟事件。
typedef ReminderDiagnosticsLoader =
    Future<ReminderDiagnosticsSnapshot> Function();

/// 定义清除原生提醒诊断事件的可替换入口，测试不会触碰真实闹钟。
typedef ReminderDiagnosticsClearer = Future<void> Function();

/// 保存与问题定位相关但不含标识符、Cookie 或完整请求地址的 Android 环境信息。
class DiagnosticDeviceInfo {
  /// 创建一份已脱敏的 Android 版本、API 和设备型号信息。
  const DiagnosticDeviceInfo({
    required this.androidRelease,
    required this.apiLevel,
    required this.model,
  });

  /// Android 的公开系统版本号，例如“15”。
  final String androidRelease;

  /// Android 的公开 API 级别；通道不可用时为空。
  final int? apiLevel;

  /// 设备厂商和型号；不读取序列号、Android ID、MAC 地址或广告标识符。
  final String model;

  /// 从 Android 方法通道返回的字典中读取并校验环境信息。
  factory DiagnosticDeviceInfo.fromPlatformMap(Map<Object?, Object?> values) {
    final String release = (values['androidRelease'] as String? ?? '').trim();
    final int? apiLevel = (values['apiLevel'] as num?)?.toInt();
    final String model = (values['model'] as String? ?? '').trim();
    return DiagnosticDeviceInfo(
      androidRelease: release.isEmpty ? '未知' : release,
      apiLevel: apiLevel != null && apiLevel > 0 ? apiLevel : null,
      model: model.isEmpty ? '未知设备' : model,
    );
  }

  /// 返回适合页面和复制文本展示的 Android 版本字符串。
  String get androidLabel {
    final String apiLabel = apiLevel == null ? 'API 未知' : 'API $apiLevel';
    return '$androidRelease / $apiLabel';
  }
}

/// 保存一次不含任务正文和会话编号的闹钟安排、恢复或触发事件。
class ReminderDiagnosticEvent {
  /// 创建一条只包含时间、固定类型、结果和调度模式的提醒事件。
  const ReminderDiagnosticEvent({
    required this.occurredAt,
    required this.type,
    required this.result,
    required this.mode,
  });

  final DateTime occurredAt;
  final String type;
  final String result;
  final String mode;

  /// 从 Android 原生字典读取一条事件；缺失时间或固定字段时返回空。
  static ReminderDiagnosticEvent? tryParse(Map<Object?, Object?> values) {
    final int timeMs = (values['timeMs'] as num?)?.toInt() ?? 0;
    final String type = (values['type'] as String? ?? '').trim();
    final String result = (values['result'] as String? ?? '').trim();
    final String mode = (values['mode'] as String? ?? '').trim();
    if (timeMs <= 0 || type.isEmpty || result.isEmpty) {
      return null;
    }
    return ReminderDiagnosticEvent(
      occurredAt: DateTime.fromMillisecondsSinceEpoch(timeMs),
      type: type,
      result: result,
      mode: mode,
    );
  }

  /// 返回问题诊断页面使用的中文事件类型。
  String get typeLabel => switch (type) {
    'schedule' => '安排闹钟',
    'trigger' => '触发提醒',
    'restore' => '恢复闹钟',
    'cancel' => '取消闹钟',
    _ => type,
  };

  /// 返回常见原生结果的中文说明，未知结果保留原文用于定位。
  String get resultLabel => switch (result) {
    'scheduled' => '已进入系统闹钟队列',
    'notification_posted' => '通知已提交给系统',
    'notification_permission_denied' => '通知运行时权限被拒绝',
    'notifications_disabled' => '应用通知总开关已关闭',
    'cancelled' => '已取消',
    'nothing_pending' => '没有待恢复提醒',
    'invalid_request' => '提醒参数或时间无效',
    'system_rejected' => '系统拒绝安排闹钟',
    'storage_failed' => '待提醒记录保存失败',
    _ when result.startsWith('restored_') =>
      '已恢复 ${result.substring('restored_'.length)} 条提醒',
    _ => result,
  };
}

/// 汇总 Android 闹钟队列、权限限制和最近原生触发事件。
class ReminderDiagnosticsSnapshot {
  /// 创建一份可安全展示和复制的提醒诊断快照。
  const ReminderDiagnosticsSnapshot({
    required this.pendingCount,
    required this.lastScheduledAt,
    required this.lastTriggeredAt,
    required this.lastRestoredAt,
    required this.lastTriggerResult,
    required this.lastScheduleMode,
    required this.exactAlarmAllowed,
    required this.notificationsEnabled,
    required this.batteryOptimizationIgnored,
    required this.backgroundRestricted,
    required this.manufacturer,
    required this.events,
  });

  final int pendingCount;
  final DateTime? lastScheduledAt;
  final DateTime? lastTriggeredAt;
  final DateTime? lastRestoredAt;
  final String lastTriggerResult;
  final String lastScheduleMode;
  final bool exactAlarmAllowed;
  final bool notificationsEnabled;
  final bool batteryOptimizationIgnored;
  final bool backgroundRestricted;
  final String manufacturer;
  final List<ReminderDiagnosticEvent> events;

  /// 从 Android MethodChannel 字典读取提醒诊断，忽略损坏的单条事件。
  factory ReminderDiagnosticsSnapshot.fromPlatformMap(
    Map<Object?, Object?> values,
  ) {
    final List<ReminderDiagnosticEvent> events = <ReminderDiagnosticEvent>[];
    final Object? rawEvents = values['events'];
    if (rawEvents is List) {
      for (final Object? rawEvent in rawEvents) {
        if (rawEvent is! Map) continue;
        final ReminderDiagnosticEvent? event = ReminderDiagnosticEvent.tryParse(
          Map<Object?, Object?>.from(rawEvent),
        );
        if (event != null) {
          events.add(event);
        }
      }
    }
    return ReminderDiagnosticsSnapshot(
      pendingCount: ((values['pendingCount'] as num?)?.toInt() ?? 0)
          .clamp(0, 1000)
          .toInt(),
      lastScheduledAt: _dateTimeFromMilliseconds(values['lastScheduledAtMs']),
      lastTriggeredAt: _dateTimeFromMilliseconds(values['lastTriggeredAtMs']),
      lastRestoredAt: _dateTimeFromMilliseconds(values['lastRestoredAtMs']),
      lastTriggerResult: (values['lastTriggerResult'] as String? ?? 'never')
          .trim(),
      lastScheduleMode: (values['lastScheduleMode'] as String? ?? 'never')
          .trim(),
      exactAlarmAllowed: values['exactAlarmAllowed'] == true,
      notificationsEnabled: values['notificationsEnabled'] == true,
      batteryOptimizationIgnored: values['batteryOptimizationIgnored'] == true,
      backgroundRestricted: values['backgroundRestricted'] == true,
      manufacturer: (values['manufacturer'] as String? ?? '').trim(),
      events: List<ReminderDiagnosticEvent>.unmodifiable(events),
    );
  }

  /// 创建原生通道不可用时的空快照，诊断页仍可正常加载其他内容。
  factory ReminderDiagnosticsSnapshot.unavailable() {
    return const ReminderDiagnosticsSnapshot(
      pendingCount: 0,
      lastScheduledAt: null,
      lastTriggeredAt: null,
      lastRestoredAt: null,
      lastTriggerResult: 'unavailable',
      lastScheduleMode: 'unavailable',
      exactAlarmAllowed: false,
      notificationsEnabled: false,
      batteryOptimizationIgnored: false,
      backgroundRestricted: false,
      manufacturer: '',
      events: <ReminderDiagnosticEvent>[],
    );
  }

  /// 把平台毫秒时间戳转换为本地时间，零值和错误类型统一返回空。
  static DateTime? _dateTimeFromMilliseconds(Object? value) {
    final int milliseconds = (value as num?)?.toInt() ?? 0;
    return milliseconds <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
}

/// 保存一条可复制给开发者的脱敏错误记录。
class ProblemDiagnosticEntry {
  /// 创建一条最近错误记录；附加信息必须是不会识别用户身份的短文本。
  const ProblemDiagnosticEntry({
    required this.occurredAt,
    required this.category,
    required this.operation,
    required this.description,
    this.errorCode,
    this.additionalInfo = const <String, String>{},
  });

  /// 错误发生的本机时间。
  final DateTime occurredAt;

  /// 便于诊断文本稳定处理的英文分类，例如 riskControl、network、playback。
  final String category;

  /// 不含用户输入的固定操作名，例如 load_play_url 或 search_video。
  final String operation;

  /// 平台或业务错误码；没有可靠代码时为空。
  final int? errorCode;

  /// 面向用户和开发者的简短、脱敏错误说明。
  final String description;

  /// 只保存有限的播放器状态或布尔标记，不保存视频地址、Cookie、搜索词或笔记内容。
  final Map<String, String> additionalInfo;

  /// 返回页面中的中文分类标签，保留英文分类给复制诊断文本使用。
  String get categoryLabel => switch (category) {
    'riskControl' => '播放错误 / 请求限制',
    'network' => '网络错误',
    'playback' => '播放错误',
    'app' => '应用错误',
    _ => '其他错误',
  };

  /// 返回页面中的中文操作标签，固定操作名仍会写入复制文本方便程序化定位。
  String get operationLabel => switch (operation) {
    'load_play_url' => '获取视频播放地址',
    'search_video' => '搜索视频',
    'open_video_detail' => '获取视频详情',
    'flutter_framework' => 'Flutter 界面运行',
    'dart_runtime' => 'Dart 运行时',
    _ => operation,
  };

  /// 将诊断记录转换为可安全写入 SharedPreferences 的 JSON 字典。
  Map<String, Object> toJson() {
    return <String, Object>{
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      'category': category,
      'operation': operation,
      'errorCode': errorCode ?? 0,
      'hasErrorCode': errorCode != null,
      'description': description,
      'additionalInfo': additionalInfo,
    };
  }

  /// 从本机 JSON 安全读取一条诊断记录；损坏、过长或缺失关键字段时返回 null。
  static ProblemDiagnosticEntry? tryParse(Map<String, dynamic> json) {
    final Object? occurredAt = json['occurredAt'];
    final Object? category = json['category'];
    final Object? operation = json['operation'];
    final Object? description = json['description'];
    if (occurredAt is! String ||
        category is! String ||
        operation is! String ||
        description is! String) {
      return null;
    }
    final DateTime? parsedTime = DateTime.tryParse(occurredAt);
    final String safeCategory = category.trim();
    final String safeOperation = operation.trim();
    final String safeDescription = description.trim();
    if (parsedTime == null ||
        safeCategory.isEmpty ||
        safeOperation.isEmpty ||
        safeDescription.isEmpty ||
        safeDescription.length > 240) {
      return null;
    }
    final bool hasErrorCode = json['hasErrorCode'] == true;
    final Object? rawCode = json['errorCode'];
    final int? errorCode = hasErrorCode && rawCode is num
        ? rawCode.toInt().clamp(-999999, 999999).toInt()
        : null;
    final Map<String, String> additionalInfo = <String, String>{};
    final Object? rawAdditionalInfo = json['additionalInfo'];
    if (rawAdditionalInfo is Map) {
      for (final MapEntry<Object?, Object?> item in rawAdditionalInfo.entries) {
        final String key = item.key?.toString().trim() ?? '';
        final String value = item.value?.toString().trim() ?? '';
        if (key.isEmpty ||
            value.isEmpty ||
            key.length > 40 ||
            value.length > 120 ||
            additionalInfo.length >= 8) {
          continue;
        }
        additionalInfo[key] = value;
      }
    }
    return ProblemDiagnosticEntry(
      occurredAt: parsedTime.toLocal(),
      category: safeCategory,
      operation: safeOperation,
      errorCode: errorCode,
      description: safeDescription,
      additionalInfo: Map<String, String>.unmodifiable(additionalInfo),
    );
  }
}

/// 汇总一次诊断页面或复制动作所需的环境信息、生成时间和最近错误。
class ProblemDiagnosticsSnapshot {
  /// 创建一份完整诊断快照；错误记录以最新优先的顺序保存。
  const ProblemDiagnosticsSnapshot({
    required this.appVersion,
    required this.deviceInfo,
    required this.generatedAt,
    required this.recentErrors,
    required this.reminderDiagnostics,
  });

  /// 当前已安装应用的语义版本与构建号。
  final String appVersion;

  /// 当前设备的公开 Android 环境信息。
  final DiagnosticDeviceInfo deviceInfo;

  /// 本次页面加载或复制文本生成的时间。
  final DateTime generatedAt;

  /// 最多保留固定数量的近期脱敏错误。
  final List<ProblemDiagnosticEntry> recentErrors;
  final ReminderDiagnosticsSnapshot reminderDiagnostics;
}

/// 提供问题诊断 MVP 的本机记录、环境读取、复制文本和清空能力。
class ProblemDiagnosticsService {
  /// 创建诊断服务；可注入时钟、偏好设置和环境读取函数以支持稳定测试。
  ProblemDiagnosticsService({
    ProblemDiagnosticsPreferencesLoader? preferencesLoader,
    ProblemDiagnosticsAppVersionLoader? appVersionLoader,
    ProblemDiagnosticsDeviceInfoLoader? deviceInfoLoader,
    ReminderDiagnosticsLoader? reminderDiagnosticsLoader,
    ReminderDiagnosticsClearer? reminderDiagnosticsClearer,
    DateTime Function()? clock,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _appVersionLoader = appVersionLoader ?? _loadInstalledAppVersion,
       _deviceInfoLoader = deviceInfoLoader ?? _loadNativeDeviceInfo,
       _reminderDiagnosticsLoader =
           reminderDiagnosticsLoader ?? _loadNativeReminderDiagnostics,
       _reminderDiagnosticsClearer =
           reminderDiagnosticsClearer ?? _clearNativeReminderDiagnostics,
       _clock = clock ?? DateTime.now;

  static const String _storageKey = 'focubili_problem_diagnostics_v1';

  /// 最多保存二十条错误，既足够定位最近问题，也避免本机偏好设置无限增长。
  static const int maximumRecentErrors = 20;

  static const MethodChannel _deviceChannel = MethodChannel(
    'com.focubili.app/device_status',
  );

  final ProblemDiagnosticsPreferencesLoader _preferencesLoader;
  final ProblemDiagnosticsAppVersionLoader _appVersionLoader;
  final ProblemDiagnosticsDeviceInfoLoader _deviceInfoLoader;
  final ReminderDiagnosticsLoader _reminderDiagnosticsLoader;
  final ReminderDiagnosticsClearer _reminderDiagnosticsClearer;
  final DateTime Function() _clock;

  /// 读取当前设备已保存的最近错误，损坏记录会被自动忽略。
  Future<List<ProblemDiagnosticEntry>> loadRecentErrors() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      final String? rawJson = preferences.getString(_storageKey);
      if (rawJson == null || rawJson.trim().isEmpty) {
        return const <ProblemDiagnosticEntry>[];
      }
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List<Object?>) {
        return const <ProblemDiagnosticEntry>[];
      }
      final List<ProblemDiagnosticEntry> records = <ProblemDiagnosticEntry>[];
      for (final Object? item in decoded) {
        if (item is! Map) {
          continue;
        }
        final ProblemDiagnosticEntry? record = ProblemDiagnosticEntry.tryParse(
          Map<String, dynamic>.from(item),
        );
        if (record != null) {
          records.add(record);
        }
        if (records.length >= maximumRecentErrors) {
          break;
        }
      }
      records.sort(
        (ProblemDiagnosticEntry left, ProblemDiagnosticEntry right) =>
            right.occurredAt.compareTo(left.occurredAt),
      );
      return List<ProblemDiagnosticEntry>.unmodifiable(records);
    } catch (_) {
      // 诊断存储本身不可用时保持空列表，绝不影响正常播放、搜索和笔记功能。
      return const <ProblemDiagnosticEntry>[];
    }
  }

  /// 记录播放器失败；只提取状态码、固定操作名和脱敏状态，不记录地址或会话数据。
  Future<void> recordPlaybackFailure({
    required String message,
    required String playerState,
    required bool multiPart,
  }) {
    final int? code = _extractErrorCode(message);
    final String category = _categoryFor(message, code, fallback: 'playback');
    return record(
      ProblemDiagnosticEntry(
        occurredAt: _clock(),
        category: category,
        operation: 'load_play_url',
        errorCode: code,
        description: _descriptionForPlayback(message, code, category),
        additionalInfo: <String, String>{
          'player_state': _sanitizeText(playerState, fallback: 'unknown'),
          'multi_part': multiPart.toString(),
        },
      ),
    );
  }

  /// 记录网络或业务请求失败；调用方只传固定操作名和错误说明，不传用户搜索词或 URL。
  Future<void> recordNetworkFailure({
    required String operation,
    required String message,
  }) {
    final int? code = _extractErrorCode(message);
    final String category = _categoryFor(message, code, fallback: 'network');
    final String safeOperation = _sanitizeOperation(operation);
    // 搜索服务的动态错误文本有机会回显用户关键词，因此诊断只保留固定说明和已提取的安全错误码。
    final String safeMessage =
        safeOperation == 'search_video' || safeOperation == 'search_user'
        ? '网络连接失败。'
        : message;
    return record(
      ProblemDiagnosticEntry(
        occurredAt: _clock(),
        category: category,
        operation: safeOperation,
        errorCode: code,
        description: _descriptionForNetwork(safeMessage, code, category),
      ),
    );
  }

  /// 记录未预期框架或运行时错误；不保存异常原文和堆栈，避免意外携带用户输入。
  Future<void> recordUnexpectedError({required String operation}) {
    return record(
      ProblemDiagnosticEntry(
        occurredAt: _clock(),
        category: 'app',
        operation: _sanitizeOperation(operation),
        description: '应用遇到未预期错误，请复制诊断信息后反馈给开发者。',
      ),
    );
  }

  /// 将一条已脱敏记录写入设备，并只保留最新的固定数量。
  Future<void> record(ProblemDiagnosticEntry entry) async {
    try {
      final List<ProblemDiagnosticEntry> existing = await loadRecentErrors();
      final ProblemDiagnosticEntry safeEntry = _sanitizeEntry(entry);
      final List<ProblemDiagnosticEntry> records =
          <ProblemDiagnosticEntry>[safeEntry, ...existing]..sort(
            (ProblemDiagnosticEntry left, ProblemDiagnosticEntry right) =>
                right.occurredAt.compareTo(left.occurredAt),
          );
      final List<ProblemDiagnosticEntry> limited = records
          .take(maximumRecentErrors)
          .toList(growable: false);
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.setString(
        _storageKey,
        jsonEncode(
          limited
              .map((ProblemDiagnosticEntry entry) => entry.toJson())
              .toList(growable: false),
        ),
      );
    } catch (_) {
      // 写诊断失败不能反过来制造新的错误，也不能打断原始业务流程。
    }
  }

  /// 清空本机诊断记录；登录状态、观看记录、笔记和学习清单不会受到影响。
  Future<void> clearRecentErrors() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.remove(_storageKey);
      await _reminderDiagnosticsClearer();
    } catch (_) {
      // 存储暂不可用时页面仍会在重新加载后显示实际可读取的数据。
    }
  }

  /// 读取应用版本、Android 环境和最近错误，生成供页面展示的一次性诊断快照。
  Future<ProblemDiagnosticsSnapshot> loadSnapshot() async {
    final List<Object> values = await Future.wait<Object>(<Future<Object>>[
      _loadVersionSafely(),
      _loadDeviceInfoSafely(),
      loadRecentErrors(),
      _loadReminderDiagnosticsSafely(),
    ]);
    return ProblemDiagnosticsSnapshot(
      appVersion: values[0] as String,
      deviceInfo: values[1] as DiagnosticDeviceInfo,
      generatedAt: _clock(),
      recentErrors: values[2] as List<ProblemDiagnosticEntry>,
      reminderDiagnostics: values[3] as ReminderDiagnosticsSnapshot,
    );
  }

  /// 按用户要求的固定格式生成可复制诊断文本，并在末尾明确写出隐私范围。
  Future<String> buildCopyText() async {
    final ProblemDiagnosticsSnapshot snapshot = await loadSnapshot();
    final StringBuffer text = StringBuffer()
      ..writeln('FocuBili 问题诊断')
      ..writeln()
      ..writeln('应用版本：${snapshot.appVersion}')
      ..writeln('Android：${snapshot.deviceInfo.androidLabel}')
      ..writeln('设备型号：${snapshot.deviceInfo.model}')
      ..writeln('生成时间：${formatDiagnosticDateTime(snapshot.generatedAt)}')
      ..writeln()
      ..writeln('提醒诊断：')
      ..writeln('待触发提醒：${snapshot.reminderDiagnostics.pendingCount}')
      ..writeln(
        '精确闹钟权限：${snapshot.reminderDiagnostics.exactAlarmAllowed ? '已允许' : '未允许'}',
      )
      ..writeln(
        '通知状态：${snapshot.reminderDiagnostics.notificationsEnabled ? '已开启' : '未开启'}',
      )
      ..writeln(
        '后台限制：${snapshot.reminderDiagnostics.backgroundRestricted ? '受限制' : '未检测到限制'}',
      )
      ..writeln(
        '最近安排：${_formatOptionalDiagnosticTime(snapshot.reminderDiagnostics.lastScheduledAt)}',
      )
      ..writeln(
        '最近触发：${_formatOptionalDiagnosticTime(snapshot.reminderDiagnostics.lastTriggeredAt)}',
      );
    if (snapshot.reminderDiagnostics.events.isEmpty) {
      text.writeln('最近提醒事件：（暂无记录）');
    } else {
      text.writeln('最近提醒事件：');
      for (final ReminderDiagnosticEvent event
          in snapshot.reminderDiagnostics.events) {
        text.writeln(
          '- [${formatDiagnosticDateTime(event.occurredAt)}] ${event.type} / ${event.result}'
          '${event.mode.isEmpty ? '' : ' / ${event.mode}'}',
        );
      }
    }
    text
      ..writeln()
      ..writeln('最近错误：');
    if (snapshot.recentErrors.isEmpty) {
      text.writeln('（暂无记录）');
    } else {
      for (final ProblemDiagnosticEntry entry in snapshot.recentErrors) {
        text
          ..writeln()
          ..writeln('[${formatDiagnosticDateTime(entry.occurredAt)}]')
          ..writeln('分类：${entry.category}')
          ..writeln('操作：${entry.operation}');
        if (entry.errorCode != null) {
          text.writeln('错误代码：${entry.errorCode}');
        }
        text.writeln('说明：${entry.description}');
        if (entry.additionalInfo.isNotEmpty) {
          text.writeln('附加信息：');
          for (final MapEntry<String, String> item
              in entry.additionalInfo.entries) {
            text.writeln('- ${item.key}: ${item.value}');
          }
        }
      }
    }
    text
      ..writeln()
      ..writeln('隐私说明：')
      ..writeln('本诊断信息不包含登录凭据、Cookie、搜索内容、笔记正文、专注目标或完整请求地址。');
    return text.toString().trimRight();
  }

  /// 安全读取安装版本；插件在测试或极少数异常设备不可用时回退到当前发布版本。
  Future<String> _loadVersionSafely() async {
    try {
      final String version = (await _appVersionLoader()).trim();
      return version.isEmpty ? '1.1.1+10' : version;
    } catch (_) {
      return '1.1.1+10';
    }
  }

  /// 安全读取 Android 环境；原生通道不可用时保留不含标识符的最小回退信息。
  Future<DiagnosticDeviceInfo> _loadDeviceInfoSafely() async {
    try {
      return await _deviceInfoLoader();
    } catch (_) {
      return _fallbackDeviceInfo();
    }
  }

  /// 安全读取原生闹钟诊断；通道不可用时返回空快照而不影响错误记录。
  Future<ReminderDiagnosticsSnapshot> _loadReminderDiagnosticsSafely() async {
    try {
      return await _reminderDiagnosticsLoader();
    } catch (_) {
      return ReminderDiagnosticsSnapshot.unavailable();
    }
  }

  /// 把可空提醒时间格式化为诊断文本；没有原生记录时显示“从未”。
  String _formatOptionalDiagnosticTime(DateTime? value) {
    return value == null ? '从未' : formatDiagnosticDateTime(value);
  }

  /// 通过专注通知通道读取原生闹钟的安排、恢复和触发状态。
  static Future<ReminderDiagnosticsSnapshot>
  _loadNativeReminderDiagnostics() async {
    final Map<Object?, Object?> values = await const FocusNotificationService()
        .getReminderDiagnostics();
    return values.isEmpty
        ? ReminderDiagnosticsSnapshot.unavailable()
        : ReminderDiagnosticsSnapshot.fromPlatformMap(values);
  }

  /// 请求原生层只清除闹钟诊断事件，仍待触发的提醒保持不变。
  static Future<void> _clearNativeReminderDiagnostics() {
    return const FocusNotificationService().clearReminderDiagnostics();
  }

  /// 将调用方传入的记录再次收敛为有限、脱敏且可安全复制的字段。
  ProblemDiagnosticEntry _sanitizeEntry(ProblemDiagnosticEntry entry) {
    final Map<String, String> additionalInfo = <String, String>{};
    for (final MapEntry<String, String> item in entry.additionalInfo.entries) {
      final String key = _sanitizeInfoKey(item.key);
      final String value = _sanitizeText(item.value, fallback: 'unknown');
      if (key.isEmpty || additionalInfo.length >= 8) {
        continue;
      }
      additionalInfo[key] = value;
    }
    return ProblemDiagnosticEntry(
      occurredAt: entry.occurredAt,
      category: _sanitizeCategory(entry.category),
      operation: _sanitizeOperation(entry.operation),
      errorCode: entry.errorCode?.clamp(-999999, 999999).toInt(),
      description: _sanitizeText(entry.description, fallback: '未提供说明'),
      additionalInfo: Map<String, String>.unmodifiable(additionalInfo),
    );
  }

  /// 按消息与状态码识别风控、网络或播放错误，未知情况使用调用方提供的安全分类。
  String _categoryFor(String message, int? code, {required String fallback}) {
    final String normalized = message.toLowerCase();
    if (code?.abs() == 412 ||
        normalized.contains('风控') ||
        normalized.contains('risk') ||
        normalized.contains('拒绝')) {
      return 'riskControl';
    }
    if (normalized.contains('网络') ||
        normalized.contains('连接') ||
        normalized.contains('timeout') ||
        normalized.contains('socket')) {
      return 'network';
    }
    return fallback;
  }

  /// 为播放失败生成优先可读的脱敏说明，412 类风控错误使用固定说明避免带出服务端原文。
  String _descriptionForPlayback(String message, int? code, String category) {
    if (category == 'riskControl' && code?.abs() == 412) {
      return '平台暂时拒绝了本次请求。';
    }
    return _sanitizeText(message, fallback: '无法获取视频播放地址，请稍后重试。');
  }

  /// 为网络失败生成优先可读的脱敏说明，风控请求同样使用固定说明保护服务端原文。
  String _descriptionForNetwork(String message, int? code, String category) {
    if (category == 'riskControl' && code?.abs() == 412) {
      return '平台暂时拒绝了本次请求。';
    }
    return _sanitizeText(message, fallback: '网络连接失败。');
  }

  /// 从有限的 HTTP、错误码或 code 文本中提取整数状态码，不能识别时返回 null。
  int? _extractErrorCode(String message) {
    final List<RegExp> patterns = <RegExp>[
      RegExp(
        r'(?:HTTP|错误码|error\s*code|code)\s*[：:=]?\s*(-?\d{1,6})',
        caseSensitive: false,
      ),
      RegExp(r'\b(4(?:0[0-9]|1[0-9]|2[0-9]|3[0-9]|4[0-9]|5[0-9]|9[0-9]))\b'),
    ];
    for (final RegExp pattern in patterns) {
      final RegExpMatch? match = pattern.firstMatch(message);
      final int? value = int.tryParse(match?.group(1) ?? '');
      if (value != null) {
        return value.clamp(-999999, 999999).toInt();
      }
    }
    return null;
  }

  /// 把固定操作名限制为英文小写、数字和下划线，避免把动态用户输入写进诊断文本。
  String _sanitizeOperation(String value) {
    final String normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return normalized.isEmpty
        ? 'unknown_operation'
        : normalized.substring(0, normalized.length.clamp(0, 48).toInt());
  }

  /// 将错误分类限制在 MVP 支持的固定枚举，未知文本统一作为 other 输出。
  String _sanitizeCategory(String value) {
    return switch (value.trim()) {
      'riskControl' => 'riskControl',
      'network' => 'network',
      'playback' => 'playback',
      'app' => 'app',
      _ => 'other',
    };
  }

  /// 将附加信息键限制为简短英文标识，避免动态文本或隐私字段进入复制内容。
  String _sanitizeInfoKey(String value) {
    final String normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return normalized.isEmpty
        ? ''
        : normalized.substring(0, normalized.length.clamp(0, 40).toInt());
  }

  /// 清除 URL、常见凭据片段、连续空白和过长文本，保证诊断说明不会携带敏感资料。
  String _sanitizeText(String value, {required String fallback}) {
    String normalized = value
        .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '[已隐藏地址]')
        .replaceAll(
          RegExp(
            r'(cookie|sessdata|bili_jct|access[_-]?token)\s*[:=]\s*[^\s;,]+',
            caseSensitive: false,
          ),
          r'$1=[已隐藏]',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) {
      return fallback;
    }
    if (normalized.length > 220) {
      normalized = '${normalized.substring(0, 219)}…';
    }
    return normalized;
  }

  /// 通过 package_info_plus 读取真实安装版本；构建号存在时组合为“版本+构建号”。
  static Future<String> _loadInstalledAppVersion() async {
    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    final String version = packageInfo.version.trim();
    final String buildNumber = packageInfo.buildNumber.trim();
    if (version.isEmpty) {
      return '';
    }
    return buildNumber.isEmpty ? version : '$version+$buildNumber';
  }

  /// 通过既有 Android 设备状态通道读取公开系统版本和型号；桌面测试没有通道时使用最小回退。
  static Future<DiagnosticDeviceInfo> _loadNativeDeviceInfo() async {
    try {
      final Object? result = await _deviceChannel.invokeMethod<Object?>(
        'getDiagnosticDeviceInfo',
      );
      if (result is Map) {
        return DiagnosticDeviceInfo.fromPlatformMap(
          Map<Object?, Object?>.from(result),
        );
      }
    } on MissingPluginException {
      // 测试或非 Android 平台没有原生实现时使用公开的最小回退信息。
    } on PlatformException {
      // 原生调用失败时不影响设置页，改为显示未知环境字段。
    }
    return _fallbackDeviceInfo();
  }

  /// 创建没有设备唯一标识符的环境回退值，供非 Android 平台或通道失败时展示。
  static DiagnosticDeviceInfo _fallbackDeviceInfo() {
    final String system = Platform.isAndroid
        ? Platform.operatingSystemVersion.trim()
        : '未知';
    final RegExpMatch? releaseMatch = RegExp(
      r'(\d+(?:\.\d+)*)',
    ).firstMatch(system);
    return DiagnosticDeviceInfo(
      androidRelease: releaseMatch?.group(1) ?? '未知',
      apiLevel: null,
      model: '未知设备',
    );
  }
}

/// 将本机时间格式化为诊断页面和复制文本统一使用的“年月日 时:分:秒”格式。
String formatDiagnosticDateTime(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}
