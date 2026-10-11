import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_feed_tile.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/subscriptions/subscription_home_card.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/models/video_preview.dart';

import 'subscription_service_test.dart' show Content;
import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;
import 'refactor_r3_feedback_test.dart' show video, FeedbackPlayback;

class _Videos implements BilibiliService {
  final calls = <String>[];
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    calls.add(input);
    return video;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const titles = [
  '线性代数 · 用几何直觉理解矩阵与空间变换',
  '从零写一个属于自己的番茄钟：布局、交互与状态管理',
  '把知识连起来：我的阅读笔记与复习方法',
  '为什么天空是蓝色的？一起做一个小实验',
  '一周学习回顾：把复杂的问题拆成小步骤',
];

String uiFixture() {
  final data =
      jsonDecode(feedFixture(count: 5, sourceCount: 2)) as Map<String, dynamic>;
  final feed = data['feed'] as List;
  for (var i = 0; i < feed.length; i++) {
    feed[i]['title'] = titles[i];
    feed[i]['sources'] = {'creator:1': i.isEven ? '数学与日常' : '一起慢慢学 · 系列课程'};
    feed[i]['coverUrl'] =
        'https://fixture.invalid/${i.isEven ? 'wide' : 'portrait'}';
  }
  final sources = data['sources'] as List;
  sources[0]['name'] = '数学与日常';
  sources[1]['name'] = '一起慢慢学 · 从基础开始的完整系列课程';
  return jsonEncode(data);
}

Future<void> captureSubscriptionUi(
  WidgetTester tester,
  GlobalKey key,
  String name, {
  bool settle = true,
}) async {
  const directory = String.fromEnvironment('BETA3_CAPTURE_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  if (settle) await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> loadBetaReviewFonts(WidgetTester tester) async {
  if (const String.fromEnvironment('BETA3_CAPTURE_DIR').isEmpty) return;
  await tester.runAsync(() async {
    for (final entry in {
      'BetaReview': '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
      'MaterialIcons':
          '/workspace/toolchains/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final bytes = await File(entry.value).readAsBytes();
      await (FontLoader(
        entry.key,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
}

// Synthetic image responses exercise landscape and portrait decoding without
// external network access. These are review fixtures, never shipped in the app.
class _Images extends HttpOverrides {
  final Map<String, List<int>> bytes;
  _Images(this.bytes);
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(bytes);
}

class _Client implements HttpClient {
  final Map<String, List<int>> bytes;
  _Client(this.bytes);
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _Request(bytes[url.path]!);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  final List<int> bytes;
  _Request(this.bytes);
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<HttpClientResponse> close() async => _Response(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  final List<int> bytes;
  _Response(this.bytes);
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<List<int>> _image(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(color, BlendMode.src);
  final paint = Paint()..color = Colors.white.withValues(alpha: .5);
  canvas.drawCircle(Offset(width * .7, height * .4), width * .2, paint);
  paint.color = Colors.white.withValues(alpha: .8);
  canvas.drawRect(
    Rect.fromLTWH(width * .15, height * .2, width * .3, height * .6),
    paint,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'compact rows, source management and card fit narrow, large text and desktop themes',
    (tester) async {
      await loadBetaReviewFonts(tester);
      final previous = HttpOverrides.current;
      await tester.runAsync(() async {
        HttpOverrides.global = _Images({
          '/wide': await _image(320, 180, const Color(0xff427a86)),
          '/portrait': await _image(120, 320, const Color(0xff9f714a)),
        });
      });
      addTearDown(() => HttpOverrides.global = previous);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = CountingSnapshots()..value = uiFixture();
      final content = Content();
      final service = SubscriptionService(
        snapshotStore: store,
        contentService: content,
      );
      addTearDown(service.dispose);
      await service.initialize();
      for (final config in [
        (const Size(390, 844), 1.0, Brightness.light, 'mobile'),
        (const Size(320, 850), 1.8, Brightness.light, 'large-text'),
        (const Size(1280, 900), 1.0, Brightness.dark, 'desktop-dark'),
      ]) {
        tester.view.physicalSize = config.$1;
        tester.view.devicePixelRatio = 1;
        final key = GlobalKey();
        Widget host(Widget child) => RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme:
                (config.$3 == Brightness.dark
                        ? AppTheme.dark()
                        : AppTheme.light())
                    .copyWith(
                      textTheme:
                          (config.$3 == Brightness.dark
                                  ? AppTheme.dark()
                                  : AppTheme.light())
                              .textTheme
                              .apply(fontFamily: 'BetaReview'),
                    ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(config.$2)),
              child: child!,
            ),
            home: child,
          ),
        );
        await tester.pumpWidget(
          host(SubscriptionUpdatesPage(service: service)),
        );
        await tester.pumpAndSettle();
        final image = tester.getRect(
          find.byKey(const ValueKey('subscription-cover-fixture0')),
        );
        final title = tester.getRect(find.text(titles.first));
        expect(title.left, greaterThan(image.right));
        expect(title.top, closeTo(image.top, .1));
        expect(tester.takeException(), isNull);
        await captureSubscriptionUi(tester, key, 'feed-${config.$4}');
        await tester.pumpWidget(
          host(SubscriptionSettingsPage(service: service)),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('数学与日常'), 200);
        expect(tester.takeException(), isNull);
        await captureSubscriptionUi(tester, key, 'sources-${config.$4}');
        await tester.pumpWidget(
          host(
            Scaffold(
              appBar: AppBar(title: const Text('首页 · 自定义卡片')),
              body: SingleChildScrollView(
                child: Center(
                  child: SizedBox(
                    width: 500,
                    child: SubscriptionHomeCard(service: service),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SubscriptionFeedTile), findsNWidgets(3));
        expect(content.calls, isEmpty);
        expect(tester.takeException(), isNull);
        await captureSubscriptionUi(tester, key, 'card-${config.$4}');
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'home card shares updates, refresh, read state and navigation; empty state is usable',
    (tester) async {
      final store = CountingSnapshots()
        ..value = feedFixture(count: 5, sourceCount: 1);
      final content = Content();
      final videos = _Videos();
      final service = SubscriptionService(
        snapshotStore: store,
        contentService: content,
      );
      addTearDown(service.dispose);
      await service.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionHomeCard(
              service: service,
              videoService: videos,
              playerBuilder: (video) =>
                  PlayerPage(video: video, playbackService: FeedbackPlayback()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(content.calls, isEmpty);
      await service.markRead('fixture0');
      await tester.pumpAndSettle();
      expect(find.text('最近收到 · 4 条未读'), findsOneWidget);
      await tester.tap(find.byTooltip('查看全部订阅更新'));
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionUpdatesPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SubscriptionFeedTile).first);
      await tester.pumpAndSettle();
      expect(videos.calls, ['fixture0']);
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(service.unreadCount, 4);
      Navigator.of(tester.element(find.byType(PlayerPage))).pop();
      await tester.pumpAndSettle();
      service.setForeground(true);
      await tester.pumpAndSettle();
      content.calls.clear();
      await tester.tap(find.byTooltip('刷新焦点订阅'));
      await tester.pumpAndSettle();
      expect(content.calls, ['1:1']);
      await service.clearDisplayCache();
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有收到更新'), findsOneWidget);
      await tester.tap(find.text('查看订阅'));
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionUpdatesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      service.setForeground(false);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
