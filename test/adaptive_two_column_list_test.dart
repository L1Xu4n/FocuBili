import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/core/layout/adaptive_two_column_list.dart';

/// 构建使用真实 Material 约束的响应式列表测试宿主。
Widget _host() {
  return MaterialApp(
    home: Scaffold(
      body: AdaptiveTwoColumnList(
        key: const Key('adaptive-test-list'),
        itemCount: 3,
        header: const SizedBox(key: Key('adaptive-test-header'), height: 36),
        footer: const SizedBox(key: Key('adaptive-test-footer'), height: 24),
        padding: const EdgeInsets.all(16),
        // 条目构建函数生成固定高度卡片，方便测试精确比较横纵坐标。
        itemBuilder: (BuildContext context, int index) => SizedBox(
          key: Key('adaptive-test-item-$index'),
          height: 80,
          child: Card(child: Center(child: Text('项目 $index'))),
        ),
      ),
    ),
  );
}

/// 验证通用列表根据窗口宽度切换双列与单列，而不依赖运行平台。
void main() {
  /// 宽窗口把前两项放在同一行，第三项和分页尾部依次位于后续整行。
  testWidgets('宽窗口使用双列并让分页尾部横跨整行', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host());

    final Rect first = tester.getRect(
      find.byKey(const Key('adaptive-test-item-0')),
    );
    final Rect header = tester.getRect(
      find.byKey(const Key('adaptive-test-header')),
    );
    final Rect second = tester.getRect(
      find.byKey(const Key('adaptive-test-item-1')),
    );
    final Rect third = tester.getRect(
      find.byKey(const Key('adaptive-test-item-2')),
    );
    final Rect footer = tester.getRect(
      find.byKey(const Key('adaptive-test-footer')),
    );
    expect(first.top, second.top);
    expect(second.left, greaterThan(first.right));
    expect(first.top, greaterThan(header.bottom));
    expect(header.width, greaterThan(first.width));
    expect(third.top, greaterThan(first.bottom));
    expect(footer.top, greaterThan(third.bottom));
  });

  /// 窄窗口保持原有单列阅读顺序，避免手机卡片被压成过窄的两栏。
  testWidgets('窄窗口保持单列', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host());

    final Rect first = tester.getRect(
      find.byKey(const Key('adaptive-test-item-0')),
    );
    final Rect second = tester.getRect(
      find.byKey(const Key('adaptive-test-item-1')),
    );
    expect(second.top, greaterThan(first.bottom));
    expect(second.left, first.left);
    expect(second.width, first.width);
  });
}
