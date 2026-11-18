import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:focubili/features/profile/content_blocklist_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/content_blocklist.dart';
import 'package:focubili/models/search_content_filter.dart';
import 'package:focubili/models/user_search.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'package:focubili/services/search_content_filter_service.dart';

VideoSearchResult row(
  String bvid,
  String title, {
  int mid = 42,
  String owner = '同名UP',
  int? category,
}) => VideoSearchResult(
  bvid: bvid,
  title: title,
  ownerName: owner,
  ownerMid: mid,
  duration: const Duration(minutes: 1),
  thumbnailUrl: '',
  publishedAt: null,
  playCount: 100,
  danmakuCount: 0,
  episodeCountText: '1',
  categoryId: category,
);

class BlockSearchService implements BilibiliService {
  int lookups = 0;
  int searches = 0;
  bool offline = false;
  VideoSearchFilter? lastFilter;
  final bool missingMid;
  BlockSearchService({this.missingMid = false});
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    searches++;
    if (offline) throw StateError('offline');
    lastFilter = filter;
    return VideoSearchPage(
      page: 1,
      totalPages: 1,
      results: [
        row('BV1GJ411x7h7', '第一条视频', mid: missingMid ? 0 : 42),
        row('BV1GJ411x7h8', '第二条视频', mid: 43),
      ],
    );
  }

  @override
  Future<List<String>> suggestKeywords(String input) async => [];
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookups++;
    return VideoPreview(
      bvid: input,
      cid: 1,
      title: '第一条视频',
      ownerName: '同名UP',
      ownerMid: 42,
      parts: const [
        VideoPart(
          pageNumber: 1,
          cid: 1,
          title: 'P1',
          duration: Duration(minutes: 1),
        ),
      ],
    );
  }
}

class BlockUserSearchService implements BilibiliUserSearchService {
  @override
  Future<UserSearchPage> searchUsers(
    String keyword, {
    int page = 1,
    UserSearchFilter filter = const UserSearchFilter(),
  }) async => UserSearchPage(
    page: 1,
    totalPages: 1,
    results: [
      for (final mid in [42, 43])
        UserSearchResult(
          mid: mid,
          name: '用户$mid',
          avatarUrl: '',
          signature: '',
          followerCount: 0,
          videoCount: 1,
          level: 1,
          isUploader: true,
          certification: '',
        ),
    ],
  );
}

class RejectingBlocklistStore extends InMemorySharedPreferencesStore {
  RejectingBlocklistStore(super.data) : super.withData();
  bool reject = true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (reject && key == 'flutter.${ContentBlocklistService.storageKey}') {
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class InterruptedFilterStore extends InMemorySharedPreferencesStore {
  InterruptedFilterStore(super.data) : super.withData();
  bool rejectRead = false;
  int filterWrites = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    if (rejectRead) {
      rejectRead = false;
      throw StateError('storage temporarily unavailable');
    }
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.${SearchContentFilterService.storageKey}') {
      filterWrites++;
    }
    return super.setValue(valueType, key, value);
  }
}

