import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/focus_timer_scope.dart';
import 'package:focubili/features/home/home_page.dart';
import 'package:focubili/features/learning/learning_list_page.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/learning_list_service.dart';

/// 创建没有远程封面的单P测试视频，保证清单页面测试不依赖网络图片加载。
VideoPreview _learningVideo() {
  return const VideoPreview(
    bvid: 'BV1Learning2',
    cid: 2001,
    title: '首页继续学习测试',
    ownerName: '测试 UP 主',
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 2001,
        title: '第一节',
        duration: Duration(minutes: 8),
      ),
    ],
  );
}

/// 创建使用当前测试内存偏好设置的学习清单服务。
Future<LearningListService> _learningListService() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return LearningListService(preferencesLoader: () async => preferences);
}

/// 注册学习清单管理页和首页唯一继续学习任务的组件测试。
void main() {
  /// 每项测试开始前清空 SharedPreferences，防止学习任务影响其他测试。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('学习清单页面可以切换未开始、学习中和已完成状态', (WidgetTester tester) async {
    final LearningListService service = await _learningListService();
    await service.addVideo(_learningVideo());
    await tester.pumpWidget(
      MaterialApp(home: LearningListPage(learningListService: service)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(Key('learning-list-${_learningVideo().bvid}')),
      findsOneWidget,
    );
    expect(find.text('未开始'), findsWidgets);
    await tester.tap(
      find.byKey(Key('learning-status-${_learningVideo().bvid}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习中').last);
    await tester.pumpAndSettle();

    expect(
      (await service.loadEntries()).single.status,
      LearningListStatus.learning,
    );
  });

  testWidgets('首页继续学习只突出当前的一条学习任务', (WidgetTester tester) async {
    final LearningListService service = await _learningListService();
    await service.addVideo(_learningVideo());
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: FocusTimerScope(
          controller: focusController,
          child: HomePage(
            onSearchRequested: () {},
            learningListService: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('continue-learning-card')), findsOneWidget);
    expect(find.text('首页继续学习测试'), findsOneWidget);
    expect(find.byKey(const Key('home-continue-learning')), findsOneWidget);
  });
}
