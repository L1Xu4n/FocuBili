import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/classroom/course_cache_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
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
  Duration untilExpiry(CourseCacheEntry e) =>
      fixedNow == null ? super.untilExpiry(e) : e.until!.difference(fixedNow!);
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
        // Keep the whole explanatory paragraph and the action within the
        // evidence image. The actual interaction below still uses 320×580.
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
