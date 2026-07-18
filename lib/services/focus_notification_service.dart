import 'dart:io';

import 'package:flutter/services.dart';

/// 通过 Android 原生方法通道管理提醒通知、权限和系统设置入口。
class FocusNotificationService {
  /// 创建通知服务；测试可注入自定义方法通道。
  const FocusNotificationService({MethodChannel? channel})
    : _usesDefaultChannel = channel == null,
      _channel =
          channel ??
          const MethodChannel('com.focubili.app/focus_notifications');

  final MethodChannel _channel;
  final bool _usesDefaultChannel;

  /// Flutter 组件测试没有 Android 消息接收端，默认通道应直接使用安全返回值。
  bool get _skipDefaultChannelInFlutterTest =>
      _usesDefaultChannel && Platform.environment['FLUTTER_TEST'] == 'true';

  /// 检查当前平台是否已经允许应用发送通知。
  Future<bool> hasPermission() async {
    if (_skipDefaultChannelInFlutterTest) {
      return false;
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
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开当前应用的系统通知设置页，方便用户手动恢复权限。
  Future<void> openSettings() async {
    if (_skipDefaultChannelInFlutterTest) {
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
}
