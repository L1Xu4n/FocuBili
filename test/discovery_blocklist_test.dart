import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/common/discovery_blocklist.dart';
import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/features/subscriptions/subscription_home_card.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/models/content_blocklist.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_interaction_service.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;
import 'subscription_service_test.dart' show Content;

const _evidence = String.fromEnvironment('DISCOVERY_BLOCK_EVIDENCE');
const _font = String.fromEnvironment('DISCOVERY_BLOCK_FONT');

class _Posts implements BilibiliPublicContentService {
  final pages = <int>[];

  @override
  Future<CreatorProfile> loadProfile(int mid) async => CreatorProfile(
    mid: mid,
    name: '演示课室',
    avatarUrl: '',
    sign: '',
    officialDescription: '',
  );

  @override
  Future<CreatorContentPage<CreatorVideo>> loadVideos(
    int mid, {
    int page = 1,
    String keyword = '',
    CreatorVideoOrder order = CreatorVideoOrder.latest,
  }) async {
    pages.add(page);
    return CreatorContentPage(
      items: page == 1
          ? const [
              CreatorVideo(
                bvid: 'BV1SYN411za1',
                title: '第一条演示预告',
                partCount: 2,
                coverUrl: '',
                duration: Duration(minutes: 1),
              ),
              CreatorVideo(
                bvid: 'BV1SYN411za2',
                title: '第二条被标签命中的投稿',
                partCount: 2,
                tags: ['屏蔽标签'],
                coverUrl: '',
                duration: Duration(minutes: 2),
              ),
            ]
          : const [
              CreatorVideo(
                bvid: 'BV1SYN411za3',
                title: '后续可见教程',
                partCount: 2,
                coverUrl: '',
                duration: Duration(minutes: 3),
              ),
            ],
      page: page,
      hasMore: page == 1,
      totalCount: 3,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoFollowingRequest extends BilibiliInteractionService {
  @override
  Future<bool> loadFollowingState(int mid) async => false;
}

class _NoVideoRequests implements BilibiliService, BilibiliVideoTagSource {
  int views = 0, tags = 0;
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    views++;
    throw StateError('discovery filtering may not fetch video details');
  }

  @override
  Future<List<String>> loadVideoTags(String bvid) async {
    tags++;
    throw StateError('discovery filtering may not fetch tags');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(Widget child, GlobalKey key) => RepaintBoundary(
  key: key,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _evidence.isEmpty
        ? ThemeData.dark()
        : ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'DiscoveryChinese',
            ),
          ),
    home: child,
  ),
);

Future<void> _capture(WidgetTester tester, GlobalKey key, String label) async {
  if (_evidence.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_evidence/$label.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 920);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

SubscriptionFeedItem _update(
  String bvid, {
  Map<String, String> sources = const {},
}) => SubscriptionFeedItem(
  bvid: bvid,
  title: '公开更新',
  coverUrl: '',
  sources: sources,
  discoveredAt: DateTime(2026, 10, 10),
);

class _FlakyRuleDisk extends InMemorySharedPreferencesStore {
  _FlakyRuleDisk(super.data) : super.withData();
  final firstRead = Completer<void>();
  bool broken = true;

  @override
  Future<Map<String, Object>> getAll() async {
    await firstRead.future;
    if (broken) throw StateError('synthetic preference read failure');
    return super.getAll();
  }
}

String _discoveryFeedFixture(int count) {
  final data = jsonDecode(feedFixture(count: count)) as Map;
  for (final (index, entry) in (data['feed'] as List).indexed) {
    entry['bvid'] = 'BV1SYN411za${index + 1}';
  }
  return jsonEncode(data);
}

String _savedVideoBlocks(Iterable<String> ids) => jsonEncode({
  'version': 1,
  'videos': {for (final id in ids) id: '合成稿件'},
  'creators': {},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    if (_evidence.isEmpty) return;
    final font = File(_font).readAsBytesSync();
    await (FontLoader(
      'DiscoveryChinese',
    )..addFont(Future.value(ByteData.sublistView(font)))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test(
    'does not mistake a collection owner or source label for video authorship',
    () {
      const list = ContentBlocklist(
        creators: {42: '旧 UID 标签'},
        rules: {
          ContentBlockKind.creatorName: ['演示课室'],
          ContentBlockKind.videoTag: ['屏蔽标签'],
        },
      );
      expect(
        blocksSubscriptionUpdate(
          list,
          _update('collection', sources: {'collection:42:11': '演示课室'}),
        ),
        isFalse,
      );
      expect(
        blocksSubscriptionUpdate(
          list,
          _update(
            'creator',
            sources: {'creator:42': '旧源名称', 'collection:12:14': '另外的合集'},
          ),
        ),
        isTrue,
      );
      expect(
        blocksSubscriptionUpdate(
          list,
          _update(
            'ambiguous',
            sources: {'creator:42': '来源1', 'creator:11': '演示课室'},
          ),
        ),
        isFalse,
      );
      expect(
        blocksSubscriptionUpdate(
          list,
          _update('unknown', sources: {'creator:11': '演示课室'}),
        ),
        isFalse,
      );
      bool post(CreatorVideo video) =>
          blocksCreatorPost(list, video, profileMid: 42, profileName: '演示课室');
      expect(
        post(
          const CreatorVideo(
            bvid: 'unknown-post',
            title: '不同作者已知 UID',
            ownerMid: 11,
            coverUrl: '',
            duration: Duration.zero,
          ),
        ),
        isFalse,
      );
      expect(
        post(
          const CreatorVideo(
            bvid: 'author-name',
            title: '不同作者仅已知昵称',
            ownerName: '其他频道',
            coverUrl: '',
            duration: Duration.zero,
          ),
        ),
        isFalse,
      );
      expect(
        post(
          const CreatorVideo(
            bvid: 'profile-post',
            title: '仅关联主页',
            coverUrl: '',
            duration: Duration.zero,
          ),
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'all hidden creator posts preserve count, raw paging and live restore',
    (tester) async {
      _viewport(tester);
      const blacklist = ContentBlocklistService();
      const title = ContentBlockRule(
        ContentBlockKind.videoTitleKeyword,
        '演示预告',
      );
      const tag = ContentBlockRule(ContentBlockKind.videoTag, '屏蔽标签');
      await blacklist.saveRule(title);
      await blacklist.saveRule(tag);
      final public = _Posts();
      final videos = _NoVideoRequests();
      final key = GlobalKey();
      await tester.pumpWidget(
        _host(
          UserProfilePage(
            mid: 42,
            publicContentService: public,
            videoService: videos,
            interactionService: _NoFollowingRequest(),
          ),
          key,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('共3投稿'), findsOneWidget);
      expect(find.text('第一条演示预告'), findsNothing);
      expect(find.text('第二条被标签命中的投稿'), findsNothing);
      expect(find.text('黑名单已隐藏 2 条'), findsOneWidget);
      expect(find.text('暂无公开投稿'), findsNothing);
      expect(public.pages, [1]);
      await _capture(tester, key, '01-posts-hidden-next-page');
      await tester.tap(find.text('管理黑名单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('规则范围和缺失资料'));
      await tester.pumpAndSettle();
      expect(find.textContaining('优先用视频作者'), findsOneWidget);
      expect(find.textContaining('有冲突的多个来源不会被当成作者'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(public.pages, [1]);

      await tester.tap(find.text('继续加载下一页'));
      await tester.pumpAndSettle();
      expect(find.text('后续可见教程'), findsOneWidget);
      expect(find.text('共3投稿'), findsOneWidget);
      expect(public.pages, [1, 2]);
      expect(find.text('继续加载下一页'), findsNothing);

      await blacklist.removeRule(title);
      await blacklist.removeRule(tag);
      await tester.pumpAndSettle();
      expect(find.text('第一条演示预告'), findsOneWidget);
      expect(find.text('第二条被标签命中的投稿'), findsOneWidget);
      expect(find.text('黑名单已隐藏 2 条'), findsNothing);
      expect(public.pages, [1, 2]);
      expect(videos.views, 0);
      expect(videos.tags, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'subscription card filters before its limit, feed keeps hidden unread and raw storage',
    (tester) async {
      _viewport(tester);
      final raw = jsonDecode(feedFixture(count: 5, sourceCount: 2)) as Map;
      final feed = raw['feed'] as List;
      final titles = [
        '演示预告',
        '被明确 UID 命中的更新',
        '只有合集来源的更新',
        '只有订阅来源名称的更新',
        '首页第三条可见更新',
      ];
      for (var i = 0; i < titles.length; i++) {
        feed[i]['title'] = titles[i];
        feed[i]['sources'] = switch (i) {
          1 => {'creator:2': '测试账号'},
          2 => {'collection:2:8': '测试合集'},
          3 => {'creator:1': '测试账号'},
          _ => {'creator:1': '其他频道'},
        };
      }
      final store = CountingSnapshots()..value = jsonEncode(raw);
      final service = SubscriptionService(
        snapshotStore: store,
        contentService: Content(),
        clock: () => DateTime(2026, 10, 10, 12),
      );
      addTearDown(service.dispose);
      await service.initialize();
      final baseline = store.value;
      final writes = store.saves;
      final videos = _NoVideoRequests();
      final key = GlobalKey();
      const rules = ContentBlocklistService();
      const keyword = ContentBlockRule(
        ContentBlockKind.videoTitleKeyword,
        '预告',
      );
      await rules.saveRule(keyword);
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.creatorUid, '2'),
      );
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.creatorName, '测试账号'),
      );
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: SubscriptionHomeCard(service: service, videoService: videos),
          ),
          key,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最近收到 · 5 条未读'), findsOneWidget);
      expect(find.text('黑名单已隐藏 2 条'), findsOneWidget);
      for (final (index, title) in titles.indexed) {
        expect(find.text(title), index < 2 ? findsNothing : findsOneWidget);
      }
      expect(service.feed, hasLength(5));
      expect(service.unreadCount, 5);
      expect(store.saves, writes);
      expect(store.value, baseline);
      await _capture(tester, key, '02-subscription-home');

      await tester.tap(find.byTooltip('查看全部订阅更新'));
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionUpdatesPage), findsOneWidget);
      expect(find.text('黑名单已隐藏 2 条'), findsOneWidget);
      expect(find.text('显示项标为已读'), findsOneWidget);
      await _capture(tester, key, '03-subscription-feed');
      expect(store.value, baseline);
      await tester.tap(find.text('显示项标为已读'));
      await tester.pumpAndSettle();
      expect(service.unreadCount, 2);
      expect(
        service.feed
            .where((item) => item.readAt == null)
            .map((item) => item.title),
        titles.take(2),
      );
      final afterExplicitRead = store.value;

      await rules.removeRule(keyword);
      await tester.pumpAndSettle();
      expect(find.text(titles.first), findsOneWidget);
      expect(find.text('黑名单已隐藏 1 条'), findsOneWidget);
      expect(service.unreadCount, 2);
      expect(store.value, afterExplicitRead);
      expect(videos.views, 0);
      expect(videos.tags, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cold failed rules never expose rows or permit mark-all before retry',
    (tester) async {
      _viewport(tester);
      final store = CountingSnapshots()..value = _discoveryFeedFixture(2);
      final servicePrefs = await SharedPreferences.getInstance();
      final service = SubscriptionService(
        preferencesLoader: () async => servicePrefs,
        snapshotStore: store,
        contentService: Content(),
        clock: () => DateTime(2026, 10, 10, 12),
      );
      addTearDown(service.dispose);
      await service.initialize();
      final hidden = service.feed.first;
      final snapshot = store.value;
      SharedPreferences.setMockInitialValues({});
      final disk = _FlakyRuleDisk({
        'flutter.${ContentBlocklistService.storageKey}': _savedVideoBlocks([
          hidden.bvid,
        ]),
      });
      SharedPreferencesStorePlatform.instance = disk;
      await tester.pumpWidget(
        _host(SubscriptionUpdatesPage(service: service), GlobalKey()),
      );
      await tester.pump();
      expect(find.text(hidden.title), findsNothing);
      disk.firstRead.complete();
      await tester.pumpAndSettle();

      expect(find.text('黑名单读取失败，内容暂未显示。'), findsOneWidget);
      final all = find.widgetWithText(TextButton, '全部标为已读');
      expect(tester.widget<TextButton>(all).onPressed, isNull);
      expect(service.unreadCount, 2);
      expect(store.value, snapshot);

      disk.broken = false;
      await tester.tap(find.text('重试读取黑名单'));
      await tester.pumpAndSettle();
      expect(find.text(hidden.title), findsNothing);
      expect(find.text('黑名单已隐藏 1 条'), findsOneWidget);
      await tester.tap(find.text('显示项标为已读'));
      await tester.pumpAndSettle();
      expect(
        service.feed.singleWhere((item) => item.bvid == hidden.bvid).readAt,
        isNull,
      );
      expect(service.unreadCount, 1);
    },
  );

  testWidgets(
    'failed background refresh keeps last display and blocks a stale action',
    (tester) async {
      _viewport(tester);
      final prefs = await SharedPreferences.getInstance();
      final store = CountingSnapshots()..value = _discoveryFeedFixture(3);
      final service = SubscriptionService(
        snapshotStore: store,
        contentService: Content(),
        clock: () => DateTime(2026, 10, 10, 12),
      );
      addTearDown(service.dispose);
      await service.initialize();
      final oldestView = service.feed.toList();
      final priorHidden = oldestView.first;
      final newHidden = oldestView[1];
      final snapshot = store.value;
      await prefs.setString(
        ContentBlocklistService.storageKey,
        _savedVideoBlocks([priorHidden.bvid]),
      );
      await tester.pumpWidget(
        _host(SubscriptionUpdatesPage(service: service), GlobalKey()),
      );
      await tester.pumpAndSettle();
      final mark = find.widgetWithText(TextButton, '显示项标为已读');
      final oldCallback = tester.widget<TextButton>(mark).onPressed!;
      expect(find.text(priorHidden.title), findsNothing);
      expect(find.text(newHidden.title), findsOneWidget);

      await prefs.setString(ContentBlocklistService.storageKey, '坏的规则快照');
      ContentBlocklistService.changes.value++;
      oldCallback();
      await tester.pumpAndSettle();
      expect(find.text('黑名单读取失败，使用上次规则显示，相关操作已暂停。'), findsOneWidget);
      expect(find.text(priorHidden.title), findsNothing);
      expect(find.text(newHidden.title), findsOneWidget);
      expect(tester.widget<TextButton>(mark).onPressed, isNull);
      expect(store.value, snapshot);

      await prefs.setString(
        ContentBlocklistService.storageKey,
        _savedVideoBlocks([priorHidden.bvid, newHidden.bvid]),
      );
      await tester.tap(find.text('重试读取黑名单'));
      await tester.pumpAndSettle();
      expect(find.text('黑名单已隐藏 2 条'), findsOneWidget);
      oldCallback();
      await tester.pumpAndSettle();
      expect(
        service.feed
            .where((item) => item.readAt == null)
            .map((item) => item.bvid),
        [priorHidden.bvid, newHidden.bvid],
      );
      expect(service.unreadCount, 2);
    },
  );
}
