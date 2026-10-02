import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/widgets/editable_card_board.dart';
import 'package:focubili/models/dashboard_layout.dart' show DashboardLayout;
import 'package:focubili/services/dashboard_layout_service.dart';

/// 构造容易测量和点击的业务卡片，布局组件不能调用其内部动作。
DashboardCardDefinition card(
  String id, {
  bool required = false,
  VoidCallback? onTap,
  Key? contentKey,
  bool available = true,
}) => DashboardCardDefinition(
  id: id,
  title: id,
  icon: Icons.rectangle,
  required: required,
  available: available,
  builder: (_) => Material(
    key: contentKey,
    color: Colors.blue.shade100,
    child: SizedBox(
      height: 100,
      width: double.infinity,
      child: TextButton(onPressed: onTap ?? () {}, child: Text('业务$id')),
    ),
  ),
);

/// 将卡片放在真实外部滚动视图里，按需启用减少动画偏好。
Widget host({
  required List<DashboardCardDefinition> items,
  DashboardLayoutService? service,
  ScrollController? controller,
  ValueChanged<bool>? onEditingChanged,
  bool reduced = true,
  int? columns,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        disableAnimations: reduced,
        textScaler: textScaler,
      ),
      child: SingleChildScrollView(
        controller: controller,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: EditableCardBoard(
            storageId: 'home',
            items: items,
            service: service,
            scrollController: controller,
            columnCount: columns,
            onEditingChanged: onEditingChanged,
          ),
        ),
      ),
    ),
  ),
);

/// 用于确认散开绘制真正执行十二次分片，而非整体透明度动画。
class ShardCanvas extends Fake implements Canvas {
  int fragments = 0;

  /// 记录每个截图源矩形，其他画布变换由 Fake 忽略。
  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    fragments++;
  }

  /// 保存变换栈，测试仅统计分片绘制次数。
  @override
  void save() {}

  /// 恢复变换栈，测试仅统计分片绘制次数。
  @override
  void restore() {}

  /// 接受散片平移，不需要 GPU 渲染。
  @override
  void translate(double dx, double dy) {}

  /// 接受散片旋转，不需要 GPU 渲染。
  @override
  void rotate(double radians) {}
}

/// 模拟保存失败，验证卡片和顺序只在成功保存后改变。
class RejectingService extends DashboardLayoutService {
  /// 保留原有布局服务的加载逻辑，仅拒绝持久化。
  @override
  Future<void> save(String storageId, DashboardLayout layout) async {
    throw StateError('模拟拒绝保存');
  }
}

/// 在页面销毁前阻塞首笔写入，验证已经点击的多笔隐藏仍按顺序落盘。
class DelayedService extends DashboardLayoutService {
  final gate = Completer<void>();
  final accepted = <Set<String>>[];

  /// 先记录布局并等待测试放行，再交由真实服务持久化。
  @override
  Future<void> save(String storageId, DashboardLayout layout) async {
    accepted.add(layout.hidden);
    await gate.future;
    await super.save(storageId, layout);
  }
}

