import 'dart:async';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/core/theme/app_theme.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_video_tags.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/video_tag_preferences.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;
import 'subscription_compact_ui_test.dart'
    show loadBetaReviewFonts, captureSubscriptionUi;

const a = VideoPreview(
  bvid: 'BV1GJ411x7h7',
  cid: 25,
  title: '从力学到轨道：模拟物理课',
  ownerName: '示例讲堂',
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 25,
      title: '模拟章节',
      duration: Duration(minutes: 12),
    ),
  ],
);
const b = VideoPreview(
  bvid: 'BV1Q541167Qg',
  cid: 29,
  title: '模拟实验',
  ownerName: '合成数据',
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 29,
      title: '实验',
      duration: Duration(minutes: 15),
    ),
  ],
);

class _Source extends Fake implements BilibiliService, BilibiliVideoTagSource {
  final calls = <String>[];
  Completer<List<String>>? pending;
  bool fail = false, empty = false;
  @override
  Future<List<String>> loadVideoTags(String bvid) async {
    calls.add(bvid);
    if (fail) throw StateError('synthetic');
    return pending == null
        ? empty
              ? <String>[]
              : ['物理', '高中物理', '知识点归纳', '学习心得']
        : pending!.future;
  }
}

class _ThrowingWrite extends InMemorySharedPreferencesStore {
  _ThrowingWrite()
    : super.withData({'flutter.${VideoTagPreferences.key}': 'hidden'});
  @override
  Future<bool> setValue(String type, String key, Object value) async =>
      throw StateError('synthetic write failure');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'failed write keeps confirmed hidden mode and makes no tag request',
    (t) async {
      SharedPreferencesStorePlatform.instance = _ThrowingWrite();
      expect(await VideoTagPreferences.load(), VideoTagMode.hidden);
      expect(await VideoTagPreferences.save(VideoTagMode.expanded), isFalse);
      final source = _Source(), session = PlayerTagSession()..bind(a);
      session.initialize(source);
      addTearDown(session.dispose);
      await t.pump();
      expect(session.visible, isFalse);
      expect(source.calls, isEmpty);
    },
  );
  test('migrates only the setting, rejects unknown imported modes', () async {
    final service = SettingsTransferService();
    await service.importSettings({VideoTagPreferences.key: 'hidden'});
    expect(await VideoTagPreferences.load(), VideoTagMode.hidden);
    await expectLater(
      service.importSettings({VideoTagPreferences.key: 'invalid'}),
      throwsFormatException,
    );
    expect(await VideoTagPreferences.load(), VideoTagMode.hidden);
  });

  testWidgets(
    'old results and repeated clicks cannot disclose tags on new or hidden video',
    (t) async {
      final source = _Source()..pending = Completer();
      final session = PlayerTagSession()
        ..bind(a)
        ..initialize(source);
      addTearDown(session.dispose);
      await t.pump();
      expect(session.expanded, isFalse);
      expect(source.calls, isEmpty);
      unawaited(session.reveal());
      unawaited(session.reveal());
      await t.pump();
      expect(source.calls, [a.bvid]);
      session.bind(b);
      source.pending!.complete(['迟到的标签']);
      await t.pump();
      expect(session.tags, isEmpty);
      expect(session.expanded, isFalse);
      source.pending = null;
      await VideoTagPreferences.save(VideoTagMode.hidden);
      await t.pump();
      expect(session.visible, isFalse);
      await session.reveal();
      expect(source.calls, [a.bvid]);
      await VideoTagPreferences.save(VideoTagMode.expanded);
      await t.pump();
      expect(source.calls, [a.bvid, b.bvid]);
      expect(session.tags, contains('物理'));
    },
  );
  testWidgets(
    'no second request for known tags; errors retry and empty results stay expanded',
    (t) async {
      final source = _Source();
      final session = PlayerTagSession()
        ..bind(a.withTags(['已知标签']))
        ..initialize(source);
      addTearDown(session.dispose);
      await t.pump();
      await session.reveal();
      expect(session.tags, ['已知标签']);
      expect(source.calls, isEmpty);
      session.bind(b);
      source.fail = true;
      await session.reveal();
      expect(session.failed, isTrue);
      source.fail = false;
      source.empty = true;
      await session.reveal();
      await session.reveal();
      expect(session.failed, isFalse);
      expect(session.expanded, isTrue);
      expect(session.tags, isEmpty);
      expect(source.calls, [b.bvid, b.bvid]);
    },
  );
  for (final size in [(390.0, 815.0, 1.0), (830.0, 530.0, 1.45)]) {
    testWidgets(
      'actual player tag actions survive rebuild, not re-entry at ${size.$1}',
      (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(size.$1, size.$2);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.view.resetPhysicalSize);
        final source = _Source(), key = GlobalKey();
        await loadBetaReviewFonts(t);
        final base = AppTheme.dark();
        Widget page(int id) => RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: base.copyWith(
              textTheme: base.textTheme.apply(fontFamily: 'BetaReview'),
            ),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: TextScaler.linear(size.$3)),
              child: child!,
            ),
            home: PlayerPage(
              key: ValueKey(id),
              video: a,
              bilibiliService: source,
              playbackService: FeedbackPlayback(),
              offlineVideoService: ReviewOfflineLibrary(),
            ),
          ),
        );
        final button = find.byKey(const Key('reveal-video-tags'));
        await t.pumpWidget(page(1));
        await t.pumpAndSettle();
        expect(source.calls, isEmpty);
        await t.ensureVisible(button);
        await t.pumpAndSettle();
        await captureSubscriptionUi(
          t,
          key,
          'tags-collapsed-${size.$1.toInt()}',
        );
        await t.tap(button);
        await t.pumpAndSettle();
        expect(button, findsNothing);
        expect(find.text('物理'), findsOneWidget);
        expect(source.calls, [a.bvid]);
        await captureSubscriptionUi(t, key, 'tags-expanded-${size.$1.toInt()}');
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
        await t.pumpWidget(page(2));
        await t.pumpAndSettle();
        expect(button, findsOneWidget);
        expect(source.calls, [a.bvid]);
        await VideoTagPreferences.save(VideoTagMode.hidden);
        await t.pumpAndSettle();
        expect(button, findsNothing);
        expect(find.text('物理'), findsNothing);
        await t.pumpWidget(const SizedBox.shrink());
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('personalization search lets users save and reopen each mode', (
    t,
  ) async {
    await t.pumpWidget(const MaterialApp(home: PersonalizationSettingsPage()));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('settings-search')), '视频标签');
    await t.pumpAndSettle();
    final tile = find.byKey(const Key('video-tag-mode'));
    expect(tile, findsOneWidget);
    for (final m in [
      VideoTagMode.hidden,
      VideoTagMode.expanded,
      VideoTagMode.onTap,
    ]) {
      await t.tap(tile);
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('video-tag-choice-${m.name}')));
      await t.pumpAndSettle();
      expect(await VideoTagPreferences.load(), m);
      expect(find.text(m.label), findsOneWidget);
    }
  });
}
