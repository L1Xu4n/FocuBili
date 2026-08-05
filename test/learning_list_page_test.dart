import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/focus/focus_timer_scope.dart';
import 'package:focubili/features/home/home_page.dart';
import 'package:focubili/features/learning/learning_list_page.dart';
import 'package:focubili/features/shell/main_shell.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
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

/// 创建两P测试视频，验证页面可以把同一 BV 的不同分 P 独立展示、搜索和分区。
VideoPreview _multiPartLearningVideo() {
  return const VideoPreview(
    bvid: 'BV1Learning4',
    cid: 4001,
    title: '多P学习清单测试',
    ownerName: '测试 UP 主',
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 4001,
        title: '第一节',
        duration: Duration(minutes: 4),
      ),
      VideoPart(
        pageNumber: 2,
        cid: 4002,
        title: '第二节',
        duration: Duration(minutes: 5),
      ),
    ],
  );
}

/// 创建使用当前测试内存偏好设置的学习清单服务。
Future<LearningListService> _learningListService() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  return LearningListService(preferencesLoader: () async => preferences);
}

/// 为首页头像测试返回固定的已登录会话，不访问真实网络或设备 Cookie。
class _FixedAuthService extends BilibiliAuthService {
  /// 创建固定会话替身，便于验证首页只在有效登录时显示头像。
  _FixedAuthService(this.session);

  final BilibiliSessionState session;

