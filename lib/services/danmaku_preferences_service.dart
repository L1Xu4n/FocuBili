import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/danmaku_preferences.dart';

/// 定义可替换的偏好读取入口，使单元测试无需依赖真实平台通道。
typedef DanmakuPreferencesLoader = Future<SharedPreferences> Function();

/// 使用 SharedPreferences 持久化全局弹幕配置，存储不可用时安全降级为内存与默认值。
class DanmakuPreferencesService {
  /// 创建服务；生产环境读取真实 SharedPreferences，测试可注入内存实例或失败读取器。
  DanmakuPreferencesService({DanmakuPreferencesLoader? preferencesLoader}) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;
  static const String storageKey = 'focubili_danmaku_preferences_v1';
  final DanmakuPreferencesLoader _preferencesLoader;

  /// 读取并解析 JSON；旧用户无键、数据损坏或平台失败时返回完整默认配置，不阻断播放器启动。
  Future<DanmakuPreferences> load() async {
    try {
      final String? raw = (await _preferencesLoader()).getString(storageKey);
      if (raw == null || raw.trim().isEmpty) return DanmakuPreferences();
      final Object? decoded = jsonDecode(raw);
      return decoded is Map ? DanmakuPreferences.fromJson(Map<String, dynamic>.from(decoded)) : DanmakuPreferences();
    } catch (_) {
      return DanmakuPreferences();
    }
  }

  /// 写入归一化配置并返回是否成功；失败时返回 false，调用方仍保留当前会话配置并继续播放。
  Future<bool> save(DanmakuPreferences preferences) async {
    try {
      return await (await _preferencesLoader()).setString(storageKey, jsonEncode(preferences.toJson()));
    } catch (_) {
      return false;
    }
  }
}