Future<void> search(WidgetTester tester, BlockSearchService service) async {
  await tester.pumpWidget(MaterialApp(home: SearchPage(service: service)));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('search-input-field')), '视频');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'new defaults preserve every category; explicit learning rule preserves category-only matches',
    () {
      expect(
        const SearchContentFilter().includes(
          row('BV1GJ411x7h7', '游戏实况', category: 4),
        ),
        isTrue,
      );
      expect(
        const SearchContentFilter(
          learningOnly: true,
        ).includes(row('BV1GJ411x7h7', '独奏', category: 3)),
        isTrue,
      );
    },
  );

  test(
    'title and owner terms are independent literal case-insensitive exclusions',
    () {
      final filter = SearchContentFilter(
        titleKeywords: SearchContentFilter.parseKeywords(
          ' Spoiler, SPOILER\n[C++] ',
        ),
        ownerKeywords: ['STUDIO'],
      );
      expect(filter.titleKeywords, ['Spoiler', '[C++]']);
      expect(filter.includes(row('BV1GJ411x7h7', 'spoILER ahead')), isFalse);
      expect(
        filter.includes(row('BV1GJ411x7h7', '学习视频', owner: 'My Studio')),
        isFalse,
      );
      expect(
        filter.includes(row('BV1GJ411x7h7', 'studio', owner: 'spoiler')),
        isTrue,
      );
      expect(filter.includes(row('BV1GJ411x7h7', 'C programming')), isTrue);
      expect(
        filter.includes(row('BV1GJ411x7h7', '[c++] programming')),
        isFalse,
      );
    },
  );

  test(
    'old settings retain learning and exact play threshold; new terms roundtrip',
    () async {
      SharedPreferences.setMockInitialValues({
        SearchContentFilterService.storageKey: jsonEncode({
          'learningOnly': true,
          'minimumPlayCount': 12345,
        }),
      });
      const service = SearchContentFilterService();
      final old = await service.load();
      expect(old.learningOnly, isTrue);
      expect(old.minimumPlayCount, 12345);
      expect(old.titleKeywords, isEmpty);
      await service.save(
        old.copyWith(titleKeywords: ['Test'], ownerKeywords: ['UP']),
      );
      final restored = await service.load();
      expect(restored.learningOnly, isTrue);
      expect(restored.minimumPlayCount, 12345);
      expect(restored.titleKeywords, ['Test']);
      expect(restored.ownerKeywords, ['UP']);
    },
  );

  test(
    'concurrent service instances preserve both blocks and cancellation survives reload',
    () async {
      const service = ContentBlocklistService();
      await Future.wait([
        service.blockVideo('BV1GJ411x7h7', '标题'),
        const ContentBlocklistService().blockCreator(42, '同名UP'),
      ]);
      var list = await service.load();
      expect(list.videos, {'BV1GJ411x7h7': '标题'});
      expect(list.creators, {42: '同名UP'});
      expect(list.includes(row('BV1GJ411x7h8', '同名但不同UID', mid: 43)), isTrue);
      expect(list.includes(row('BV1GJ411x7h8', '已屏蔽UID', mid: 42)), isFalse);
      await service.unblockVideo('BV1GJ411x7h7');
      await service.unblockCreator(42);
      list = await const ContentBlocklistService().load();
      expect(list.videos, isEmpty);
      expect(list.creators, isEmpty);
    },
  );

  test(
    'unreadable storage is reported and never replaced by a mutation',
    () async {
      SharedPreferences.setMockInitialValues({
        ContentBlocklistService.storageKey: '{broken',
      });
      const service = ContentBlocklistService();
      await expectLater(service.load(), throwsFormatException);
      await expectLater(service.blockCreator(42, 'UP'), throwsFormatException);
      expect(
        (await SharedPreferences.getInstance()).getString(
          ContentBlocklistService.storageKey,
        ),
        '{broken',
      );
    },
  );

  testWidgets(
    'failed unblock leaves the stored and displayed block retryable',
    (tester) async {
      final store = RejectingBlocklistStore({
        'flutter.${ContentBlocklistService.storageKey}': jsonEncode({
          'version': 1,
          'videos': {'BV1GJ411x7h7': '第一条视频'},
          'creators': {},
        }),
      });
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      await tester.pumpWidget(const MaterialApp(home: ContentBlocklistPage()));
      await tester.pumpAndSettle();
      final unblock = find.byKey(const Key('unblock-video-BV1GJ411x7h7'));
      expect(unblock, findsOneWidget);

      await tester.tap(unblock);
      await tester.pumpAndSettle();
      expect(find.text('取消屏蔽失败，请重试。'), findsOneWidget);
      expect(unblock, findsOneWidget);
      expect(
        (await const ContentBlocklistService().load()).videos,
        contains('BV1GJ411x7h7'),
      );

      store.reject = false;
      await tester.tap(unblock);
      await tester.pumpAndSettle();
      expect(find.text('暂无屏蔽的视频'), findsOneWidget);
      expect((await const ContentBlocklistService().load()).videos, isEmpty);
    },
  );

  test('BV identity preserves case and does not match another identifier', () {
    const list = ContentBlocklist(videos: {'BV1GJ411x7h7': 'A'});
    expect(list.blocks(bvid: 'BV1GJ411x7h7', ownerMid: 0), isTrue);
    expect(list.blocks(bvid: 'BV1GJ411X7h7', ownerMid: 0), isFalse);
  });

  test(
    'search parser retains stable creator IDs and category metadata',
    () async {
      final service = BilibiliVideoInfoService(
        requestJson: (_) async => jsonEncode({
          'code': 0,
          'data': {
            'page': 1,
            'numPages': 1,
            'result': [
              {
                'bvid': 'BV1GJ411x7h7',
                'mid': '42',
                'author': '<em>UP</em>',
                'title': '视频',
                'typeid': '188',
                'duration': '1:00',
              },
            ],
          },
        }),
      );
      final result = (await service.searchVideos('视频')).results.single;
      expect(result.ownerMid, 42);
      expect(result.ownerName, 'UP');
      expect(result.categoryId, 188);
    },
  );

  testWidgets(
    'keyword drafts apply, cancel preserves saved terms, reset restores unrestricted search',
    (tester) async {
      await search(tester, BlockSearchService());
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      final titles = find.byKey(const Key('search-title-keywords'));
      await tester.ensureVisible(titles);
      await tester.enterText(titles, '第一');
      final owners = find.byKey(const Key('search-owner-keywords'));
      await tester.ensureVisible(owners);
      await tester.enterText(owners, 'other studio');
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect(find.text('第一条视频'), findsNothing);
      expect(find.text('第二条视频'), findsOneWidget);
      expect((await const SearchContentFilterService().load()).titleKeywords, [
        '第一',
      ]);
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(owners);
      await tester.enterText(owners, '同名');
      await tester.tap(find.byKey(const Key('close-search-filter')));
      await tester.pumpAndSettle();
      expect((await const SearchContentFilterService().load()).ownerKeywords, [
        'other studio',
      ]);
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置'));
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect(find.text('第一条视频'), findsOneWidget);
      expect(find.text('第二条视频'), findsOneWidget);
    },
  );

  testWidgets(
    'reopening search filters after a failed read retains all saved rules',
    (tester) async {
      const storageKey = 'flutter.${SearchContentFilterService.storageKey}';
      final original = jsonEncode({
        'learningOnly': true,
        'minimumPlayCount': 54321,
        'titleKeywords': ['keep-title'],
        'ownerKeywords': ['keep-creator'],
      });
      final store = InterruptedFilterStore({storageKey: original})
        ..rejectRead = true;
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();

      await tester.pumpWidget(
        MaterialApp(home: SearchPage(service: BlockSearchService())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      expect(find.text('keep-title'), findsOneWidget);
      expect(find.text('keep-creator'), findsOneWidget);
      expect(find.text('54321'), findsOneWidget);
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect((await store.getAll())[storageKey], original);
      expect(store.filterWrites, 0);

      store.rejectRead = true;
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      expect(find.text('筛选设置读取失败，未覆盖原设置。请重试。'), findsOneWidget);
      expect(find.text('应用筛选'), findsNothing);
      expect((await store.getAll())[storageKey], original);
      expect(store.filterWrites, 0);

      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      expect(find.text('keep-title'), findsOneWidget);
      expect(find.text('keep-creator'), findsOneWidget);
    },
  );

  testWidgets('local filters work with already loaded videos while offline', (
    tester,
  ) async {
    final service = BlockSearchService();
    await search(tester, service);
    expect(service.searches, 1);
    expect(find.text('第一条视频'), findsOneWidget);
    service.offline = true;

    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    final titles = find.byKey(const Key('search-title-keywords'));
    await tester.ensureVisible(titles);
    await tester.enterText(titles, '第一');
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(service.searches, 1);
    expect(find.text('第一条视频'), findsNothing);
    expect(find.text('第二条视频'), findsOneWidget);

    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置'));
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(service.searches, 1);
    expect(find.text('第一条视频'), findsOneWidget);
    expect(find.text('第二条视频'), findsOneWidget);
    expect(
      (await const SearchContentFilterService().load()).titleKeywords,
      isEmpty,
    );
  });

  testWidgets('blocked BV and management can scroll with short large text', (
    tester,
  ) async {
    await const ContentBlocklistService().blockVideo(
      'BV1GJ411x7h7',
      '这个长视频标题用于确认大字模式下仍能取消屏蔽并返回',
    );
    tester.view.physicalSize = const Size(320, 310);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: SearchPage(service: BlockSearchService()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('search-input-field')),
      'BV1GJ411x7h7',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('管理黑名单'));
    await tester.pumpAndSettle();
    final unblock = find.byKey(const Key('unblock-video-BV1GJ411x7h7'));
    for (var i = 0; i < 8 && unblock.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
    }
    expect(unblock.hitTestable(), findsOneWidget);
    await tester.tap(unblock.hitTestable());
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('第一条视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'category is unrestricted until selected and reset clears the request',
    (tester) async {
      final service = BlockSearchService();
      await search(tester, service);
      expect(service.lastFilter?.categoryId, isNull);
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      final category = find.byKey(const Key('search-category-188'));
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect(service.lastFilter?.categoryId, 188);
      await tester.tap(find.byTooltip('筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置'));
      await tester.tap(find.text('应用筛选'));
      await tester.pumpAndSettle();
      expect(service.lastFilter?.categoryId, isNull);
    },
  );

  testWidgets(
    'persisted BV block also guards direct lookup and cancellation restores it',
    (tester) async {
      await const ContentBlocklistService().blockVideo('BV1GJ411x7h7', '第一条视频');
      await tester.pumpWidget(
        MaterialApp(home: SearchPage(service: BlockSearchService())),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('search-input-field')),
        'BV1GJ411x7h7',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('该视频或 UP 主已被屏蔽。'), findsOneWidget);
      await tester.tap(find.text('管理黑名单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unblock-video-BV1GJ411x7h7')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('第一条视频'), findsOneWidget);
    },
  );

  testWidgets(
    'blocked UID is hidden from user search without hiding another user',
    (tester) async {
      await const ContentBlocklistService().blockCreator(42, '用户42');
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            service: BlockSearchService(),
            userSearchService: BlockUserSearchService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('用户'));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('search-input-field')), '用户');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('user-search-42')), findsNothing);
      expect(find.byKey(const Key('user-search-43')), findsOneWidget);
      expect(find.text('黑名单已隐藏 1 位 UP 主'), findsOneWidget);
    },
  );

  testWidgets(
    'search video menu hides immediately and undo restores raw result',
    (tester) async {
      await search(tester, BlockSearchService());
      await tester.tap(find.byKey(const Key('more-search-BV1GJ411x7h7')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('屏蔽该视频'));
      await tester.pumpAndSettle();
      expect(find.text('第一条视频'), findsNothing);
      expect(find.text('第二条视频'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(find.text('第一条视频'), findsOneWidget);
    },
  );

  testWidgets(
    'creator menu resolves missing UID and management cancellation restores search',
    (tester) async {
      final service = BlockSearchService(missingMid: true);
      await search(tester, service);
      await tester.tap(find.byKey(const Key('more-search-BV1GJ411x7h7')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('屏蔽该 UP 主'));
      await tester.pumpAndSettle();
      expect(service.lookups, 1);
      expect((await const ContentBlocklistService().load()).creators, {
        42: '同名UP',
      });
      // A search result without UID is rechecked against the resolved metadata.
      expect(find.text('第一条视频'), findsNothing);
      expect(find.text('第二条视频'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: ContentBlocklistPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unblock-creator-42')));
      await tester.pumpAndSettle();
      expect(find.text('暂无屏蔽的 UP 主'), findsOneWidget);
      expect((await const ContentBlocklistService().load()).creators, isEmpty);
    },
  );
}