  /// 返回测试指定的会话状态。
  @override
  Future<BilibiliSessionState> loadCurrentSession() async => session;
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
      find.byKey(Key('learning-list-${_learningVideo().bvid}:2001')),
      findsOneWidget,
    );
    expect(find.text('未开始'), findsWidgets);
    await tester.tap(
      find.byKey(Key('learning-status-${_learningVideo().bvid}:2001')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习中').last);
    await tester.pumpAndSettle();

    expect(
      (await service.loadEntries()).single.status,
      LearningListStatus.learning,
    );
  });

  testWidgets('学习清单可搜索分P，已完成分P会自动移到列表末尾', (WidgetTester tester) async {
    final LearningListService service = await _learningListService();
    final VideoPreview video = _multiPartLearningVideo();
    await service.addVideo(video, part: video.parts.first);
    await service.addVideo(video, part: video.parts.last);
    await tester.pumpWidget(
      MaterialApp(home: LearningListPage(learningListService: service)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('P1 第一节'), findsOneWidget);
    expect(find.textContaining('P2 第二节'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-learning-list')));
    await tester.pump();
    final Finder searchField = find.byKey(
      const Key('learning-list-search-field'),
    );
    final TextField searchInput = tester.widget<TextField>(searchField);
    expect(searchInput.decoration?.filled, isTrue);
    expect(
      searchInput.decoration?.fillColor,
      Theme.of(tester.element(searchField)).scaffoldBackgroundColor,
    );
    await tester.enterText(searchField, '第二节');
    await tester.pump();
    expect(find.textContaining('P1 第一节'), findsNothing);
    expect(find.textContaining('P2 第二节'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-learning-list')));
    await tester.pump();

    await tester.tap(
      find.byKey(Key('learning-status-${video.bvid}:${video.parts.last.cid}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已完成').last);
    await tester.pumpAndSettle();

    expect(find.text('已完成（1）'), findsOneWidget);
    final Rect firstPartBounds = tester.getRect(
      find.byKey(Key('learning-list-${video.bvid}:${video.parts.first.cid}')),
    );
    final Rect completedPartBounds = tester.getRect(
      find.byKey(Key('learning-list-${video.bvid}:${video.parts.last.cid}')),
    );
    expect(completedPartBounds.top, greaterThan(firstPartBounds.bottom));
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

  /// 验证主框架发出新的首页刷新代次后，会读取其他页面刚加入的学习任务。
  testWidgets('切回首页会刷新刚加入的学习任务', (WidgetTester tester) async {
    final LearningListService service = await _learningListService();
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
            refreshGeneration: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue-learning-empty')), findsOneWidget);

    await service.addVideo(_learningVideo());
    await tester.pumpWidget(
      MaterialApp(
        home: FocusTimerScope(
          controller: focusController,
          child: HomePage(
            onSearchRequested: () {},
            learningListService: service,
            refreshGeneration: 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('continue-learning-card')), findsOneWidget);
    expect(find.text('首页继续学习测试'), findsOneWidget);
  });

  /// 验证首页一次上滑会把首屏吸附到卡片区，而不是停在半屏位置。
  testWidgets('首页首屏上滑后吸附到卡片区', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final LearningListService service = await _learningListService();
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
            onProfileRequested: () {},
            learningListService: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder scrollView = find.byType(CustomScrollView);
    await tester.drag(scrollView, const Offset(0, -260));
    await tester.pumpAndSettle();

    final Rect cardRect = tester.getRect(
      find.byKey(const Key('continue-learning-empty')),
    );
    expect(cardRect.top, lessThan(110));

    // 轻微下滑只保留自然位移，不应立即把所有卡片推回屏幕底部。
    await tester.drag(scrollView, const Offset(0, 40));
    await tester.pumpAndSettle();
    final Rect slightDownRect = tester.getRect(
      find.byKey(const Key('continue-learning-empty')),
    );
    expect(slightDownRect.top, lessThan(180));

    // 验证反向手势会播放回到首屏的完整吸附动画，而不是停在半屏位置。
    await tester.drag(scrollView, const Offset(0, 180));
    await tester.pumpAndSettle();
    final Rect returnedCardRect = tester.getRect(
      find.byKey(const Key('continue-learning-empty')),
    );
    expect(returnedCardRect.top, greaterThan(450));
  });

  /// 验证大幅上滑已经进入深层卡片时，不会被首次吸附拉回第一张卡片。
  testWidgets('首页大幅上滑保留深层卡片位置', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final LearningListService service = await _learningListService();
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
            onProfileRequested: () {},
            learningListService: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder scrollView = find.byType(CustomScrollView);
    await tester.drag(scrollView, const Offset(0, -900));
    await tester.pumpAndSettle();

    final Rect firstCardRect = tester.getRect(
      find.byKey(const Key('continue-learning-empty')),
    );
    final Rect summaryRect = tester.getRect(
      find.byKey(const Key('focus-today-summary')),
    );
    expect(firstCardRect.top, lessThan(-8));
    expect(summaryRect.top, lessThan(600));
  });

  /// 验证浅色和深色首页动作按钮都使用应用主题主色，右上角只绘制图标。
  testWidgets('首页动作按钮跟随主题色', (WidgetTester tester) async {
    final LearningListService service = await _learningListService();
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();

    for (final ThemeData theme in <ThemeData>[
      AppTheme.light(),
      AppTheme.dark(),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: FocusTimerScope(
            controller: focusController,
            child: HomePage(
              onSearchRequested: () {},
              onProfileRequested: () {},
              learningListService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final FilledButton searchButton = tester.widget<FilledButton>(
        find.byKey(const Key('home-start-search')),
      );
      final IconButton profileButton = tester.widget<IconButton>(
        find.byKey(const Key('home-profile-button')),
      );
      expect(
        searchButton.style?.backgroundColor?.resolve(<WidgetState>{}),
        theme.colorScheme.primary,
      );
      expect(
        profileButton.style?.backgroundColor?.resolve(<WidgetState>{}),
        theme.colorScheme.primary,
      );
      expect(profileButton.icon, isA<Icon>());
    }
  });

  /// 验证点击个人入口时只播放首页到“我的”的直接动画，不短暂展示搜索页。
  testWidgets('首页进入我的不会经过搜索页', (WidgetTester tester) async {
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: FocusTimerScope(
          controller: focusController,
          child: const MainShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-profile-button')));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byKey(const Key('profile-back-button')), findsOneWidget);
    expect(find.byKey(const Key('search-back-button')), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-back-button')), findsOneWidget);
  });

  /// 验证有效账号的头像地址会替换首页右上角的默认人物图标。
  testWidgets('已登录用户首页显示头像', (WidgetTester tester) async {
    final LearningListService service = await _learningListService();
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    final _FixedAuthService authService = _FixedAuthService(
      const BilibiliSessionState.active(
        BilibiliAccount(
          mid: 123,
          name: '测试账号',
          avatarUrl: 'https://example.com/avatar.png',
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: FocusTimerScope(
          controller: focusController,
          child: HomePage(
            onSearchRequested: () {},
            onProfileRequested: () {},
            learningListService: service,
            authService: authService,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final IconButton profileButton = tester.widget<IconButton>(
      find.byKey(const Key('home-profile-button')),
    );
    expect(profileButton.icon, isA<ClipOval>());
    expect(
      find.descendant(
        of: find.byKey(const Key('home-profile-button')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });
}
