import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/danmaku_preferences.dart';
import 'package:focubili/services/danmaku_preferences_service.dart';

/// 验证弹幕配置的默认兼容、序列化、边界、屏蔽规则以及 SharedPreferences 恢复。
void main() {
  /// 每个用例前清空插件内存存储，防止持久化测试互相污染。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 验证未保存过弹幕配置的旧用户会安全获得全部默认值。
  test('旧用户无配置时返回明确默认值', () async {
    final DanmakuPreferences value = await DanmakuPreferencesService().load();
    expect(value.enabled, isFalse);
    expect(value.opacity, 0.9);
    expect(value.fontSize, 15);
    expect(value.laneCount, 12);
    expect(value.scrollDurationSeconds, 9);
    expect(value.blockedKeywords, isEmpty);
  });

  /// 验证 JSON 往返不丢字段，同时规范空白、大小写不同和重复的屏蔽词。
  test('序列化往返保留所有字段并规范关键词', () {
    final DanmakuPreferences value = DanmakuPreferences(
      enabled: true,
      opacity: 0.6,
      fontSize: 18,
      laneCount: 8,
      scrollDurationSeconds: 6,
      blockedKeywords: <String>[' Spoiler ', 'spoiler', '', '广告'],
    );
    final DanmakuPreferences restored = DanmakuPreferences.fromJson(
      jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>,
    );
    expect(restored.toJson(), value.toJson());
    expect(restored.blockedKeywords, <String>['Spoiler', '广告']);
  });

  /// 验证超出最小值或最大值的数字会被截断到合法区间。
  test('越界和错误类型被截断或回退到合法范围', () {
    final DanmakuPreferences value = DanmakuPreferences.fromJson(
      <String, dynamic>{
        'opacity': -5,
        'fontSize': 100,
        'laneCount': 0,
        'scrollDurationSeconds': 999,
      },
    );
    expect(value.opacity, DanmakuPreferences.minOpacity);
    expect(value.fontSize, DanmakuPreferences.maxFontSize);
    expect(value.laneCount, DanmakuPreferences.minLaneCount);
    expect(
      value.scrollDurationSeconds,
      DanmakuPreferences.maxScrollDurationSeconds,
    );
  });

  /// 验证 NaN 和无穷值不会进入滑块或绘制逻辑，而是恢复各字段默认值。
  test('非有限数值回退到安全默认值', () {
    final DanmakuPreferences value = DanmakuPreferences(
      opacity: double.nan,
      fontSize: double.infinity,
      scrollDurationSeconds: double.negativeInfinity,
    );
    expect(value.opacity, DanmakuPreferences.defaultOpacity);
    expect(value.fontSize, DanmakuPreferences.defaultFontSize);
    expect(
      value.scrollDurationSeconds,
      DanmakuPreferences.defaultScrollDurationSeconds,
    );
  });

  /// 验证屏蔽规则使用忽略大小写的包含匹配，且空关键词不会屏蔽所有弹幕。
  test('关键词匹配忽略大小写与空白且空关键词不误伤', () {
    final DanmakuPreferences value = DanmakuPreferences(
      blockedKeywords: <String>['  AbC  ', ' ', '广告'],
    );
    expect(value.blocks('prefix aBc suffix'), isTrue);
    expect(value.blocks('这是一条广告内容'), isTrue);
    expect(value.blocks('普通弹幕'), isFalse);
  });

  /// 验证 SharedPreferences 保存后能在新的读取流程中恢复开关和轨道数。
  test('服务保存后可恢复轨道配置', () async {
    final DanmakuPreferencesService service = DanmakuPreferencesService();
    expect(
      await service.save(DanmakuPreferences(enabled: true, laneCount: 20)),
      isTrue,
    );
    final DanmakuPreferences restored = await service.load();
    expect(restored.enabled, isTrue);
    expect(restored.laneCount, 20);
  });

  /// 验证连续保存会按调用顺序写入，最后一次的轨道数不会被旧请求覆盖。
  test('连续保存后恢复最新配置', () async {
    final DanmakuPreferencesService service = DanmakuPreferencesService();
    final List<bool> results = await Future.wait(<Future<bool>>[
      service.save(DanmakuPreferences(laneCount: 3)),
      service.save(DanmakuPreferences(laneCount: 24)),
    ]);
    expect(results, everyElement(isTrue));
    expect((await service.load()).laneCount, 24);
  });

  /// 验证本机 JSON 损坏时服务会返回默认配置，不向播放器抛出解析异常。
  test('损坏的持久化数据降级为默认配置', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      DanmakuPreferencesService.storageKey: '{invalid-json',
    });
    final DanmakuPreferences value = await DanmakuPreferencesService().load();
    expect(value.toJson(), DanmakuPreferences().toJson());
  });
}
