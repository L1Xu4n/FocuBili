import 'package:flutter/services.dart';

/// 通过 Windows Runner 查询官方系统专注能力并打开设置；未获授权时安全拒绝自动切换。
class WindowsDoNotDisturbService {
  /// 创建 Windows 勿扰服务；测试可注入假方法通道。
  const WindowsDoNotDisturbService({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.focubili.app/windows_do_not_disturb');

  final MethodChannel _channel;

  /// 检查当前安装包是否具备微软批准的系统专注自动切换能力。
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 请求开启官方系统专注，或在关闭时清理旧版本遗留状态，并返回是否执行成功。
  Future<bool> setEnabled(bool enabled) async {
    try {
      return await _channel.invokeMethod<bool>('setEnabled', <String, Object?>{
            'enabled': enabled,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 打开 Windows 的勿扰/专注助手设置页，让旧系统用户继续手动配置。
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on MissingPluginException {
      // 非 Windows 与组件测试没有 Runner 通道时保持无操作。
    } on PlatformException {
      // 系统没有对应设置页时不影响专注计时和视频播放。
    }
  }
}
