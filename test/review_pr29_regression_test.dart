import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';

/// Returns two pages so filtering the first must not hide the second.
class ReviewSearchService implements BilibiliService {
  final List<int> requestedPages = <int>[];

  /// Produces a low-count first page and an eligible second page.
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    requestedPages.add(page);
    return VideoSearchPage(
      page: page,
      totalPages: 2,
      results: List<VideoSearchResult>.generate(
        page == 1 ? 20 : 1,
        (int index) => VideoSearchResult(
          bvid: page == 1
              ? 'BV1GJ411x7${index.toString().padLeft(2, '0')}'
              : 'BV1GJ411x7h9',
          title: 'Review result',
          ownerName: 'Review',
          duration: Duration.zero,
          thumbnailUrl: '',
          publishedAt: DateTime(2026),
          playCount: page == 1 ? 1 : 1000000,
          danmakuCount: 0,
          episodeCountText: '1',
        ),
      ),
    );
  }

  /// Avoids suggestion requests during the regression test.
  @override
  Future<List<String>> suggestKeywords(String input) async => <String>[];

  /// Rejects unexpected direct video lookups.
  @override
  Future<VideoPreview> lookupVideo(String input) async =>
      throw StateError('unused');
}

/// Verifies users can continue searching after a fully filtered page.
void main() {
  for (final bool enabled in <bool>[false, true]) {
    testWidgets('first page retains pagination, filter=$enabled', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'search.content_filter_v2':
            '{"learningOnly":true,"minimumPlayCount":${enabled ? 500000 : 0}}',
      });
      final service = ReviewSearchService();
      await tester.pumpWidget(MaterialApp(home: SearchPage(service: service)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-input-field')),
        'review',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      if (!enabled) {
        expect(service.requestedPages, <int>[1]);
        await tester.drag(find.byType(ListView).last, const Offset(0, -10000));
      }
      await tester.pumpAndSettle();
      expect(
        service.requestedPages,
        contains(2),
        reason: 'Page 2 has eligible results and must remain reachable.',
      );
    });
  }
}
