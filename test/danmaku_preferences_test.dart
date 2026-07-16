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

  test('旧用户无配置时返回明确默认值', () async {
    final DanmakuPreferences value = await DanmakuPreferencesService().load();
    expect(value.enabled, isFalse);
    expect(value.opacity, 0.9);
    expect(value.fontSize, 15);
    expect(value.laneCount, 12);
    expect(value.scrollDurationSeconds, 9);
    expect(value.blockedKeywords, isEmpty);
  });

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
    expect(value.scrollDurationSeconds,
        DanmakuPreferences.maxScrollDurationSeconds);
  });

  test('关键词匹配忽略大小写与空白且空关键词不误伤', () {
    final DanmakuPreferences value = DanmakuPreferences(
      blockedKeywords: <String>['  AbC  ', ' ', '广告'],
    );
    expect(value.blocks('prefix aBc suffix'), isTrue);
    expect(value.blocks('这是一条广告内容'), isTrue);
    expect(value.blocks('普通弹幕'), isFalse);
  });

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
}
