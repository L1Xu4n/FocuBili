import 'dart:convert';

import 'package:focubili/features/common/app_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

class _RejectSortWrite extends LearningListService {
  @override
  Future<void> saveNewestFirst(bool value) async {
    throw const LearningListStorageException();
  }
}

/// 为首页头像测试返回固定的已登录会话，不访问真实网络或设备 Cookie。
class _FixedAuthService extends BilibiliAuthService {
  /// 创建固定会话替身，便于验证首页只在有效登录时显示头像。
  _FixedAuthService(this.session);

  final BilibiliSessionState session;

  /// 返回测试指定的会话状态。
  @override
  Future<BilibiliSessionState> loadCurrentSession({
    bool forceRefresh = false,
  }) async => session;
}

/// 注册学习清单管理页和首页唯一继续学习任务的组件测试。
void main() {
  /// 每项测试开始前清空 SharedPreferences，防止学习任务影响其他测试。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 账号读取使用空内存容器，避免访问 Windows 凭据插件并留下超时计时器。
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('最近加入优先持久化，分组和搜索生效，且不会改手动顺序', (tester) async {
    final service = await _learningListService();
    final folder = (await service.createFolder('数学')).folders.single;
    final prefs = await SharedPreferences.getInstance();
    const storage = 'focubili_learning_list_v2';
    final snapshot = jsonDecode(prefs.getString(storage)!) as Map;
    LearningListEntry entry(
      int id,
      int day, {
      bool grouped = true,
      LearningListStatus status = LearningListStatus.notStarted,
    }) => LearningListEntry(
      bvid: 'BV1Learning$id',
      title: '数学视频 $id',
      ownerName: '测试 UP 主',
      thumbnailUrl: '',
      partCid: id,
      partPageNumber: 1,
      partTitle: '第 $id 节',
      position: Duration.zero,
      duration: const Duration(minutes: 1),
      status: status,
      addedAt: DateTime(2026, 11, day),
      updatedAt: DateTime(2026, 11, 19),
      sortOrder: id,
      folderId: grouped ? folder.id : null,
    );
    final old = entry(1, 1);
    final fresh = entry(2, 5);
    final tie = entry(3, 5);
    final outside = entry(4, 7, grouped: false);
    final completed = entry(5, 8, status: LearningListStatus.completed);
    snapshot['entries'] = [
      old,
      fresh,
      tie,
      outside,
      completed,
    ].map((e) => e.toJson()).toList();
    final original = jsonEncode(snapshot);
    await prefs.setString(storage, original);
    await tester.binding.setSurfaceSize(const Size(960, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> showPage() async {
      await tester.pumpWidget(
        MaterialApp(home: LearningListPage(learningListService: service)),
      );
      await tester.pumpAndSettle();
    }

    Finder row(LearningListEntry e) =>
        find.byKey(Key('learning-list-${e.stableId}'));
    void before(LearningListEntry a, LearningListEntry b) {
      expect(
        tester.getTopLeft(row(a)).dy,
        lessThan(tester.getTopLeft(row(b)).dy),
      );
    }

    Future<void> selectSort(String label) async {
      await tester.tap(find.byKey(const Key('learning-list-sort')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(CheckedPopupMenuItem<bool>),
        ),
      );
      await tester.pumpAndSettle();
    }

    await showPage();
    before(old, fresh);
    expect(find.byType(ReorderableDragStartListener), findsWidgets);
    await selectSort('最近加入优先');
    before(outside, fresh);
    before(fresh, tie);
    before(tie, old);
    before(old, completed);
    expect(find.byType(ReorderableDragStartListener), findsNothing);

    await tester.tap(find.byKey(Key('learning-folder-${folder.id}')));
    await tester.pumpAndSettle();
    expect(row(outside), findsNothing);
    before(fresh, old);
    await tester.tap(find.byKey(const Key('search-learning-list')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('learning-list-search-field')),
      '视频 1',
    );
    await tester.pumpAndSettle();
    expect(row(old), findsOneWidget);
    expect(row(fresh), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await showPage();
    before(fresh, old);
    expect(await service.loadNewestFirst(), isTrue);
    await selectSort('手动顺序');
    before(old, fresh);
    expect(await service.loadNewestFirst(), isFalse);
    expect(prefs.getString(storage), original);
  });

  testWidgets('窄屏大字设置排序失败时保留手动顺序', (tester) async {
    final service = _RejectSortWrite();
    await service.addVideo(_learningVideo());
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: LearningListPage(learningListService: service),
      ),
    );
    await tester.pumpAndSettle();
    final sort = find.byKey(const Key('learning-list-sort'));
    await tester.ensureVisible(sort);
    await tester.tap(sort);
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text('最近加入优先'),
        matching: find.byType(CheckedPopupMenuItem<bool>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未保存，请检查设备存储后重试'), findsOneWidget);
    expect(find.byTooltip('学习清单排序：手动顺序'), findsOneWidget);
    expect(await service.loadNewestFirst(), isFalse);
    expect(tester.takeException(), isNull);
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

  /// 一次明确的上拉展开卡片，下拉同样不需要等待中途停靠。
  testWidgets('首页卡片一次上拉打开一次下拉关闭', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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

    await tester.fling(scrollView, const Offset(0, 120), 2500);
    await tester.pumpAndSettle();
    final Rect returnedCardRect = tester.getRect(
      find.byKey(const Key('continue-learning-empty')),
    );
    expect(returnedCardRect.top, greaterThan(450));
  });

  /// 验证大幅上滑已经进入深层卡片时，不会被首次吸附拉回第一张卡片。
  testWidgets('首页大幅上滑保留深层卡片位置', (WidgetTester tester) async {
    // 短屏保留足够的深层滚动距离，同时让真实视口和 MediaQuery 尺寸一致。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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
    // 单次拖动从首屏穿过首张卡片，松手后应停在已抵达的列表深处。
    await tester.drag(scrollView, const Offset(0, -1300));
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
        matching: find.byType(AppNetworkImage),
      ),
      findsOneWidget,
    );
  });
}