/// 覆盖编辑隔离、立即恢复、分片截图、拖动和外层边缘滚动。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// 编辑留白增高页面后底部按钮仍可点击，完成后的入口也由父滚动视图保持可见。
  testWidgets('编辑切换保持底部工具可达且无需传入滚动控制器', (tester) async {
    await tester.pumpWidget(
      host(items: [for (var i = 0; i < 8; i++) card('card-$i')], columns: 1),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('添加卡片').hitTestable(), findsOneWidget);
    expect(find.text('完成').hitTestable(), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('自定义').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑屏蔽业务动作，设置没有红叉且可向前移动', (tester) async {
    var clicks = 0;
    final edits = <bool>[];
    final service = DashboardLayoutService();
    await tester.pumpWidget(
      host(
        items: [
          card('a', onTap: () => clicks++),
          card('settings', required: true),
        ],
        service: service,
        onEditingChanged: edits.add,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('业务a'), warnIfMissed: false);
    expect(clicks, 1);
    await tester.tap(find.text('自定义'));
    await tester.pump();
    await tester.tap(find.text('业务a'), warnIfMissed: false);
    expect(clicks, 1);
    expect(find.byKey(const ValueKey('dashboard-hide-settings')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dashboard-menu-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dashboard-before-settings')));
    await tester.pumpAndSettle();
    expect((await service.load('home', [])).order, ['settings', 'a']);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(edits, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部隐藏后入口仍在，点加号立即保存并支持重进', (tester) async {
    final service = DashboardLayoutService();
    await tester.pumpWidget(host(items: [card('a')], service: service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dashboard-hide-a')));
    await tester.pumpAndSettle();
    expect(find.text('业务a'), findsNothing);
    expect(find.text('添加卡片'), findsOneWidget);
    await tester.tap(find.text('添加卡片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dashboard-add-a')));
    await tester.pumpAndSettle();
    expect((await service.load('home', [])).hidden, isEmpty);
    expect(find.text('所有卡片都已添加'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(items: [card('a')]));
    await tester.pumpAndSettle();
    expect(find.text('业务a'), findsOneWidget);
  });

  /// 添加落到末尾，恢复默认同时恢复顺序与隐藏项，并在重新读取后保持。
  testWidgets('添加卡片追加末尾并能恢复默认布局', (tester) async {
    final service = DashboardLayoutService();
    final items = [card('a'), card('b'), card('settings', required: true)];
    await service.save(
      'home',
      DashboardLayout(order: ['b', 'settings', 'a'], hidden: ['b']),
    );
    await tester.pumpWidget(host(items: items, service: service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加卡片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dashboard-add-b')));
    await tester.pumpAndSettle();
    expect((await service.load('home', items)).order, ['settings', 'a', 'b']);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dashboard-hide-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dashboard-reset-layout')));
    await tester.pumpAndSettle();
    final restored = await DashboardLayoutService().load('home', items);
    expect(restored.order, ['a', 'b', 'settings']);
    expect(restored.hidden, isEmpty);
    expect(find.text('业务a'), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-hide-settings')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('截图移除分成十二片，动画结束之前保持布局占位', (tester) async {
    final service = DashboardLayoutService();
    await tester.pumpWidget(
      host(
        items: [card('a'), card('b')],
        service: service,
        reduced: false,
        columns: 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump(const Duration(milliseconds: 20));
    final before = tester.getTopLeft(
      find.byKey(const ValueKey('dashboard-card-b')),
    );
    await tester.tap(find.byKey(const ValueKey('dashboard-hide-a')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 80));
    final painters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where(
          (widget) =>
              widget.painter.runtimeType.toString() == '_CardShardPainter',
        )
        .toList();
    expect(painters, hasLength(1));
    final canvas = ShardCanvas();
    painters.single.painter!.paint(canvas, const Size(300, 100));
    expect(canvas.fragments, 12);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('dashboard-card-b'))),
      before,
    );
    expect((await service.load('home', [])).hidden, {'a'});
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const ValueKey('dashboard-card-a')), findsNothing);
    expect((await service.load('home', [])).hidden, {'a'});
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败恢复旧卡片并显示提示', (tester) async {
    await tester.pumpWidget(
      host(items: [card('a')], service: RejectingService()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dashboard-hide-a')));
    await tester.pumpAndSettle();
    expect(find.text('业务a'), findsOneWidget);
    expect(find.text('卡片布局保存失败，请重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-hide-a')), findsOneWidget);
    expect((await DashboardLayoutService().load('home', [])).hidden, isEmpty);
  });

  testWidgets('点击连续隐藏后立即离开，重建等待写入并保留两个隐藏', (tester) async {
    final service = DelayedService();
    await tester.pumpWidget(
      host(items: [card('a'), card('b')], service: service, reduced: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dashboard-hide-a')));
    await tester.tap(find.byKey(const ValueKey('dashboard-hide-b')));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(items: [card('a'), card('b')]));
    await tester.pump();
    service.gate.complete();
    await tester.pumpAndSettle();
    expect(service.accepted, [
      <String>{'a'},
      <String>{'a', 'b'},
    ]);
    expect(find.text('业务a'), findsNothing);
    expect(find.text('业务b'), findsNothing);
    expect((await DashboardLayoutService().load('home', [])).hidden, {
      'a',
      'b',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('散开中条件卡不可用，恢复条件后仍保持已隐藏', (tester) async {
    final service = DashboardLayoutService();
    await tester.pumpWidget(
      host(items: [card('a')], service: service, reduced: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dashboard-hide-a')));
    await tester.pumpWidget(
      host(
        items: [card('a', available: false)],
        service: service,
        reduced: false,
      ),
    );
    await tester.pump();
    expect((await service.load('home', [])).hidden, {'a'});
    await tester.pumpWidget(
      host(items: [card('a')], service: service, reduced: false),
    );
    await tester.pump();
    expect(find.text('业务a'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体角落控件和顺序菜单不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(260, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(
      host(
        items: [card('a'), card('settings', required: true)],
        columns: 1,
        textScaler: const TextScaler.linear(2.4),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('dashboard-hide-a'))),
      const Size(44, 44),
    );
    await tester.tap(find.byKey(const ValueKey('dashboard-menu-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dashboard-before-settings')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面抓手即时鼠标拖动支持跨行重排', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final service = DashboardLayoutService();
    final contentKey = GlobalKey();
    await tester.pumpWidget(
      host(
        items: [
          card('a', contentKey: contentKey),
          card('b'),
          card('c'),
          card('settings', required: true),
        ],
        service: service,
        columns: 2,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    final start = tester.getCenter(
      find.byKey(const ValueKey('dashboard-drag-a')),
    );
    final target = tester.getCenter(
      find.byKey(const ValueKey('dashboard-card-c')),
    );
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump();
    expect(find.byKey(contentKey), findsOneWidget);
    expect(tester.takeException(), isNull);
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect((await service.load('home', [])).order, ['b', 'c', 'a', 'settings']);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('触摸长按整卡可重排，不依赖桌面抓手', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final service = DashboardLayoutService();
    await tester.pumpWidget(
      host(items: [card('a'), card('b')], service: service, columns: 1),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    expect(find.byKey(const ValueKey('dashboard-drag-a')), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('业务a')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('dashboard-card-b'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect((await service.load('home', [])).order, ['b', 'a']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('拖动靠近外层视口底部时自动滚动', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final controller = ScrollController();
    await tester.pumpWidget(
      host(
        items: [for (var i = 0; i < 20; i++) card('c$i')],
        controller: controller,
        columns: 2,
      ),
    );
    await tester.pumpAndSettle();
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pump();
    controller.jumpTo(0);
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('dashboard-drag-c0'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump();
    await gesture.moveTo(const Offset(400, 580));
    await tester.pump(const Duration(milliseconds: 240));
    expect(controller.offset, greaterThan(0));
    await gesture.up();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
