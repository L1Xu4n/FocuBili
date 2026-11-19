import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/classroom/course_cache_page.dart';
import 'package:focubili/features/classroom/course_cache_playback_page.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/course_cache_validity.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'course_cache_library_test.dart' show part, video;
import 'subscription_compact_ui_test.dart'
    show loadBetaReviewFonts, captureSubscriptionUi;

class _Library extends CourseCacheLibrary {
  List<CourseCacheEntry> rows = [];
  int serial = 0;
  int starts = 0;
  Completer<List<CourseCacheEntry>>? gate;
  DateTime? fixedNow;
  @override
  bool isUsable(CourseCacheEntry e) =>
      fixedNow == null ? super.isUsable(e) : e.usableAt(fixedNow!);
  @override
  Duration? untilExpiry(CourseCacheEntry e) =>
      fixedNow == null ? super.untilExpiry(e) : e.until?.difference(fixedNow!);
  @override
  int get listVersion => serial;
  @override
  Future<List<CourseCacheEntry>> entries() async =>
      gate == null ? rows : gate!.future;
  @override
  Future<void> start(VideoPreview v, VideoPart p, {int quality = 64}) async {
    starts++;
    rows = [
      CourseCacheEntry(
        mid: 51,
        season: 11,
        ep: 21,
        aid: 55,
        cid: 31,
        courseTitle: v.title,
        chapterTitle: p.title,
        duration: p.duration,
        quality: quality,
        videoBytes: 5263852,
        audioBytes: 514288,
        checkedAt: DateTime.now().subtract(const Duration(minutes: 1)),
        until: DateTime.now().add(const Duration(hours: 1)),
      ),
    ];
    serial++;
    notifyListeners();
  }

  @override
  Future<({CourseCacheEntry entry, String video, String? audio})> open(
    CourseCacheEntry e,
  ) async {
    if (!isUsable(e)) throw const CourseCacheFailure('缓存不可用。');
    return (entry: e, video: '/synthetic/private/lesson.bin', audio: null);
  }

