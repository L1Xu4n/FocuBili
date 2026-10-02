import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/widgets/player_note_tile.dart';

/// 构建真实受限尺寸与大字体环境，独立验证笔记列表而不启动播放器服务。
Future<void> _pumpNoteList(
  WidgetTester tester, {
  required Size viewport,
  required bool horizontal,
}) async {
  await tester.binding.setSurfaceSize(viewport);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: viewport,
          textScaler: TextScaler.linear(1.6),
        ),
        child: Scaffold(
          body: Builder(
            // 构建函数在 Material 默认文字样式下测量卡片，与播放器保持一致。
            builder: (BuildContext context) {
              final Size tileSize = measurePlayerNoteStripTile(
                context,
                title: '多分P长章节标题：这是需要完整提示的笔记',
                positionLabel: '123:45:56',
                partLabel: 'P123',
              );
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: horizontal ? viewport.width : viewport.width * 0.17,
                  height: horizontal ? tileSize.height : viewport.height - 70,
                  child: ListView.separated(
                    scrollDirection: horizontal
                        ? Axis.horizontal
                        : Axis.vertical,
                    itemCount: 12,
                    // 分隔函数保留与笔记工作区相同的卡片间距。
                    separatorBuilder: (BuildContext context, int index) =>
                        SizedBox(
                          width: horizontal ? 8 : 0,
                          height: horizontal ? 0 : 6,
                        ),
                    // 卡片构建函数保留长时长和多分P文字并连接可观察的选择回调。
                    itemBuilder: (BuildContext context, int index) => SizedBox(
                      width: horizontal ? tileSize.width : null,
                      child: PlayerNoteTile(
                        title: '多分P长章节标题：这是需要完整提示的笔记',
                        positionLabel: '123:45:56',
                        partLabel: 'P123',
                        horizontal: horizontal,
                        selected: index == 0,
                        tapKey: Key('note-$index'),
                        // 点击函数记录选择事件，模拟工作区只选择而不触发播放命令。
                        onTap: () => _selectedNotes.add(index),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

final List<int> _selectedNotes = <int>[];

/// 验证大字体下横向卡片可读可选、竖向窄列表可自然增高并滚动。
void main() {
  // 初始化函数清空上一用例的选择记录，保持验证相互独立。
  setUp(() => _selectedNotes.clear());

  testWidgets('320宽1.6倍字体横向笔记保留时间分P且可以选择和滚动', (WidgetTester tester) async {
    await _pumpNoteList(
      tester,
      viewport: const Size(320, 640),
      horizontal: true,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('123:45:56'), findsWidgets);
    expect(find.text('P123'), findsWidgets);
    expect(find.byTooltip('多分P长章节标题：这是需要完整提示的笔记'), findsWidgets);
    await tester.tap(find.byKey(const Key('note-0')));
    expect(_selectedNotes, <int>[0]);
    await tester.drag(find.byType(ListView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('note-0')), findsNothing);
  });

  for (final Size viewport in <Size>[
    const Size(780, 320),
    const Size(1000, 260),
  ]) {
    testWidgets('1.6倍字体竖向笔记在${viewport.width}x${viewport.height}窄列中自然增高', (
      WidgetTester tester,
    ) async {
      await _pumpNoteList(tester, viewport: viewport, horizontal: false);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('note-0')));
      expect(_selectedNotes, <int>[0]);
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('note-0')), findsNothing);
    });
  }
}
