import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/classroom/purchased_courses_page.dart';
import 'package:focubili/services/bilibili_course_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';

class _Purchased extends BilibiliCourseService {
  final requests = <Completer<List<PurchasedCourse>>>[];

  @override
  Future<List<PurchasedCourse>> purchasedCourses() {
    final request = Completer<List<PurchasedCourse>>();
    requests.add(request);
    return request.future;
  }
}

PurchasedCourse _course(int id) => PurchasedCourse(
  id: id,
  title: '合成课程 $id',
  cover: '',
  description: '',
  unavailable: false,
  expired: false,
);

void main() {
  testWidgets('后台恢复时链接弹窗仍开着，完成刷新且取消后不会卡住', (tester) async {
    final service = _Purchased();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(home: PurchasedCoursesPage(service: service)),
    );
    service.requests.single.complete([_course(1)]);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('打开课程链接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('purchased-courses-link-input')),
      'https://www.bilibili.com/cheese/play/ss3',
    );

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(service.requests, hasLength(2));
    service.requests.last.complete([_course(2)]);
    await tester.pumpAndSettle();
    expect(find.textContaining('/ss3'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('合成课程 2'), findsOneWidget);
    expect(find.text('合成课程 1'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('前台切号立即移除旧课程，过期错误与慢返回均不能覆盖新账号', (tester) async {
    final service = _Purchased();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(home: PurchasedCoursesPage(service: service)),
    );
    service.requests.single.complete([_course(1)]);
    await tester.pumpAndSettle();
    expect(find.text('合成课程 1'), findsOneWidget);
    CacheLifecycle.accountChanged();
    await tester.pump();
    expect(find.text('合成课程 1'), findsNothing);
    expect(service.requests, hasLength(2));
    CacheLifecycle.accountChanged();
    await tester.pump();
    expect(service.requests, hasLength(3));
    service.requests[2].complete([_course(2)]);
    await tester.pumpAndSettle();
    service.requests[1].completeError(const CourseLookupException('旧账号请求超时'));
    await tester.pumpAndSettle();
    expect(find.text('合成课程 2'), findsOneWidget);
    expect(find.text('旧账号请求超时'), findsNothing);
  });

  test('购买列表短暂重叠时按去重后数量继续取页，而不是误报未购买', () async {
    final pages = <int>[];
    final service = BilibiliCourseService(
      readCookies: () async => 'synthetic-session',
      requestJson: (uri, _) async {
        final page = int.parse(uri.queryParameters['pn']!);
        pages.add(page);
        final ids = switch (page) {
          1 => [1],
          2 => [1, 2],
          3 => [3],
          _ => throw StateError('unexpected page'),
        };
        return jsonEncode({
          'code': 0,
          'data': {
            'total': 3,
            'data': [
              for (final id in ids) {'id': id},
            ],
          },
        });
      },
    );
    await service.requirePurchasedCourse(3, 'synthetic-session');
    expect(pages, [1, 2, 3]);
    pages.clear();
    final courses = await service.purchasedCourses();
    expect(courses.map((course) => course.id), [1, 2, 3]);
    expect(pages, [1, 2, 3]);
  });

  test('账号代次变化即停止课堂目录分页，即使转换期间 Cookie 未变', () async {
    final pages = <String>[];
    final service = BilibiliCourseService(
      readCookies: () async => 'synthetic-same-session',
      requestJson: (uri, cookie) async {
        if (uri.path.endsWith('/season')) {
          return jsonEncode({
            'code': 0,
            'data': {
              'season_id': 1,
              'episodes': [],
              'episode_page': {'total': 2},
            },
          });
        }
        if (uri.path.endsWith('/my/paid')) {
          return '{"code":0,"data":{"total":1,"data":[{"id":1}]}}';
        }
        final page = uri.queryParameters['pn']!;
        pages.add(page);
        if (page == '1') CacheLifecycle.accountChanged();
        return jsonEncode({
          'code': 0,
          'data': {
            'items': [
              {'id': int.parse(page), 'aid': 1, 'cid': int.parse(page)},
            ],
            'page': {'next': page == '1', 'total': 2},
          },
        });
      },
    );
    await expectLater(
      service.lookup(Uri.parse('https://www.bilibili.com/cheese/play/ss1')),
      throwsA(
        isA<CourseLookupException>().having(
          (error) => error.message,
          'message',
          contains('登录状态已变化'),
        ),
      ),
    );
    expect(pages, ['1']);
  });
}
