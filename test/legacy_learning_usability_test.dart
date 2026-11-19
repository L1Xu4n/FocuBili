import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_text_scale.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/player_focus_sheet.dart';
import 'package:focubili/features/learning/learning_add_sheet.dart';
import 'package:focubili/features/learning/learning_list_page.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'learning_add_sheet_test.dart' show partsVideo;
import 'learning_batch_test.dart' show video;

const _evidence = String.fromEnvironment('LEGACY_LEARNING_EVIDENCE');
const _evidenceFont = String.fromEnvironment('LEGACY_LEARNING_FONT');

Future<void> _loadEvidenceFont() async {
  if (_evidence.isEmpty) return;
  final font = File(_evidenceFont).readAsBytesSync();
  await (FontLoader(
    'LegacyLearningCjk',
  )..addFont(Future.value(ByteData.sublistView(font)))).load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String scene) async {
  if (_evidence.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_evidence/$scene.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _host(GlobalKey boundary, Widget home) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      fontFamily: _evidence.isEmpty ? null : 'LegacyLearningCjk',
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        // 200% app setting stacked with a modest 120% system setting.
        textScaler: const AppUiTextScaler(TextScaler.linear(1.2), 2),
      ),
      child: child!,
    ),
    home: home,
  ),
);

void _useCompactViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 480);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _loadEvidenceFont();
  });

  testWidgets('large batch picker can reach every part and its save action', (
    tester,
  ) async {
    _useCompactViewport(tester);
    final key = GlobalKey();
    final learning = LearningListService();
    final lesson = partsVideo();
    final folder = (await learning.createFolder(
      '高等数学 · 函数与极限、线性代数与复习资料',
    )).folders.single;
    await learning.addVideo(
      lesson,
      part: lesson.parts[1],
      position: const Duration(seconds: 41),
    );
    await tester.pumpWidget(
      _host(
        key,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                LearningAddSheet.show(
                  context,
                  video: lesson,
                  service: learning,
                ),
              ),
              child: const Text('打开分 P 选择'),
            ),
          ),
        ),
      ),
    );

    Future<void> open() async {
      await tester.tap(find.text('打开分 P 选择'));
      await tester.pumpAndSettle();
    }

    await open();
    await _capture(tester, key, '01-picker-open');
    expect(tester.takeException(), isNull);
    final all = find.text('全部 P');
    await tester.ensureVisible(all);
    await tester.pumpAndSettle();
    expect(all.hitTestable(), findsOneWidget);
    await tester.tap(all);
    await tester.pumpAndSettle();
    final folderPicker = find.byKey(const Key('add-learning-folder'));
    await tester.ensureVisible(folderPicker);
    await tester.pumpAndSettle();
    expect(folderPicker.hitTestable(), findsOneWidget);
    await tester.tap(folderPicker);
    await tester.pumpAndSettle();
    final folderOption = find.text(folder.name).last;
    await tester.tap(folderOption);
    await tester.pumpAndSettle();
    await _capture(tester, key, '02-picker-folder');
    final lastPart = find.widgetWithText(ListTile, 'P5 第5课');
    final parts = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    await tester.scrollUntilVisible(lastPart, 140, scrollable: parts.last);
    await tester.ensureVisible(lastPart);
    await tester.pumpAndSettle();
    expect(lastPart.hitTestable(), findsOneWidget);
    await tester.tap(lastPart);
    await tester.pumpAndSettle();
    await _capture(tester, key, '03-picker-last-part');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await learning.loadEntries()).length, 1);

    await open();
    await tester.tap(find.text('确认加入'));
    await tester.pumpAndSettle();
    final entries = await learning.loadEntries();
    expect(entries.map((entry) => entry.partCid), [102, 101]);
    expect(entries.first.position, const Duration(seconds: 41));
    expect(entries.every((entry) => entry.folderId == null), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large focus sheet remains usable with a keyboard and after reopen',
    (tester) async {
      _useCompactViewport(tester);
      addTearDown(tester.view.resetViewInsets);
      final key = GlobalKey();
      var now = DateTime(2026, 11, 18, 9);
      final controller = FocusTimerController(
        clock: () => now,
        tickInterval: const Duration(days: 1),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        _host(
          key,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (_) => FractionallySizedBox(
                      heightFactor: .78,
                      child: PlayerFocusSheet(
                        controller: controller,
                        defaultGoal: '复习函数与极限',
                        partRemainingDuration: const Duration(minutes: 12),
                        bvid: 'BVmath',
                        videoTitle: '高等数学：函数与极限',
                        partCid: 1,
                        partPageNumber: 1,
                        partTitle: '函数定义与连续性',
                      ),
                    ),
                  ),
                ),
                child: const Text('打开专注'),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('打开专注'));
        await tester.pumpAndSettle();
      }

      await open();
      await _capture(tester, key, '04-focus-open');
      expect(tester.takeException(), isNull);
      final goal = find.byKey(const Key('player-focus-goal'));
      await tester.ensureVisible(goal);
      await tester.pumpAndSettle();
      await tester.enterText(goal, '复习第一章及练习');
      tester.view.viewInsets = const FakeViewPadding(bottom: 185);
      await tester.pumpAndSettle();
      await _capture(tester, key, '05-focus-keyboard');
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final start = find.byKey(const Key('start-player-focus'));
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      final id = controller.activeSession!.id;
      expect(controller.activeSession!.goal, '复习第一章及练习');
      expect(controller.activeSession!.status, FocusSessionStatus.running);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      now = now.add(const Duration(minutes: 3));
      await open();
      expect(controller.activeSession!.id, id);
      expect(controller.elapsedDuration, const Duration(minutes: 3));
      final end = find.byKey(const Key('end-player-focus'));
      await tester.ensureVisible(end);
      await tester.pumpAndSettle();
      await _capture(tester, key, '06-focus-reopen');
      await tester.tap(end);
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续专注'));
      await tester.pumpAndSettle();
      expect(controller.activeSession!.id, id);
      expect(controller.history, isEmpty);
      expect(tester.takeException(), isNull);
      await controller.endFocusEarly();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('large folder rename can reject a duplicate, cancel and retry', (
    tester,
  ) async {
    _useCompactViewport(tester);
    addTearDown(tester.view.resetViewInsets);
    final key = GlobalKey();
    final learning = LearningListService();
    final folder = (await learning.createFolder('数学')).folders.single;
    await learning.createFolder('英语');
    await learning.addVideo(video(1), position: const Duration(seconds: 25));
    await learning.moveEntries({'BV1:1'}, folder.id);
    await tester.pumpWidget(
      _host(key, LearningListPage(learningListService: learning)),
    );
    await tester.pumpAndSettle();
    final chip = find.byKey(Key('learning-folder-${folder.id}'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    expect(chip.hitTestable(), findsOneWidget);
    await tester.tap(chip.hitTestable());
    await tester.pumpAndSettle();

    Future<void> rename() async {
      final manage = find.byKey(Key('manage-learning-folder-${folder.id}'));
      await tester.ensureVisible(manage);
      await tester.pumpAndSettle();
      expect(manage.hitTestable(), findsOneWidget);
      await tester.tap(manage.hitTestable());
      await tester.pumpAndSettle();
    }

    await rename();
    final name = find.byKey(const Key('learning-folder-name'));
    await tester.enterText(name, '英语');
    tester.view.viewInsets = const FakeViewPadding(bottom: 185);
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save-learning-folder'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    await tester.tap(save.hitTestable());
    await tester.pumpAndSettle();
    final duplicateName = find.text('已存在同名学科分组');
    expect(duplicateName, findsOneWidget);
    await tester.ensureVisible(duplicateName);
    await tester.pumpAndSettle();
    await _capture(tester, key, '07-duplicate-folder-keyboard');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect((await learning.loadState()).folders.first.name, '数学');

    await rename();
    await tester.enterText(name, '高等数学');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    await tester.tap(save.hitTestable());
    await tester.pumpAndSettle();
    final state = await learning.loadState();
    expect(state.folders.first.name, '高等数学');
    expect(state.folders.first.id, folder.id);
    expect(state.entries.single.folderId, folder.id);
    expect(state.entries.single.position, const Duration(seconds: 25));
    expect(tester.takeException(), isNull);
  });

  testWidgets('filtering multi-select keeps only visible learning tasks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final learning = LearningListService();
    await learning.addVideo(video(1));
    await learning.addVideo(video(2), status: LearningListStatus.learning);
    await tester.pumpWidget(
      MaterialApp(home: LearningListPage(learningListService: learning)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('多选管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择当前结果'));
    await tester.pumpAndSettle();
    expect(find.text('移除所选（2）'), findsOneWidget);
    final filter = find.widgetWithText(ChoiceChip, '学习中');
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-list-BV1:1')), findsNothing);
    expect(find.text('移除所选（1）'), findsOneWidget);
    await tester.tap(find.text('移除所选（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await learning.loadEntries()).length, 2);

    await tester.tap(find.byKey(const Key('search-learning-list')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('learning-list-search-field')),
      'no matching tasks',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '移除所选（0）'))
          .onPressed,
      isNull,
    );
    expect((await learning.loadEntries()).length, 2);
  });
}
