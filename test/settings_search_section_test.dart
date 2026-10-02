import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/settings_search_section.dart';

/// 核验完全没有登记别名的新设置，也能按可见标题与说明搜索且可点击。
void main() {
  testWidgets('未配置关键词的新设置自动按标题和说明命中', (tester) async {
    var clicked = 0;
    for (final query in ['未来新增选项', '自动整理学习任务']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsSearchSection(
              icon: Icons.settings,
              title: '测试分类',
              query: query,
              children: [
                ListTile(
                  key: const Key('unregistered-new-setting'),
                  title: const Text('未来新增选项'),
                  subtitle: const Text('开启后自动整理学习任务'),
                  onTap: () => clicked++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unregistered-new-setting')), findsOneWidget);
      await tester.tap(find.byKey(const Key('unregistered-new-setting')));
    }
    expect(clicked, 2);
  });
}
