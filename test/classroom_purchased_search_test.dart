import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/features/classroom/course_page.dart';
import 'package:focubili/features/classroom/purchased_courses_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_course_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';

PurchasedCourse _course(
  int id,
  String title, {
  String description = '',
  String cover = '',
  bool expired = false,
  bool unavailable = false,
}) => PurchasedCourse(
  id: id,
  title: title,
  cover: cover,
  description: description,
  unavailable: unavailable,
  expired: expired,
);

String _paid(int total, List<Map<String, Object?>> items) => jsonEncode({
  'code': 0,
  'data': {'total': total, 'data': items},
});

class _QueuedCourses extends BilibiliCourseService {
  final requests = <Completer<List<PurchasedCourse>>>[];
  final opened = <Uri>[];

  @override
  Future<List<PurchasedCourse>> purchasedCourses() {
    final request = Completer<List<PurchasedCourse>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<VideoPreview> lookup(Uri input) async {
    opened.add(input);
    throw const CourseLookupException('合成课程详情');
  }
}

class _ManyCourses extends BilibiliCourseService {
  _ManyCourses(this.items);
  final List<PurchasedCourse> items;
  int loads = 0;
  @override
  Future<List<PurchasedCourse>> purchasedCourses() async {
    loads++;
    return items;
  }
}

final _search = find.byKey(const Key('purchased-courses-search'));
final _empty = find.byKey(const Key('purchased-courses-message'));
final _noMatches = find.byKey(const Key('purchased-courses-no-matches'));
Finder _tile(int id) => find.byKey(Key('purchased-course-$id'));
Finder _cover(int id) => find.byKey(Key('purchased-course-cover-$id'));
Finder _placeholder(int id) =>
    find.byKey(Key('purchased-course-cover-placeholder-$id'));

Future<void> _show(
  WidgetTester tester,
  BilibiliCourseService service, {
  double textScale = 1,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: PurchasedCoursesPage(service: service),
    ),
  );
}

class _CoverClient extends Fake implements HttpClient {
  _CoverClient(this.png);
  final List<int> png;
  final requests = <_CoverRequest>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = _CoverRequest(url, png);
    requests.add(request);
    return request;
  }
}

class _CoverRequest extends Fake implements HttpClientRequest {
  _CoverRequest(this.url, this.png);
  final Uri url;
  final List<int> png;

  @override
  final _CoverHeaders headers = _CoverHeaders();

  @override
  Future<HttpClientResponse> close() async {
    final failed = url.path.contains('missing');
    return _CoverResponse(
      failed ? HttpStatus.notFound : HttpStatus.ok,
      failed ? const [] : png,
    );
  }
}

class _CoverHeaders extends Fake implements HttpHeaders {
  final sent = <String, Object>{};
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    sent[name.toLowerCase()] = value;
  }
}

class _CoverResponse extends Stream<List<int>> implements HttpClientResponse {
  _CoverResponse(this.statusCode, this.bytes);

