import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/features/profile/watch_history_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/watch_history_service.dart';

/// 创建页面测试使用的本机观看记录。
WatchHistoryEntry _entry({
  String bvid = 'BV1GJ411x7h7',
  String title = '本机保存的视频标题',
  int part = 2,
  DateTime? watchedAt,
  String thumbnailUrl =
      'https://i0.hdslb.com/bfs/archive/existing-history-cover.jpg',
  Duration lastPosition = Duration.zero,
}) {
  return WatchHistoryEntry(
    bvid: bvid,
    title: title,
    ownerName: '测试 UP 主',
    lastPartTitle: '第 $part P 的测试标题',
    lastPartPageNumber: part,
    watchedAt: watchedAt ?? DateTime(2026, 7, 15, 12, 34),
    thumbnailUrl: thumbnailUrl,
    lastPosition: lastPosition,
  );
}

/// 创建测试时可控制读写结果的内存观看记录服务。
class _FakeWatchHistoryService extends WatchHistoryService {
  /// 创建具有初始记录、可选加载失败或等待加载行为的假服务。
  _FakeWatchHistoryService(
    List<WatchHistoryEntry> entries, {
    this.throwWhenLoading = false,
    this.pendingLoad,
  }) : _entries = List<WatchHistoryEntry>.from(entries);

  List<WatchHistoryEntry> _entries;
  final bool throwWhenLoading;
  final Completer<List<WatchHistoryEntry>>? pendingLoad;
  final List<String> removeRequests = <String>[];
  bool clearRequested = false;
  Map<String, String> backfilledThumbnails = const <String, String>{};

  /// 返回测试配置的列表、异常或尚未完成的加载 Future。
  @override
  Future<List<WatchHistoryEntry>> loadHistory() async {
    if (throwWhenLoading) {
      throw StateError('测试读取失败');
    }
    if (pendingLoad != null) {
      return pendingLoad!.future;
    }
    return List<WatchHistoryEntry>.unmodifiable(_entries);
  }

  /// 记录移除请求并返回去除对应 BV 后的内存列表。
  @override
  Future<List<WatchHistoryEntry>> remove(String bvid) async {
    removeRequests.add(bvid);
    _entries = _entries
        .where((WatchHistoryEntry entry) => entry.bvid != bvid)
        .toList(growable: false);
    return List<WatchHistoryEntry>.unmodifiable(_entries);
  }

  /// 记录清空请求并把测试内存列表替换为空列表。
  @override
  Future<List<WatchHistoryEntry>> clear() async {
    clearRequested = true;
    _entries = const <WatchHistoryEntry>[];
    return _entries;
  }

  /// 模拟旧记录封面批量补写，并保持测试列表顺序与其他字段不变。
  @override
  Future<List<WatchHistoryEntry>> backfillThumbnails(
    Map<String, String> thumbnailUrls,
  ) async {
    backfilledThumbnails = Map<String, String>.from(thumbnailUrls);
    _entries = _entries
        .map(
          (WatchHistoryEntry entry) => entry.thumbnailUrl.isEmpty &&
                  thumbnailUrls.containsKey(entry.bvid)
              ? entry.copyWith(thumbnailUrl: thumbnailUrls[entry.bvid])
              : entry,
        )
        .toList(growable: false);
    return List<WatchHistoryEntry>.unmodifiable(_entries);
  }
}

/// 创建测试用的视频查询服务，避免页面测试访问真实网络。
class _FakeBilibiliService implements BilibiliService {
  /// 创建按 BV 返回预览或抛出指定异常的测试服务。
  _FakeBilibiliService({this.preview, this.error});

  final VideoPreview? preview;
  final Object? error;
  final List<String> lookupRequests = <String>[];

  /// 记录请求的 BV 号并返回配置好的视频详情或错误。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookupRequests.add(input);
    if (error != null) {
      throw error!;
    }
    return preview!;
  }

  /// 页面测试不涉及搜索，因此返回一个空搜索页。
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    return VideoSearchPage(
      results: const <VideoSearchResult>[],
      page: page,
      totalPages: page,
    );
  }

  /// 页面测试不涉及候选词，因此固定返回空列表。
  @override
  Future<List<String>> suggestKeywords(String input) async {
    return const <String>[];
  }
}

