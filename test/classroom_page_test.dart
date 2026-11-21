import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/classroom/purchased_courses_page.dart';
import 'package:focubili/features/classroom/course_page.dart';
import 'package:focubili/services/bilibili_course_service.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;
import 'classroom_access_test.dart' show course;

class ChapterPlayback extends FeedbackPlayback {
  final openedParts = <VideoPart>[];
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    expect(video.isCourse, isTrue);
    openedParts.add(part ?? video.initialPart);
    await super.openVideo(
      video,
      part: part,
      quality: quality,
      initialPosition: initialPosition,
    );
  }
}

class CourseFixture extends BilibiliCourseService {
  int loads = 0;
  bool fails = false;
  @override
  Future<List<PurchasedCourse>> purchasedCourses() async {
    loads++;
    if (fails) throw const CourseLookupException('登录已失效，请重新登录购买课程的账号。');
    return const [
      PurchasedCourse(
        id: 1,
        title: '计算机系统基础（合成测试课程）',
        cover: '',
        description: '第 1 章至第 12 章 · 已更新完',
        unavailable: false,
        expired: false,
      ),
      PurchasedCourse(
        id: 2,
        title: '数据结构与算法（合成测试课程）',
        cover: '',
        description: '有效期测试',
        unavailable: false,
        expired: true,
      ),
      PurchasedCourse(
        id: 3,
        title: '下架课程（合成测试课程）',
        cover: '',
        description: '',
        unavailable: true,
        expired: false,
      ),
    ];
  }
}

