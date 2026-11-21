import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/player_focus_sheet.dart';
import 'package:focubili/features/learning/learning_list_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/learning_list_service.dart';

/// 仅使用合成课程生成布局证据；不连接真实账号、播放器或网络。
/// flutter test --dart-define=V19_EVIDENCE=true test/v19_focus_learning_evidence_test.dart
void main() {
  testWidgets('生成专注会话和学科分组的手机与桌面布局证据', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fontFile = File(r'C:\Windows\Fonts\msyh.ttc');
    if (fontFile.existsSync()) {
      final loader = FontLoader('EvidenceCJK')
        ..addFont(
          Future.value(ByteData.sublistView(fontFile.readAsBytesSync())),
        );
      await loader.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final boundaryKey = GlobalKey();
    Future<void> render(Widget page, Size size, String name) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'EvidenceCJK',
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('docs/v1.9/screenshots/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = LearningListService();
    for (var i = 1; i <= 3; i++) {
      await service.addVideo(
        VideoPreview(
          bvid: 'BVfixture$i',
          cid: i,
          title: ['高等数学：函数与极限', '英语听力：日常交流', '线性代数：矩阵基础'][i - 1],
          ownerName: '示例课程',
          parts: [
            VideoPart(
              pageNumber: 1,
              cid: i,
              title: '第一讲',
              duration: const Duration(minutes: 30),
            ),
          ],
        ),
      );
    }
    final folder = (await service.createFolder('数学')).folders.single;
    await service.createFolder('英语');
    await service.moveEntries({'BVfixture1:1', 'BVfixture3:3'}, folder.id);
    await render(
      LearningListPage(
        key: const ValueKey('phone'),
        learningListService: service,
      ),
      const Size(390, 844),
      'learning-folders-phone',
    );
    await render(
      LearningListPage(
        key: const ValueKey('desktop'),
        learningListService: service,
      ),
      const Size(1180, 820),
      'learning-folders-desktop',
    );
    final controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '完成函数与极限复习',
      duration: const Duration(minutes: 25),
    );
    await render(
      Scaffold(
        body: PlayerFocusSheet(
          controller: controller,
          defaultGoal: '完成函数与极限复习',
          partRemainingDuration: const Duration(minutes: 12),
          bvid: 'BVfixture1',
          videoTitle: '高等数学：函数与极限',
          partCid: 1,
          partPageNumber: 1,
          partTitle: '第一讲',
        ),
      ),
      const Size(390, 844),
      'focus-session-phone',
    );
    await controller.endFocusEarly();
    await tester.pump();
  }, skip: !const bool.fromEnvironment('V19_EVIDENCE'));
}