/// 记录导航事件，便于断言页面向播放器传递了正确的视频参数。
class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushedRoutes = <Route<dynamic>>[];

  /// 保存每次被推入导航栈的路由，供测试检查路由名和参数。
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    pushedRoutes.add(route);
  }
}

/// 构建供导航断言使用的播放器占位目的地。
Widget _buildPlayerDestination(BuildContext context) {
  return const Scaffold(body: Text('播放器测试目的地'));
}

/// 为测试中的命名路由创建一个简单的页面目的地。
Route<dynamic> _buildTestRoute(RouteSettings settings) {
  return MaterialPageRoute<void>(
    settings: settings,
    builder: _buildPlayerDestination,
  );
}

/// 创建包含页面、测试服务和可选导航观察器的 Material 测试宿主。
Widget _buildTestApp({
  required WatchHistoryService historyService,
  required BilibiliService bilibiliService,
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
  Key? pageKey,
}) {
  return MaterialApp(
    home: WatchHistoryPage(
      key: pageKey,
      historyService: historyService,
      bilibiliService: bilibiliService,
    ),
    onGenerateRoute: _buildTestRoute,
    navigatorObservers: observers,
  );
}

/// 验证本机观看记录页面的状态、删除确认和重新打开视频行为。
void main() {
  /// 验证页面展示本机范围说明、封面、观看位置、日期字段和空状态。
  testWidgets('显示本机说明、记录内容和空状态', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const String thumbnailUrl =
        'https://i0.hdslb.com/bfs/archive/watch-history-cover.jpg';
    final _FakeWatchHistoryService historyService = _FakeWatchHistoryService(
      <WatchHistoryEntry>[
        _entry(
          thumbnailUrl: thumbnailUrl,
          lastPosition: const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
      ],
    );
    final _FakeBilibiliService bilibiliService = _FakeBilibiliService(
      preview: VideoPreview.placeholder(),
    );

    await tester.pumpWidget(
      _buildTestApp(
        historyService: historyService,
        bilibiliService: bilibiliService,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本机观看记录'), findsOneWidget);
    expect(find.textContaining('仅保存在本机'), findsOneWidget);
    expect(find.text('本机保存的视频标题'), findsOneWidget);
    expect(find.textContaining('上次看至 P2'), findsOneWidget);
    expect(find.textContaining('上次观看：2026-07-15 12:34'), findsOneWidget);
    expect(find.text('已看 1:02:03'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is CachedNetworkImage && widget.imageUrl == thumbnailUrl,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('移除记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(historyService.removeRequests, <String>['BV1GJ411x7h7']);
    expect(find.text('还没有本机观看记录'), findsOneWidget);
    expect(find.textContaining('仅保存在本机'), findsOneWidget);
  });

  /// 验证升级前没有封面的记录会受控补查详情，并把封面写回本机服务和当前列表。
  testWidgets('旧观看记录会自动补齐缺失缩略图', (WidgetTester tester) async {
    const String thumbnailUrl =
        'https://i0.hdslb.com/bfs/archive/backfilled-history-cover.jpg';
    final _FakeWatchHistoryService historyService = _FakeWatchHistoryService(
      <WatchHistoryEntry>[_entry(thumbnailUrl: '')],
    );
    final VideoPreview preview = VideoPreview(
      bvid: VideoPreview.placeholder().bvid,
      cid: VideoPreview.placeholder().cid,
      title: VideoPreview.placeholder().title,
      ownerName: VideoPreview.placeholder().ownerName,
      thumbnailUrl: thumbnailUrl,
      parts: VideoPreview.placeholder().parts,
    );
    final _FakeBilibiliService bilibiliService =
        _FakeBilibiliService(preview: preview);

    await tester.pumpWidget(
      _buildTestApp(
        historyService: historyService,
        bilibiliService: bilibiliService,
      ),
    );
    await tester.pumpAndSettle();

    expect(bilibiliService.lookupRequests, <String>['BV1GJ411x7h7']);
    expect(
      historyService.backfilledThumbnails,
      <String, String>{'BV1GJ411x7h7': thumbnailUrl},
    );
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is CachedNetworkImage && widget.imageUrl == thumbnailUrl,
      ),
      findsOneWidget,
    );
  });

  /// 验证清空操作必须确认，确认后只清空页面注入的本机服务。
  testWidgets('清空全部本机记录需要确认', (WidgetTester tester) async {
    final _FakeWatchHistoryService historyService =
        _FakeWatchHistoryService(<WatchHistoryEntry>[_entry()]);
    final _FakeBilibiliService bilibiliService = _FakeBilibiliService(
      preview: VideoPreview.placeholder(),
    );

    await tester.pumpWidget(
      _buildTestApp(
        historyService: historyService,
        bilibiliService: bilibiliService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(historyService.clearRequested, isFalse);
    await tester.tap(find.text('确认清空'));
    await tester.pumpAndSettle();

    expect(historyService.clearRequested, isTrue);
    expect(find.text('还没有本机观看记录'), findsOneWidget);
  });

  /// 验证点击记录会查询对应 BV 并向播放器命名路由传递 VideoPreview。
  testWidgets('点击本机记录会查询详情并进入播放器', (WidgetTester tester) async {
    final WatchHistoryEntry entry = _entry();
    final VideoPreview preview = VideoPreview.placeholder();
    final _FakeWatchHistoryService historyService =
        _FakeWatchHistoryService(<WatchHistoryEntry>[entry]);
    final _FakeBilibiliService bilibiliService =
        _FakeBilibiliService(preview: preview);
    final _RecordingNavigatorObserver observer = _RecordingNavigatorObserver();

    await tester.pumpWidget(
      _buildTestApp(
        historyService: historyService,
        bilibiliService: bilibiliService,
        observers: <NavigatorObserver>[observer],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('watch-history-BV1GJ411x7h7')));
    await tester.pumpAndSettle();

    expect(bilibiliService.lookupRequests, <String>[entry.bvid]);
    expect(observer.pushedRoutes.last.settings.name, AppRoutes.player);
    expect(observer.pushedRoutes.last.settings.arguments, same(preview));
  });

  /// 验证查询失败时不删除记录，并显示持续三秒的错误提示。
  testWidgets('查询失败会保留记录并显示三秒提示', (WidgetTester tester) async {
    final _FakeWatchHistoryService historyService =
        _FakeWatchHistoryService(<WatchHistoryEntry>[_entry()]);
    final _FakeBilibiliService bilibiliService = _FakeBilibiliService(
      error: const BilibiliLookupException('测试查询失败'),
    );

    await tester.pumpWidget(
      _buildTestApp(
        historyService: historyService,
        bilibiliService: bilibiliService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('watch-history-BV1GJ411x7h7')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('watch-history-BV1GJ411x7h7')), findsOneWidget);
    expect(find.text('测试查询失败'), findsOneWidget);
    final SnackBar snackBar = tester.widget(find.byType(SnackBar));
    expect(snackBar.duration, const Duration(seconds: 3));
  });

  /// 验证未完成的本机读取显示加载状态，异常读取显示可重试错误状态。
  testWidgets('显示加载和读取失败状态', (WidgetTester tester) async {
    final Completer<List<WatchHistoryEntry>> pendingLoad =
        Completer<List<WatchHistoryEntry>>();
    final _FakeBilibiliService bilibiliService = _FakeBilibiliService(
      preview: VideoPreview.placeholder(),
    );

    await tester.pumpWidget(
      _buildTestApp(
        historyService: _FakeWatchHistoryService(
          const <WatchHistoryEntry>[],
          pendingLoad: pendingLoad,
        ),
        bilibiliService: bilibiliService,
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pendingLoad.complete(const <WatchHistoryEntry>[]);
    await tester.pumpAndSettle();
    expect(find.text('还没有本机观看记录'), findsOneWidget);

    await tester.pumpWidget(
      _buildTestApp(
        historyService: _FakeWatchHistoryService(
          const <WatchHistoryEntry>[],
          throwWhenLoading: true,
        ),
        bilibiliService: bilibiliService,
        pageKey: const ValueKey<String>('error-page'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('读取本机观看记录失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