  @override
  final int statusCode;
  final List<int> bytes;

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
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<List<int>> _squarePng() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets(
    'complete session list searches by title and description locally',
    (tester) async {
      final secondPage = Completer<String>();
      final requests = <int>[];
      final service = BilibiliCourseService(
        readCookies: () async => 'synthetic-session',
        requestJson: (uri, session) {
          expect(session, 'synthetic-session');
          final page = int.parse(uri.queryParameters['pn']!);
          requests.add(page);
          return page == 1
              ? Future.value(
                  _paid(3, [
                    {'id': 1, 'title': '离散数学'},
                  ]),
                )
              : secondPage.future;
        },
      );
      await _show(tester, service);
      await tester.pump();
      expect(requests, [1, 2]);
      expect(_search, findsNothing);
      expect(find.text('离散数学'), findsNothing);
      secondPage.complete(
        _paid(3, [
          {'id': 2, 'title': 'C++ 语言入门'},
          {
            'id': 3,
            'title': '数据结构',
            'sub_title': 'Advanced [Graphs]',
            'status': -3,
          },
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('共 3 门已购课程'), findsOneWidget);
      await tester.enterText(_search, '  c++  ');
      await tester.pumpAndSettle();
      expect(_tile(2), findsOneWidget);
      expect(_tile(1), findsNothing);
      expect(_tile(3), findsNothing);
      expect(find.text('找到 1 门课程'), findsOneWidget);

      await tester.enterText(_search, '[graphs]');
      await tester.pumpAndSettle();
      expect(_tile(3), findsOneWidget);
      expect(find.text('课程已失效或已下架'), findsOneWidget);
      expect(tester.widget<InkWell>(_tile(3)).onTap, isNull);

      await tester.enterText(_search, '不存在');
      await tester.pumpAndSettle();
      expect(_noMatches, findsOneWidget);
      expect(_empty, findsNothing);
      expect(find.text('登录购买账号'), findsNothing);
      await tester.tap(find.text('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.text('共 3 门已购课程'), findsOneWidget);
      expect(_tile(1), findsOneWidget);

      await tester.enterText(_search, '数学');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清除课程搜索'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
      expect(requests, [1, 2]);
    },
  );

  testWidgets(
    'refresh failure and return from details keep the same-account query',
    (tester) async {
      final service = _QueuedCourses();
      final lesson = _course(1, '线性代数');
      await _show(tester, service);
      service.requests.single.complete([lesson, _course(2, '历史')]);
      await tester.pumpAndSettle();
      await tester.enterText(_search, '代数');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));

      await tester.tap(find.byTooltip('刷新已购课程'));
      await tester.pump();
      expect(_tile(1), findsNothing);
      service.requests.last.completeError(const CourseLookupException('加载失败'));
      await tester.pumpAndSettle();
      expect(_empty, findsOneWidget);
      expect(_noMatches, findsNothing);
      await tester.tap(find.text('重新加载'));
      await tester.pump();
      service.requests.last.complete([lesson, _course(3, '微积分')]);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, '代数');
      expect(_tile(1), findsOneWidget);
      expect(_tile(3), findsNothing);

      await tester.tap(_tile(1));
      await tester.pumpAndSettle();
      expect(find.byType(CoursePage), findsOneWidget);
      expect(service.opened.single, lesson.uri);
      await tester.pageBack();
      await tester.pump();
      expect(service.requests, hasLength(4));
      service.requests.last.complete([lesson]);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, '代数');
      expect(_tile(1), findsOneWidget);
    },
  );

