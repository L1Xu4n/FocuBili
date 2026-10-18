import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/subscriptions/subscription_history_page.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/subscription_history.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'subscription_background_test.dart' show AtomicSnapshots;
import 'subscription_compact_ui_test.dart'
    show loadBetaReviewFonts, captureSubscriptionUi;
import 'refactor_r3_feedback_test.dart' show video;
import 'support/subscription_public_pages.dart';

class Videos implements BilibiliService {
  final calls = <String>[];
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    calls.add(input);
    return video;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final source = SubscriptionSource(
    kind: SubscriptionKind.creator,
    mid: 1,
    name: '数学与日常 · 从基础开始的完整系列课程',
    token: '1',
  );
  Future<SubscriptionService> create(
    PublicPages api,
    AtomicSnapshots store,
  ) async {
    final service = SubscriptionService(
      snapshotStore: store,
      contentService: BilibiliHttpPublicContentService(requestJson: api.call),
    );
    addTearDown(service.dispose);
    await service.initialize();
    if (service.sources.isEmpty) await service.addSource(source);
    await service.setEnabled(true);
    service.setForeground(true);
    await service.refresh();
    return service;
  }

  testWidgets(
    'history import, pause, resume and navigation remain separate from live unread',
    (tester) async {
      final api = PublicPages(120);
      final service = await create(api, AtomicSnapshots());
      final videos = Videos();
      await tester.pumpWidget(
        MaterialApp(
          home: SubscriptionHistoryPage(
            service: service,
            source: source,
            videoService: videos,
            playerBuilder: (_) => const Scaffold(body: Text('已打开历史视频')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('尚未导入历史'), findsOneWidget);
      api.holdPage = 3;
      api.entered = Completer<void>();
      api.held = Completer<void>();
      await tester.tap(find.text('导入最近 100 条'));
      await tester.pump();
      await api.entered!.future;
      await tester.pump();
      expect(find.text('暂停导入'), findsOneWidget);
      await tester.tap(find.text('暂停导入'));
      await tester.pump();
      api.holdPage = null;
      api.held!.complete();
      await tester.pumpAndSettle();
      expect(service.historyJob(source.key)!.ids, hasLength(40));
      expect(find.text('继续导入'), findsOneWidget);
      await tester.tap(find.text('继续导入'));
      await tester.pumpAndSettle();
      expect(
        service.historyJob(source.key)!.status,
        HistoryImportStatus.limited,
      );
      expect(service.unreadCount, 0);
      expect(service.feed, isEmpty);
      await tester.tap(find.text('课程 0：理解概念与练习'));
      await tester.pumpAndSettle();
      expect(videos.calls, ['BV0000000000']);
      expect(find.text('已打开历史视频'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      service.setForeground(false);
    },
  );

  testWidgets('an unexpired previous owner is visible and cannot be stolen', (
    tester,
  ) async {
    final api = PublicPages(120);
    final store = AtomicSnapshots();
    final first = await create(api, store);
    await first.startHistory(source.key);
    first.setForeground(false);
    final json = jsonDecode(store.value!) as Map<String, dynamic>;
    final job = (json['historyJobs'] as Map)[source.key] as Map;
    job['status'] = 'running';
    job['runUntil'] = DateTime.now()
        .add(const Duration(minutes: 1))
        .toIso8601String();
    store.value = jsonEncode(json);
    final service = await create(api, store);
    final before = api.calls.length;
    await tester.pumpWidget(
      MaterialApp(
        home: SubscriptionHistoryPage(service: service, source: source),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在等待上次任务释放，请稍后继续'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '继续导入'),
    );
    expect(button.onPressed, isNull);
    await service.resumeHistory(source.key);
    expect(api.calls, hasLength(before));
    await tester.pumpWidget(const SizedBox());
    service.setForeground(false);
  });

  testWidgets('history rows fit narrow large text and desktop dark theme', (
    tester,
  ) async {
    await loadBetaReviewFonts(tester);
    final service = await create(PublicPages(120), AtomicSnapshots());
    await service.startHistory(source.key);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final config in [
      (const Size(390, 844), 1.0, Brightness.light, 'mobile'),
      (const Size(320, 1100), 1.8, Brightness.light, 'large-text'),
      (const Size(1280, 900), 1.0, Brightness.dark, 'desktop-dark'),
    ]) {
      tester.view.physicalSize = config.$1;
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      final theme = config.$3 == Brightness.dark
          ? AppTheme.dark()
          : AppTheme.light();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'BetaReview'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(config.$2)),
              child: child!,
            ),
            home: SubscriptionHistoryPage(service: service, source: source),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('已导入所选数量'), findsOneWidget);
      await captureSubscriptionUi(tester, key, 'history-${config.$4}');
    }
    await tester.pumpWidget(const SizedBox());
    service.setForeground(false);
  });
}