Future<void> render(
  WidgetTester tester,
  CourseFixture fixture,
  Size size,
  GlobalKey key, {
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  const captureDir = String.fromEnvironment('CLASSROOM_CAPTURE_DIR');
  if (captureDir.isNotEmpty) {
    await tester.runAsync(() async {
      for (final entry in {
        'ClassroomReview': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons':
            'C:/Users/L1XU4N/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final bytes = await File(entry.value).readAsBytes();
        await (FontLoader(
          entry.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    });
  }
  var theme = AppTheme.light();
  if (captureDir.isNotEmpty) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'ClassroomReview'),
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: key,
        child: PurchasedCoursesPage(service: fixture),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  const directory = String.fromEnvironment('CLASSROOM_CAPTURE_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  const offlineAction = Key('current-video-offline-download-button');
  const toolbarKey = Key('player-library-actions');
  const studyActions = <Key>[
    Key('current-video-learning-list-button'),
    Key('current-video-app-favorite-button'),
    Key('portrait-note-button'),
  ];

  Future<void> pumpPlayer(
    WidgetTester tester, {
    required VideoPreview video,
    required AppPlatform platform,
    required Size size,
    double textScale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: PlayerPage(
          video: video,
          appPlatform: platform,
          playbackService: FeedbackPlayback(),
          offlineVideoService: ReviewOfflineLibrary(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final (label, platform, size, workspace) in const [
    ('Android phone', AppPlatform.android, Size(390, 844), false),
    ('Android tablet', AppPlatform.android, Size(1100, 800), true),
    ('Windows desktop', AppPlatform.windows, Size(1440, 900), true),
    ('iPhone', AppPlatform.ios, Size(390, 844), false),
  ]) {
    testWidgets('classroom actions evenly fill the $label details', (
      tester,
    ) async {
      await pumpPlayer(tester, video: course, platform: platform, size: size);
      expect(
        find.byKey(const Key('player-workspace-layout')),
        workspace ? findsOneWidget : findsNothing,
      );
      expect(find.byKey(offlineAction), findsNothing);

      final actions = [
        for (final key in studyActions) tester.getRect(find.byKey(key)),
      ];
      final toolbar = tester.getRect(find.byKey(toolbarKey));
      final pitch = actions[1].center.dx - actions[0].center.dx;
      expect(actions[0].left, closeTo(toolbar.left, 0.01));
      expect(actions[2].right, closeTo(toolbar.right, 0.01));
      expect(pitch, greaterThan(actions[0].width));
      expect(actions[2].center.dx - actions[1].center.dx, closeTo(pitch, 0.01));
      for (final action in actions) {
        expect(action.width, closeTo(actions.first.width, 0.01));
        expect(action.top, closeTo(actions.first.top, 0.01));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('classroom actions stack without empty slots at large text', (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      video: course,
      platform: AppPlatform.macos,
      size: const Size(1000, 700),
      textScale: 1.6,
    );
    expect(find.byKey(offlineAction), findsNothing);
    final actions = [
      for (final key in studyActions) tester.getRect(find.byKey(key)),
    ];
    final toolbar = tester.getRect(find.byKey(toolbarKey));
    for (final action in actions) {
      expect(action.left, closeTo(toolbar.left, 0.01));
      expect(action.right, closeTo(toolbar.right, 0.01));
    }
    expect(actions[1].top, greaterThan(actions[0].bottom));
    expect(actions[2].top, greaterThan(actions[1].bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary videos retain all four actions including cache', (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      video: const VideoPreview(
        bvid: 'BV1xx411c7mD',
        cid: 456,
        title: 'Ordinary video',
        ownerName: 'Uploader',
        parts: [
          VideoPart(
            pageNumber: 1,
            cid: 456,
            title: 'Part one',
            duration: Duration(minutes: 2),
          ),
        ],
      ),
      platform: AppPlatform.android,
      size: const Size(390, 844),
    );
    final cache = find.byKey(offlineAction);
    expect(find.byTooltip('下载离线缓存'), findsOneWidget);
    final cacheButton = find.descendant(
      of: cache,
      matching: find.byType(TextButton),
    );
    expect(tester.widget<TextButton>(cacheButton).onPressed, isNotNull);
    final actions = [
      tester.getRect(find.byKey(studyActions[0])),
      tester.getRect(cache),
      tester.getRect(find.byKey(studyActions[1])),
      tester.getRect(find.byKey(studyActions[2])),
    ];
    for (var index = 0; index < actions.length; index++) {
      expect(actions[index].width, closeTo(actions.first.width, 0.01));
      expect(actions[index].top, closeTo(actions.first.top, 0.01));
      if (index > 0) {
        expect(actions[index].left, greaterThan(actions[index - 1].right));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'existing player switches classroom chapters with exact IDs and hides UGC/download actions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final playback = ChapterPlayback();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            video: course,
            appPlatform: AppPlatform.android,
            playbackService: playback,
            offlineVideoService: ReviewOfflineLibrary(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(playback.openedParts.single.courseEpisodeId, 1913937);
      expect(find.byKey(offlineAction), findsNothing);
      expect(find.byKey(const Key('video-like-button')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('part-2')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('part-2')).first);
      await tester.pumpAndSettle();
      expect(playback.openedParts.last.courseEpisodeId, 2508999);
      expect(playback.openedParts.last.courseAid, 116492549095986);
      expect(playback.openedParts.last.cid, 37970971612);
      expect(playback.paused, isTrue);
      expect(find.byKey(offlineAction), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'purchased list disables expired and unavailable courses; tablet and large text fit',
    (tester) async {
      final fixture = CourseFixture();
      final key = GlobalKey();
      await render(tester, fixture, const Size(1280, 800), key, scale: 1.3);
      expect(fixture.loads, 1);
      expect(find.text('已购课程'), findsOneWidget);
      final expired = tester.widget<InkWell>(
        find.byKey(const Key('purchased-course-2')),
      );
      expect(expired.onTap, isNull);
      final removed = tester.widget<InkWell>(
        find.byKey(const Key('purchased-course-3')),
      );
      expect(removed.onTap, isNull);
      expect(find.byType(CoursePage), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'classroom-purchased-tablet');
    },
  );

  testWidgets(
    'expired session shows login and retry; retry replaces failure without stale purchases',
    (tester) async {
      final fixture = CourseFixture()..fails = true;
      final key = GlobalKey();
      await render(tester, fixture, const Size(390, 844), key);
      expect(find.text('登录购买账号'), findsOneWidget);
      expect(find.textContaining('登录已失效'), findsOneWidget);
      expect(find.byKey(const Key('purchased-course-1')), findsNothing);
      await capture(tester, key, 'classroom-login-mobile');
      fixture.fails = false;
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('purchased-course-1')), findsOneWidget);
      expect(find.textContaining('登录已失效'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'classroom-purchased-mobile');
    },
  );
}
