import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/search/search_video_row.dart';

/// 使用真实结果行和 Material 菜单，隔离网络以核验触达与键盘行为。
Widget _host({
  required VoidCallback onOpen,
  double scale = 1,
  bool dark = false,
}) => MaterialApp(
  theme: dark ? AppTheme.dark() : AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: ListView(
      children: [
        SearchVideoRow(
          rowKey: const Key('video-result'),
          title: '操作系统：进程与线程',
          owner: '公开课程',
          publishedAt: '2026-11-18',
          playCount: '1.2万',
          danmakuCount: '240',
          thumbnailBuilder: (width) =>
              SizedBox(width: width, height: width * 9 / 16),
          onTap: onOpen,
          menu: PopupMenuButton<String>(
            key: const Key('video-menu'),
            tooltip: '更多选项',
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert_rounded, size: 18),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'save', child: Text('加入学习清单')),
            ],
          ),
        ),
      ],
    ),
  ),
);

void main() {
  for (final width in [320.0, 390.0, 1200.0]) {
    for (final dark in [false, true]) {
      testWidgets('结果菜单48dp边缘可点击 $width ${dark ? '深色' : '浅色'}', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final semantics = tester.ensureSemantics();
        var opened = 0;
        await tester.pumpWidget(
          _host(
            onOpen: () => opened++,
            scale: width == 320 ? 2 : 1,
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        final menu = find.byKey(const Key('video-menu'));
        final rect = tester.getRect(menu);
        expect(find.byTooltip('更多选项'), findsOneWidget);
        expect(tester.getSemantics(find.byType(IconButton)).tooltip, '更多选项');
        semantics.dispose();
        expect(
          tester.widget<Icon>(find.byIcon(Icons.more_vert_rounded)).size,
          18,
        );
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        await tester.tapAt(rect.topLeft + const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(find.text('加入学习清单'), findsOneWidget);
        expect(opened, 0, reason: '菜单边缘不应触发父级播放');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('加入学习清单'), findsNothing);
        await tester.tap(find.text('操作系统：进程与线程'));
        expect(opened, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('键盘可打开、取消并再次打开结果菜单', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_host(onOpen: () => opened++));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('加入学习清单'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('加入学习清单'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('加入学习清单'), findsOneWidget);
    expect(opened, 0);
  });
}