  @override
  Future<void> remove(CourseCacheEntry e) async {
    rows = [];
    serial++;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'expiry updates narrow large-text row and offers recheck without a dialog',
    (t) async {
      final now = DateTime.utc(2026, 11, 18);
      final library = _Library()..fixedNow = now;
      addTearDown(library.dispose);
      library.rows = [
        CourseCacheEntry(
          mid: 51,
          season: 11,
          ep: 21,
          aid: 55,
          cid: 31,
          courseTitle: video.title,
          chapterTitle: part.title,
          duration: part.duration,
          quality: 64,
          videoBytes: 100,
          checkedAt: now,
          until: now.add(const Duration(seconds: 1)),
        ),
      ];
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(320, 580);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      await loadBetaReviewFonts(t);
      final key = GlobalKey();
      final base = AppTheme.dark();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: base.copyWith(
              textTheme: base.textTheme.apply(fontFamily: 'BetaReview'),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.8)),
              child: child!,
            ),
            home: CourseCachePage(library: library),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('离线播放'), findsOneWidget);
      library.fixedNow = now.add(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('离线播放'), findsNothing);
      await t.ensureVisible(find.text('联网复核'));
      if (const String.fromEnvironment('BETA3_CAPTURE_DIR').isNotEmpty) {
        // Keep the action in the evidence image. Interaction still uses 320×580.
        t.view.physicalSize = const Size(320, 840);
        await t.pumpAndSettle();
        await captureSubscriptionUi(t, key, 'course-cache-recheck-320');
        t.view.physicalSize = const Size(320, 580);
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('联网复核'));
      }
      await t.tap(find.text('联网复核'));
      await t.pumpAndSettle();
      expect(library.starts, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('已核验无服务端日期的课堂两天后仍可打开离线播放器，不弹复核', (t) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.focubili.app/playback');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'initialize' ? {'textureId': 4} : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final now = DateTime.now();
    final checked = now.subtract(const Duration(days: 2));
    final library = _Library()..fixedNow = now;
    addTearDown(library.dispose);
    final entry = CourseCacheEntry(
      mid: 51,
      season: 11,
      ep: 21,
      aid: 55,
      cid: 31,
      courseTitle: video.title,
      chapterTitle: part.title,
      duration: part.duration,
      quality: 64,
      videoBytes: 5242880,
      checkedAt: checked,
      expiryKind: CourseCacheExpiryKind.noDeclaredDeadline,
    );
    library.rows = [entry];
    final boundary = GlobalKey();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 780);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await loadBetaReviewFonts(t);
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light().copyWith(
            textTheme: AppTheme.light().textTheme.apply(
              fontFamily: 'BetaReview',
            ),
          ),
          home: CourseCachePage(library: library),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('离线播放'), findsOneWidget);
    expect(find.text('联网复核'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await captureSubscriptionUi(
      t,
      boundary,
      'course-cache-verified-no-deadline',
    );

    // Exercise the real PlayerPage → Dart Android bridge without real account
    // credentials or video files. The library's disk and session checks have
    // separate integration coverage.
    await t.pumpWidget(
      MaterialApp(
        home: CourseCachePlaybackPage(
          library: library,
          entry: entry,
          appPlatform: AppPlatform.android,
        ),
      ),
    );
    for (int i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 25));
    }
    expect(t.widget<PlayerPage>(find.byType(PlayerPage)).forceOffline, isTrue);
    final open = calls.singleWhere((call) => call.method == 'openLocal');
    expect(
      open.arguments,
      containsPair('courseCacheCheckedAt', checked.millisecondsSinceEpoch),
    );
    expect(
      open.arguments,
      containsPair('courseCacheExpiryKind', 'noDeclaredDeadline'),
    );
    expect(open.arguments, isNot(contains('courseCacheUntil')));
    expect(calls.where((call) => call.method == 'open'), isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(library.starts, 0);
    CacheLifecycle.accountChanged();
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byType(PlayerPage), findsNothing);
    expect(calls.where((call) => call.method == 'dispose'), isNotEmpty);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('course cache overview has short contextual empty text', (
    t,
  ) async {
    final library = _Library();
    addTearDown(library.dispose);
    await t.pumpWidget(MaterialApp(home: CourseCachePage(library: library)));
    await t.pumpAndSettle();
    expect(find.text('暂无缓存，可在课程播放器中缓存章节。'), findsOneWidget);
    expect(find.textContaining('仅供购买账号'), findsNothing);
    expect(find.text('缓存本章'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in [(390.0, 780.0, 1.0), (320.0, 580.0, 1.8)]) {
    testWidgets(
      'chapter actions, cancel, delete, account-switch fence at ${mode.$1}',
      (t) async {
        final l = _Library();
        addTearDown(l.dispose);
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(mode.$1, mode.$2);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.view.resetPhysicalSize);
        await loadBetaReviewFonts(t);
        final key = GlobalKey();
        final base = mode.$3 == 1 ? AppTheme.light() : AppTheme.dark();
        await t.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: base.copyWith(
                textTheme: base.textTheme.apply(fontFamily: 'BetaReview'),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(mode.$3)),
                child: child!,
              ),
              home: CourseCachePage(video: video, part: part, library: l),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('缓存本章'), findsOneWidget);
        expect(find.text('暂无缓存'), findsOneWidget);
        expect(find.textContaining('仅供购买账号'), findsNothing);
        await captureSubscriptionUi(
          t,
          key,
          'course-cache-empty-${mode.$1.toInt()}',
        );
        await t.tap(find.text('缓存本章'));
        await t.pumpAndSettle();
        expect(l.starts, 1);
        expect(find.text('离线播放'), findsOneWidget);
        await captureSubscriptionUi(t, key, 'course-cache-${mode.$1.toInt()}');
        await t.ensureVisible(find.text('删除'));
        await t.tap(find.text('删除'));
        await t.pumpAndSettle();
        await t.tap(find.text('取消'));
        await t.pumpAndSettle();
        expect(l.rows, hasLength(1));
        await t.tap(find.text('删除'));
        await t.pumpAndSettle();
        await t.tap(find.text('删除').last);
        await t.pumpAndSettle();
        expect(l.rows, isEmpty);
        await t.ensureVisible(find.text('缓存本章'));
        await t.tap(find.text('缓存本章'));
        await t.pumpAndSettle();
        l.gate = Completer();
        CacheLifecycle.accountChanged();
        await t.pump();
        expect(find.text(video.title), findsNothing);
        expect(find.text(part.title), findsNothing);
        expect(find.text('离线播放'), findsNothing);
        l.gate!.complete([]);
        await t.pumpAndSettle();
        expect(find.text('缓存本章'), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
