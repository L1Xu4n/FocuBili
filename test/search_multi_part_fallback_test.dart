import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;

const _bvid = 'BV1GJ411x7h7';
VideoSearchResult _result({int cid = 0, String badge = ''}) =>
    VideoSearchResult(
      bvid: _bvid,
      cid: cid,
      title: 'search title',
      ownerName: 'author',
      duration: const Duration(seconds: 12),
      thumbnailUrl: '',
      publishedAt: null,
      playCount: 1,
      danmakuCount: 1,
      episodeCountText: badge,
    );
VideoPreview _details({int cid = 101, String title = 'complete title'}) =>
    VideoPreview(
      bvid: _bvid,
      cid: cid,
      title: title,
      ownerName: 'author',
      parts: [
        VideoPart(
          pageNumber: 1,
          cid: cid,
          title: 'one',
          duration: const Duration(seconds: 12),
        ),
        const VideoPart(
          pageNumber: 2,
          cid: 102,
          title: 'two',
          duration: Duration(seconds: 20),
        ),
      ],
    );

class _SearchService implements BilibiliService, BilibiliSearchPlaybackService {
  _SearchService(this.result);
  final VideoSearchResult result;
  int details = 0, resolutions = 0;
  final detailGate = Completer<VideoPreview>();
  final partGate = Completer<VideoPreview>();
  @override
  Future<VideoPreview> lookupVideo(String input) {
    details++;
    return detailGate.future;
  }

  @override
  Future<VideoPreview> resolveSearchVideo(VideoSearchResult result) {
    resolutions++;
    return partGate.future;
  }

  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async => VideoSearchPage(results: [result], page: 1, totalPages: 1);
  @override
  Future<List<String>> suggestKeywords(String input) async => [];
}

Future<void> _submit(WidgetTester tester, [String keyword = 'keyword']) async {
  await tester.enterText(find.byType(TextField), keyword);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'render, rebuild and repeated search do not request details for badges',
    (tester) async {
      final service = _SearchService(_result(badge: '全12集'));
      await tester.pumpWidget(MaterialApp(home: SearchPage(service: service)));
      await _submit(tester);
      expect(find.text('全12集'), findsOneWidget);
      await _submit(tester, 'again');
      expect(service.details, 0);
      expect(service.resolutions, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      final missing = _SearchService(_result());
      await tester.pumpWidget(MaterialApp(home: SearchPage(service: missing)));
      await _submit(tester);
      expect(missing.details, 0);
      expect(missing.resolutions, 0);
      expect(find.text('共 2 P'), findsNothing);
    },
  );
  testWidgets(
    'known CID enters actual player before details; detail failure does not stop playback',
    (tester) async {
      final service = _SearchService(_result(cid: 101));
      final playback = FeedbackPlayback();
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(service: service),
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            builder: (_) => PlayerPage(
              video: settings.arguments! as VideoPreview,
              playbackService: playback,
              bilibiliService: service,
            ),
          ),
        ),
      );
      await _submit(tester);
      await tester.tap(find.byKey(const ValueKey('search-$_bvid')));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(playback.onlineOpens, 1);
      expect(service.resolutions, 0);
      expect(service.details, 1);
      service.detailGate.completeError(
        const BilibiliLookupException('HTTP 412'),
      );
      await tester.pumpAndSettle();
      expect(playback.onlineOpens, 1);
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'missing CID waits for explicit parts only, then routes a real CID',
    (tester) async {
      final service = _SearchService(_result());
      VideoPreview? routed;
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(service: service),
          onGenerateRoute: (settings) {
            routed = settings.arguments! as VideoPreview;
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('player destination')),
            );
          },
        ),
      );
      await _submit(tester);
      await tester.tap(find.byKey(const ValueKey('search-$_bvid')));
      await tester.pump();
      expect(service.resolutions, 1);
      expect(service.details, 0);
      expect(routed, isNull);
      service.partGate.complete(
        _result().toPlaybackPreview(parts: _details().parts),
      );
      await tester.pumpAndSettle();
      expect(routed!.cid, 101);
      expect(routed!.parts.length, 2);
      expect(routed!.detailsComplete, isFalse);
    },
  );
  testWidgets('failed part resolution leaves search result and never routes', (
    tester,
  ) async {
    final service = _SearchService(_result());
    await tester.pumpWidget(MaterialApp(home: SearchPage(service: service)));
    await _submit(tester);
    await tester.tap(find.byKey(const ValueKey('search-$_bvid')));
    await tester.pump();
    service.partGate.completeError(
      const BilibiliLookupException('没有真实的分 P 编号。'),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有真实的分 P 编号。'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-$_bvid')), findsOneWidget);
    expect(service.details, 0);
  });
  testWidgets('old part result after a new query never routes', (tester) async {
    final service = _SearchService(_result());
    var routes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(service: service),
        onGenerateRoute: (_) {
          routes++;
          return null;
        },
      ),
    );
    await _submit(tester);
    await tester.tap(find.byKey(const ValueKey('search-$_bvid')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'next keyword');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    service.partGate.complete(
      _result().toPlaybackPreview(parts: _details().parts),
    );
    await tester.pumpAndSettle();
    expect(routes, 0);
    expect(tester.takeException(), isNull);
  });
  for (final sameCid in [true, false]) {
    testWidgets(
      'optional details ${sameCid ? 'update same video' : 'reject mismatched CID'} without reopening',
      (tester) async {
        final service = _SearchService(_result(cid: 101));
        final playback = FeedbackPlayback();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              video: _result(cid: 101).toPlaybackPreview(),
              bilibiliService: service,
              playbackService: playback,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(playback.onlineOpens, 1);
        service.detailGate.complete(_details(cid: sameCid ? 101 : 999));
        await tester.pumpAndSettle();
        expect(playback.onlineOpens, 1);
        expect(
          find.text('complete title'),
          sameCid ? findsWidgets : findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('disposed player cannot publish late details', (tester) async {
    final service = _SearchService(_result(cid: 101));
    final playback = FeedbackPlayback();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _result(cid: 101).toPlaybackPreview(),
          bilibiliService: service,
          playbackService: playback,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    service.detailGate.complete(_details());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(playback.onlineOpens, 1);
  });
}