  testWidgets(
    'switch and background discard old account query and late results',
    (tester) async {
      final service = _QueuedCourses();
      await _show(tester, service);
      service.requests.single.complete([_course(1, '旧账号课程')]);
      await tester.pumpAndSettle();
      await tester.enterText(_search, '旧账号');
      await tester.pumpAndSettle();
      expect(_tile(1), findsOneWidget);

      await tester.tap(find.byTooltip('刷新已购课程'));
      await tester.pump();
      final stale = service.requests.last;
      CacheLifecycle.accountChanged();
      await tester.pump();
      expect(_search, findsNothing);
      expect(_tile(1), findsNothing);
      service.requests.last.complete([_course(2, '新账号课程')]);
      await tester.pumpAndSettle();
      stale.complete([_course(3, '旧异步结果')]);
      await tester.pumpAndSettle();
      expect(_tile(2), findsOneWidget);
      expect(_tile(3), findsNothing);
      expect(tester.widget<TextField>(_search).controller!.text, isEmpty);

      await tester.enterText(_search, '新账号');
      await tester.pumpAndSettle();
      final oldQuery = tester.widget<TextField>(_search).controller!;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(oldQuery.text, isEmpty);
      final beforeResume = service.requests.length;
      CacheLifecycle.accountChanged();
      await tester.pump();
      expect(service.requests, hasLength(beforeResume));
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(_search, findsNothing);
      expect(_tile(2), findsNothing);
      expect(service.requests, hasLength(beforeResume + 1));
      service.requests.last.complete([_course(4, '回到前台的课程')]);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
      expect(_tile(4), findsOneWidget);
      expect(_tile(2), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'thumbnails stay 16:9, load without credentials, and degrade to placeholders',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 880);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final png = (await tester.runAsync(_squarePng))!;
      final client = _CoverClient(png);
      final previous = debugNetworkImageHttpClientProvider;
      debugNetworkImageHttpClientProvider = () => client;
      try {
        const public = 'https://i0.hdslb.com/fixture/purchased-square.png';
        const broken = 'https://i1.biliimg.com/fixture/missing.png';
        final service = _ManyCourses([
          _course(1, '很窄的页面里仍可读的课程标题', cover: public),
          _course(2, '过期', cover: broken, expired: true),
          _course(3, '无封面且已下架', unavailable: true),
          _course(4, '外站封面', cover: 'https://outside.invalid/purchased.png'),
        ]);
        await _show(tester, service, textScale: 2.2);
        await tester.pumpAndSettle();
        expect(find.text('搜索课程名或简介'), findsOneWidget);
        expect(tester.widget<TextField>(_search).decoration!.hintText, '输入关键词');
        final image = find.descendant(
          of: _cover(1),
          matching: find.byType(Image),
        );
        final provider = tester.widget<Image>(image).image;
        // Wait for actual decode using the mounted image's provider and test PNG.
        await tester.runAsync(() async {
          final uiReady = Completer<void>();
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener(
            (image, _) {
              if (!uiReady.isCompleted) uiReady.complete();
            },
            onError: (Object error, StackTrace? stack) {
              if (!uiReady.isCompleted) uiReady.completeError(error, stack);
            },
          );
          stream.addListener(listener);
          try {
            await uiReady.future.timeout(const Duration(seconds: 3));
          } finally {
            stream.removeListener(listener);
          }
        });
        await tester.pumpAndSettle();
        final raw = find.descendant(
          of: _cover(1),
          matching: find.byType(RawImage),
        );
        expect(tester.widget<RawImage>(raw).image, isNotNull);
        expect(tester.widget<Image>(image).fit, BoxFit.cover);
        final size = tester.getSize(_cover(1));
        expect(size.aspectRatio, closeTo(16 / 9, 0.0001));
        expect(_placeholder(1), findsNothing);
        expect(_placeholder(2), findsOneWidget);
        expect(_placeholder(3), findsOneWidget);
        expect(find.text('课程已过期，请到官方课堂确认'), findsOneWidget);
        expect(tester.widget<InkWell>(_tile(2)).onTap, isNull);
        await tester.scrollUntilVisible(
          _tile(4),
          140,
          scrollable: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        );
        await tester.pumpAndSettle();
        expect(_placeholder(4), findsOneWidget);
        expect(
          client.requests.map((request) => request.url.toString()).toSet(),
          {'$public@480w_270h_1c.webp', '$broken@480w_270h_1c.webp'},
        );
        expect(
          client.requests.expand((request) => request.headers.sent.keys),
          isNot(anyElement(contains('cookie'))),
        );
        expect(
          client.requests.expand((request) => request.headers.sent.keys),
          isNot(contains(HttpHeaders.authorizationHeader)),
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugNetworkImageHttpClientProvider = previous;
      }
    },
  );

  testWidgets(
    'long shelves build lazily while the search reaches the last item',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 680);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final service = _ManyCourses([
        for (var i = 1; i <= 200; i++) _course(i, '课程 $i'),
      ]);
      await _show(tester, service);
      await tester.pumpAndSettle();
      expect(find.text('共 200 门已购课程'), findsOneWidget);
      expect(_tile(1), findsOneWidget);
      expect(_tile(200), findsNothing);
      expect(find.byType(AspectRatio).evaluate().length, lessThan(25));

      await tester.enterText(_search, '课程 200');
      await tester.pumpAndSettle();
      expect(_tile(200), findsOneWidget);
      expect(_tile(1), findsNothing);
      expect(service.loads, 1);
    },
  );
  for (final sizeAndScale in [
    (const Size(390, 700), 1.0),
    (const Size(320, 590), 2.0),
  ]) {
    testWidgets(
      'search field semantics exclude count and purchase notice at ${sizeAndScale.$1}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = sizeAndScale.$1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await _show(
          tester,
          _ManyCourses([_course(1, '摄影')]),
          textScale: sizeAndScale.$2,
        );
        await tester.pumpAndSettle();
        await tester.tap(_search);
        await tester.pumpAndSettle();
        const notice = '仅显示当前账号的已购课堂';
        for (final query in ['', '摄影']) {
          if (query.isNotEmpty) {
            await tester.enterText(_search, query);
            await tester.pumpAndSettle();
          }
          final field = tester
              .getSemantics(find.byType(EditableText))
              .getSemanticsData();
          expect(field.flagsCollection.isTextField, isTrue);
          expect(field.label, contains('搜索课程名或简介'));
          expect(field.label, isNot(contains('门课程')));
          expect(field.label, isNot(contains('门已购课程')));
          expect(field.label, isNot(contains(notice)));
          expect(field.value, query);
          expect(find.bySemanticsLabel(RegExp(notice)), findsOneWidget);
        }
      },
    );
  }
}
