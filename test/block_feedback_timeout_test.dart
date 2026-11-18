import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/content_blocklist.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'content_blocklist_test.dart'
    show BlockSearchService, RejectingBlocklistStore, search;
import 'review_pr24_regression_test.dart'
    show ReviewLocalPlayback, ReviewOfflineLibrary;
import 'subscription_compact_ui_test.dart'
    show captureSubscriptionUi, loadBetaReviewFonts;

const _visibleVideo = '已屏蔽该视频，可在黑名单中取消。';
const _visibleCreator = '已屏蔽该 UP 主，可在黑名单中取消。';

Future<void> _openSearchBlock(WidgetTester tester, String text) async {
  await tester.tap(find.byKey(const Key('more-search-BV1GJ411x7h7')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

Future<void> _mountPlayer(
  WidgetTester tester, {
  GlobalKey<ScaffoldMessengerState>? messenger,
  GlobalKey<NavigatorState>? navigator,
}) async {
  final cached = ReviewOfflineLibrary.record.toPreview();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      scaffoldMessengerKey: messenger,
      home: PlayerPage(
        video: VideoPreview(
          bvid: cached.bvid,
          cid: cached.cid,
          title: cached.title,
          ownerName: cached.ownerName,
          ownerMid: 42,
          parts: cached.parts,
          duration: cached.duration,
          fromOfflineCache: true,
        ),
        playbackService: ReviewLocalPlayback(),
        forceOffline: true,
        offlineVideoService: ReviewOfflineLibrary(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPlayerBlock(WidgetTester tester, String key) async {
  final more = find.byKey(const Key('more-settings-menu'));
  if (more.hitTestable().evaluate().isEmpty) {
    await tester.tap(find.byKey(const Key('player-surface')).first);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }
  await tester.tap(more.hitTestable());
  await tester.pumpAndSettle();
  final item = find.byKey(Key(key));
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('搜索屏蔽视频成功提示会按时消失，不撤销屏蔽', (tester) async {
    final frame = GlobalKey();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await loadBetaReviewFonts(tester);
    const capture = String.fromEnvironment('BETA3_CAPTURE_DIR');
    await tester.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xff596abc),
            fontFamily: capture.isEmpty ? null : 'BetaReview',
          ),
          home: SearchPage(service: BlockSearchService()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-input-field')), '视频');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await _openSearchBlock(tester, '屏蔽该视频');
    expect(find.text(_visibleVideo), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    expect(find.text('第一条视频'), findsNothing);
    await captureSubscriptionUi(tester, frame, '01-confirmation-visible');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_visibleVideo), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text(_visibleVideo), findsNothing);
    expect((await const ContentBlocklistService().load()).videos.keys, [
      'BV1GJ411x7h7',
    ]);
    expect(find.text('第一条视频'), findsNothing);
    await captureSubscriptionUi(tester, frame, '02-confirmation-expired');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('播放器屏蔽 UP 主成功提示会按时消失，不撤销屏蔽', (tester) async {
    await _mountPlayer(tester);
    await _openPlayerBlock(tester, 'player-block-creator');
    expect(find.text(_visibleCreator), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text(_visibleCreator), findsNothing);
    expect((await const ContentBlocklistService().load()).creators.keys, [42]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('读屏成功提示提供足够撤销时间且可单独关闭', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await search(tester, BlockSearchService());
    await _openSearchBlock(tester, '屏蔽该 UP 主');
    await tester.pump(const Duration(seconds: 12));
    expect(find.text(_visibleCreator), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    final close = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byTooltip('Close'),
    );
    expect(close.hitTestable(), findsOneWidget);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text(_visibleCreator), findsNothing);
    expect((await const ContentBlocklistService().load()).creators.keys, [42]);
  });

  testWidgets('连续屏蔽排在重要错误后，撤销只影响最新目标', (tester) async {
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await _mountPlayer(tester, messenger: messenger);
    const important = '重要：下载失败，需要重试。';
    final error = messenger.currentState!.showSnackBar(
      const SnackBar(content: Text(important), persist: true),
    );
    await tester.pumpAndSettle();
    await _openPlayerBlock(tester, 'player-block-video');
    await _openPlayerBlock(tester, 'player-block-creator');
    expect(find.text(important), findsOneWidget);
    expect(find.text(_visibleCreator), findsNothing);
    expect(find.text(_visibleVideo), findsNothing);
    error.close();
    await tester.pumpAndSettle();
    expect(find.text(_visibleCreator), findsOneWidget);
    expect(find.text(_visibleVideo), findsNothing);
    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    final list = await const ContentBlocklistService().load();
    expect(list.creators, isEmpty);
    expect(list.videos, hasLength(1));
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('打开新页面时旧确认和撤销离场，不吞新页面错误', (tester) async {
    final messenger = GlobalKey<ScaffoldMessengerState>();
    final navigator = GlobalKey<NavigatorState>();
    await _mountPlayer(tester, messenger: messenger, navigator: navigator);
    await _openPlayerBlock(tester, 'player-block-video');
    expect(find.text(_visibleVideo), findsOneWidget);
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一个页面'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('另一个页面'), findsOneWidget);
    expect(find.text(_visibleVideo), findsNothing);
    expect(find.text('撤销'), findsNothing);

    const error = '另一个页面的重要错误';
    messenger.currentState!.showSnackBar(
      const SnackBar(content: Text(error), persist: true),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(find.text(error), findsOneWidget);
    expect((await const ContentBlocklistService().load()).videos, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('过时撤销不删除后来重新加回的同一 BV', (tester) async {
    const service = ContentBlocklistService();
    const bvid = 'BV1GJ411x7h7';
    await search(tester, BlockSearchService());
    await _openSearchBlock(tester, '屏蔽该视频');
    await service.unblockVideo(bvid);
    await service.blockVideo(bvid, '第一条视频');
    await tester.pump();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect((await service.load()).videos.keys, [bvid]);
    expect(find.text('第一条视频'), findsNothing);
  });

  testWidgets('撤销写入失败时不误恢复搜索，给出明确错误', (tester) async {
    SharedPreferencesStorePlatform.instance = RejectingBlocklistStore({})
      ..reject = false;
    await search(tester, BlockSearchService());
    await _openSearchBlock(tester, '屏蔽该视频');
    (SharedPreferencesStorePlatform.instance as RejectingBlocklistStore)
            .reject =
        true;
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('撤销屏蔽失败，请重试。'), findsOneWidget);
    expect(find.text('第一条视频'), findsNothing);
    expect((await const ContentBlocklistService().load()).videos, hasLength(1));
  });

  test('同一目标并发插入只得一次撤销，不影响另外一种规则', () async {
    const service = ContentBlocklistService();
    final actions = await Future.wait([
      service.blockCreatorWithUndo(42, 'original'),
      service.blockCreatorWithUndo(42, 'duplicate'),
      service.blockVideoWithUndo('BV1GJ411x7h7', 'video'),
    ]);
    expect((await service.load()).creators[42], 'original');
    expect(actions[1], isNull);
    await actions[0]!.apply();
    expect((await service.load()).creators, isEmpty);
    expect((await service.load()).videos, hasLength(1));
    actions[2]!.discard();
  });

  test('旧撤销不能删除 #123 管理页面另加回的 UID 规则', () async {
    const service = ContentBlocklistService();
    final original = await service.blockCreatorWithUndo(42, '已屏蔽的 UP 主');
    const oldRule = ContentBlockRule(ContentBlockKind.creatorUid, '42');
    const newRule = ContentBlockRule(ContentBlockKind.creatorUid, '43');
    await service.saveRule(newRule, previous: oldRule);
    await service.saveRule(oldRule);
    await original!.apply();
    expect((await service.load()).creators.keys, unorderedEquals([42, 43]));
  });
}
