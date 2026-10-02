import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/dashboard_layout.dart';
import 'package:focubili/services/dashboard_layout_service.dart';

/// 创建只有身份和条件变化的卡片，用于验证纯布局规则。
DashboardCardDefinition card(
  String id, {
  bool required = false,
  bool available = true,
}) => DashboardCardDefinition(
  id: id,
  title: '同名卡片',
  icon: Icons.rectangle,
  builder: (_) => const SizedBox(),
  required: required,
  available: available,
);

/// 模拟拒绝写入、抛出异常以及先更新内存缓存的偏好实现。
class ControlledPreferences extends Fake implements SharedPreferences {
  final values = <String, String>{};
  final writes = <String>[];
  bool reject = false;
  bool throwOnWrite = false;
  Completer<void>? gate;

  /// 返回缓存值，故意保留失败写入以验证服务的旧值回退。
  @override
  String? getString(String key) => values[key];

  /// 按测试开关阻塞或拒绝保存，用来观察串行写入顺序。
  @override
  Future<bool> setString(String key, String value) async {
    writes.add(value);
    values[key] = value;
    if (gate != null) await gate!.future;
    if (throwOnWrite) throw StateError('模拟存储异常');
    return !reject;
  }

  /// 保持缓存不变，验证即使重新同步无效也不会采用失败的新布局。
  @override
  Future<void> reload() async {}
}

/// 验证稳定身份、条件保留、损坏容错、页面隔离与真实失败语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('协调保留未知及不可用位置，追加新卡片并强制显示设置', () {
    final cards = [
      card('a'),
      card('timer', available: false),
      card('settings', required: true),
      card('new'),
    ];
    final layout = DashboardLayout(
      order: ['a', 'future', 'timer', 'a', '', 'settings'],
      hidden: ['future', 'settings', ''],
    ).reconcile(cards);
    expect(layout.order, ['a', 'future', 'timer', 'settings', 'new']);
    expect(layout.hidden, {'future'});
    expect(layout.visibleCards(cards).map((e) => e.id), [
      'a',
      'settings',
      'new',
    ]);
    final restored = layout.reconcile([
      card('a'),
      card('timer'),
      card('settings', required: true),
      card('new'),
    ]);
    expect(restored.order.indexOf('timer'), 2);
    expect(restored.visibleCards([card('timer')]).single.id, 'timer');
    expect(layout.setHidden('settings', true, cards).hidden, {'future'});
    expect(layout.move('new', 'a').order, [
      'new',
      'a',
      'future',
      'timer',
      'settings',
    ]);
  });

  test('损坏 JSON 和错误字段可恢复，合法未知编号仍保留', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = DashboardLayoutService(
      preferencesLoader: () async => prefs,
    );
    final key = DashboardLayoutService.storageKey('home');
    await prefs.setString(key, '{');
    expect((await service.load('home', [card('a')])).order, ['a']);
    await prefs.setString(
      key,
      jsonEncode({
        'order': ['unknown', 7, 'a', 'a', ''],
        'hidden': ['unknown', false],
      }),
    );
    final layout = await service.load('home', [card('a')]);
    expect(layout.order, ['unknown', 'a']);
    expect(layout.hidden, {'unknown'});
  });

  test('首页和个人中心分别保存，重建服务仍可恢复', () async {
    final service = DashboardLayoutService();
    await service.save(
      'home',
      DashboardLayout(order: ['b', 'a'], hidden: ['a']),
    );
    await service.save(
      'profile',
      DashboardLayout(order: ['settings', 'account']),
    );
    final fresh = DashboardLayoutService();
    final home = await fresh.load('home', [card('a'), card('b')]);
    expect(home.order, ['b', 'a']);
    expect(home.hidden, {'a'});
    expect(
      (await fresh.load('profile', [
        card('account'),
        card('settings', required: true),
      ])).order,
      ['settings', 'account'],
    );
  });

  test('拒绝及异常均报告失败，旧布局保留且后续写入可继续', () async {
    final prefs = ControlledPreferences();
    final service = DashboardLayoutService(
      preferencesLoader: () async => prefs,
    );
    await service.save('home', DashboardLayout(order: ['a', 'b']));
    prefs.reject = true;
    await expectLater(
      service.save('home', DashboardLayout(order: ['b', 'a'])),
      throwsStateError,
    );
    expect((await service.load('home', [])).order, ['a', 'b']);
    prefs.reject = false;
    prefs.throwOnWrite = true;
    await expectLater(
      service.save('home', DashboardLayout(order: ['b', 'a'])),
      throwsStateError,
    );
    expect((await service.load('home', [])).order, ['a', 'b']);
    prefs.throwOnWrite = false;
    await service.save('home', DashboardLayout(order: ['b', 'a']));
    expect((await service.load('home', [])).order, ['b', 'a']);
  });

  test('连续保存串行执行，后一笔不能先完成覆盖', () async {
    final prefs = ControlledPreferences()..gate = Completer<void>();
    final service = DashboardLayoutService(
      preferencesLoader: () async => prefs,
    );
    final first = service.save('home', DashboardLayout(order: ['a', 'b']));
    final second = service.save('home', DashboardLayout(order: ['b', 'a']));
    await Future<void>.delayed(Duration.zero);
    expect(prefs.writes.length, 1);
    prefs.gate!.complete();
    await Future.wait([first, second]);
    expect(prefs.writes.length, 2);
    expect((await service.load('home', [])).order, ['b', 'a']);
  });
}
