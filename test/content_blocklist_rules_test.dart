import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/features/profile/content_blocklist_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/content_blocklist.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/content_blocklist_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _evidencePath = String.fromEnvironment('BLOCK_RULE_EVIDENCE');
const _evidenceFont = String.fromEnvironment('BLOCK_RULE_FONT');

Future<void> _capture(WidgetTester tester, GlobalKey? key, String name) async {
  if (_evidencePath.isEmpty || key == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_evidencePath/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

String _bvid(int index) => 'BV1SYN411za$index';

Map<String, Object> _row(
  int index,
  String title,
  String author, {
  int? uid,
  String? tag,
}) => {
  'bvid': _bvid(index),
  'title': title,
  'author': author,
  'mid': uid ?? index + 102,
  // Leave the app's unrelated, pre-existing episode badge lookup disabled
  // here so any tag-driven per-row network request would fail the assertion.
  'episode_count_text': '共 1 P',
  'tag': ?tag,
};

class _PublicSearchFixture {
  final requests = <Uri>[];
  bool failTags = false;
  Completer<void>? tagGate;

  Future<String> call(Uri uri) async {
    requests.add(uri);
    if (uri.path == '/x/tag/archive/tags') {
      await tagGate?.future;
      if (failTags) throw StateError('synthetic unavailable tag endpoint');
    }
    final payload = switch (uri.path) {
      '/x/web-interface/wbi/search/type' =>
        uri.queryParameters['search_type'] == 'bili_user'
            ? {
                'result': [
                  {'mid': 101, 'uname': '手动 UID 账号'},
                  {'mid': 102, 'uname': 'Math Lab'},
                  {'mid': 103, 'uname': 'Math Lab 第二频道'},
                  {'mid': 104, 'uname': '晚间 CLIP 剪辑'},
                ],
                'numPages': 1,
              }
            : {
                'result': [
                  if (uri.queryParameters['keyword'] == '下一次搜索')
                    _row(9, '新的搜索结果', '测试教室')
                  else ...[
                    _row(1, '命中 UID', '改名后仍命中', uid: 101),
                    _row(2, '命中完整昵称', ' Math Lab '),
                    _row(3, '命中昵称关键词', '晚间 CLIP 剪辑'),
                    _row(4, '本周直播预告：周末见', '课程工作室'),
                    _row(5, '命中独立标签', '会写笔记', tag: '系统基础, 命令行 ,'),
                    _row(6, '更长标签不匹配', 'Math Lab 第二频道', tag: '系统基础笔记'),
                    _row(7, '只有详情能确认标签', '测试教室'),
                    _row(8, '不含标签但仍可播放', '直播预告'),
                  ],
                ],
                'numPages': 1,
              },
      '/x/web-interface/view' => {
        'bvid': uri.queryParameters['bvid'],
        'cid': 701,
        'title': '已读取详情',
        'owner': {'name': '测试教室', 'mid': 31337},
        'pages': [
          {'cid': 701, 'page': 1, 'part': '测试 P1', 'duration': 60},
        ],
      },
      '/x/tag/archive/tags' => [
        if (uri.queryParameters['bvid'] == _bvid(7)) {'tag_name': ' 系统基础 '},
      ],
      _ => throw StateError('unexpected synthetic request: ${uri.path}'),
    };
    return jsonEncode({'code': 0, 'data': payload});
  }
}

class _CachedTagFixture implements BilibiliService, BilibiliVideoTagSource {
  int tagRequests = 0;

  @override
  Future<VideoPreview> lookupVideo(String input) async => VideoPreview(
    bvid: input,
    cid: 1,
    title: '本机缓存视频',
    ownerName: '示例账号',
    fromOfflineCache: true,
    parts: const [
      VideoPart(pageNumber: 1, cid: 1, title: 'P1', duration: Duration.zero),
    ],
  );

  @override
  Future<List<String>> loadVideoTags(String bvid) async {
    tagRequests++;
    return ['系统基础'];
  }

  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async => throw StateError('expected a direct search');

  @override
  Future<List<String>> suggestKeywords(String input) async => [];
}

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const Key('search-input-field')), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _management({GlobalKey? key, double scale = 1}) {
  final app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(
      textTheme: _evidencePath.isEmpty
          ? null
          : ThemeData.dark().textTheme.apply(fontFamily: 'BlockRuleEvidence'),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    initialRoute: '/blacklist',
    routes: {
      '/': (_) => const Scaffold(),
      '/blacklist': (_) => const ContentBlocklistPage(),
    },
  );
  return key == null ? app : RepaintBoundary(key: key, child: app);
}

Future<void> _pickKind(WidgetTester tester, String label) async {
  final dropdown = find.byKey(const Key('block-rule-kind'));
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String input) async {
  final field = find.byKey(const Key('block-rule-value'));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, input);
  await tester.pumpAndSettle();
}

final _save = find.byKey(const Key('save-block-rule'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'legacy UID and BV blocks survive atomic rule edits and reloads',
    () async {
      SharedPreferences.setMockInitialValues({
        ContentBlocklistService.storageKey: jsonEncode({
          'version': 1,
          'creators': {'42': '已有显示名'},
          'videos': {'BV1GJ411x7h7': '旧屏蔽'},
        }),
      });
      const a = ContentBlocklistService();
      const b = ContentBlocklistService();
      const exact = ContentBlockRule(
        ContentBlockKind.creatorName,
        ' Math Lab ',
      );
      const tag = ContentBlockRule(ContentBlockKind.videoTag, '系统基础');
      await Future.wait([a.saveRule(exact), b.saveRule(tag)]);
      await expectLater(
        a.saveRule(
          const ContentBlockRule(ContentBlockKind.creatorUid, '00042'),
        ),
        throwsArgumentError,
      );
      await expectLater(
        b.saveRule(
          const ContentBlockRule(ContentBlockKind.creatorName, 'math LAB'),
        ),
        throwsArgumentError,
      );
      for (final invalid in [
        '0',
        '-1',
        '+42',
        '2.1',
        '4 2',
        '9999999999999999999999',
      ]) {
        await expectLater(
          a.saveRule(ContentBlockRule(ContentBlockKind.creatorUid, invalid)),
          throwsArgumentError,
        );
      }
      for (final invalid in [' ', '\n\t', '第一行\n第二行', '新' * 101]) {
        await expectLater(
          a.saveRule(
            ContentBlockRule(ContentBlockKind.creatorKeyword, invalid),
          ),
          throwsArgumentError,
        );
      }
      final archived = await b.load();
      expect(archived.creators, {42: '已有显示名'});
      expect(archived.videos, {'BV1GJ411x7h7': '旧屏蔽'});
      expect(archived.rules, {
        ContentBlockKind.creatorName: ['Math Lab'],
        ContentBlockKind.videoTag: ['系统基础'],
      });
      expect(archived.blocksCreator(uid: 42, nickname: '改名后'), isTrue);
      expect(archived.blocksCreator(uid: 11, nickname: '已有显示名'), isFalse);
      expect(archived.blocksCreator(uid: 11, nickname: 'math lab'), isTrue);
      expect(
        archived.blocksCreator(uid: 11, nickname: 'Math Lab 第二频道'),
        isFalse,
      );
      const edited = ContentBlockRule(ContentBlockKind.creatorName, '物理实验室');
      await a.saveRule(edited, previous: exact);
      await b.removeRule(tag);
      await expectLater(a.saveRule(tag, previous: tag), throwsArgumentError);
      final reloaded = await b.load();
      expect(reloaded.rules, {
        ContentBlockKind.creatorName: ['物理实验室'],
      });
      expect(reloaded.creators, archived.creators);
      expect(reloaded.videos, archived.videos);
    },
  );

  test(
    'nickname and title terms are literal and never match the wrong field',
    () {
      const list = ContentBlocklist(
        rules: {
          ContentBlockKind.creatorKeyword: ['[LAB]'],
          ContentBlockKind.videoTitleKeyword: ['C++'],
          ContentBlockKind.videoTag: ['C++系统'],
        },
      );
      bool blocks(String name, String title, List<String> tags) => list.blocks(
        bvid: _bvid(1),
        ownerMid: 0,
        ownerName: name,
        title: title,
        tags: tags,
      );
      expect(blocks('数理[lab]课堂', '日常', []), isTrue);
      expect(blocks('LAB', '[LAB] 日常', ['前缀C++系统']), isFalse);
      expect(blocks('其他', 'C++语法', []), isTrue);
      expect(blocks('C++编程', '日常', ['C++']), isFalse);
      expect(blocks('', '日常', [' c++系统 ']), isTrue);
      expect(blocks('', '日常', []), isFalse);
    },
  );

  testWidgets(
    'actual search parser and rows enforce five rule kinds without tag fan-out',
    (tester) async {
      _viewport(tester, const Size(920, 1200));
      const rules = ContentBlocklistService();
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.creatorUid, '101'),
      );
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.creatorName, 'math lab'),
      );
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.creatorKeyword, 'clip'),
      );
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.videoTitleKeyword, '直播预告'),
      );
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.videoTag, '系统基础'),
      );

      final fixture = _PublicSearchFixture();
      final bili = BilibiliVideoInfoService(requestJson: fixture.call);
      await tester.pumpWidget(
        MaterialApp(
          routes: {
            AppRoutes.player: (_) =>
                Scaffold(appBar: AppBar(), body: const Text('测试播放器路由')),
          },
          home: SearchPage(service: bili, userSearchService: bili),
        ),
      );
      await tester.pumpAndSettle();
      await _submit(tester, '测试教程');
      for (var i = 1; i <= 8; i++) {
        expect(
          find.byKey(ValueKey('search-${_bvid(i)}')),
          i <= 5 ? findsNothing : findsOneWidget,
        );
      }
      expect(fixture.requests.map((uri) => uri.path), [
        '/x/web-interface/wbi/search/type',
      ]);
      expect(find.textContaining('黑名单 5 条'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('search-${_bvid(6)}')));
      await tester.pumpAndSettle();
      expect(find.text('测试播放器路由'), findsOneWidget);
      expect(fixture.requests.last.path, '/x/web-interface/view');
      expect(fixture.requests.length, 2);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('search-${_bvid(7)}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('search-${_bvid(7)}')), findsNothing);
      expect(find.text('这条视频命中黑名单规则，未打开。'), findsOneWidget);
      expect(find.text('测试播放器路由'), findsNothing);
      expect(fixture.requests.map((uri) => uri.path), [
        '/x/web-interface/wbi/search/type',
        '/x/web-interface/view',
        '/x/web-interface/view',
        '/x/tag/archive/tags',
      ]);
      fixture.failTags = true;
      await tester.tap(find.byKey(ValueKey('search-${_bvid(8)}')));
      await tester.pumpAndSettle();
      expect(find.text('测试播放器路由'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      fixture.failTags = false;

      await _submit(tester, _bvid(7));
      expect(find.text('该视频或 UP 主已被屏蔽。'), findsOneWidget);
      final requestCount = fixture.requests.length;
      await tester.tap(find.text('管理黑名单'));
      await tester.pumpAndSettle();
      final tagRule = find.byKey(const ValueKey('block-rule-videoTag-系统基础'));
      await tester.ensureVisible(tagRule);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: tagRule, matching: find.byTooltip('管理规则')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除规则'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('direct-${_bvid(7)}')), findsOneWidget);
      expect(fixture.requests.length, requestCount);

      await _submit(tester, _bvid(8));
      expect(find.byKey(ValueKey('direct-${_bvid(8)}')), findsOneWidget);
      expect(fixture.requests.skip(requestCount).map((uri) => uri.path), [
        '/x/web-interface/view',
      ]);

      await tester.tap(find.text('用户'));
      await tester.pumpAndSettle();
      await _submit(tester, '测试用户');
      expect(find.byKey(const Key('user-search-101')), findsNothing);
      expect(find.byKey(const Key('user-search-102')), findsNothing);
      expect(find.byKey(const Key('user-search-103')), findsOneWidget);
      expect(find.byKey(const Key('user-search-104')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late optional tag lookup cannot replace a newer search', (
    tester,
  ) async {
    _viewport(tester, const Size(920, 1200));
    await const ContentBlocklistService().saveRule(
      const ContentBlockRule(ContentBlockKind.videoTag, '系统基础'),
    );
    final fixture = _PublicSearchFixture()..tagGate = Completer<void>();
    final bili = BilibiliVideoInfoService(requestJson: fixture.call);
    await tester.pumpWidget(
      MaterialApp(
        routes: {
          AppRoutes.player: (_) => const Scaffold(body: Text('测试播放器路由')),
        },
        home: SearchPage(service: bili),
      ),
    );
    await tester.pumpAndSettle();
    await _submit(tester, '测试教程');
    final untagged = find.byKey(ValueKey('search-${_bvid(8)}'));
    // Some results can be below the viewport, so display the real card first.
    final scrollable = find.descendant(
      of: find.byType(SearchPage),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    await tester.scrollUntilVisible(untagged, 220, scrollable: scrollable.last);
    await tester.ensureVisible(untagged);
    await tester.pumpAndSettle();
    await tester.tap(untagged);
    await tester.pump();
    expect(fixture.requests.last.path, '/x/tag/archive/tags');
    await _submit(tester, '下一次搜索');
    fixture.tagGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('新的搜索结果'), findsOneWidget);
    expect(find.text('测试播放器路由'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a cached video keeps its offline path when tag metadata is missing',
    (tester) async {
      const rules = ContentBlocklistService();
      await rules.saveRule(
        const ContentBlockRule(ContentBlockKind.videoTag, '系统基础'),
      );
      final fixture = _CachedTagFixture();
      await tester.pumpWidget(MaterialApp(home: SearchPage(service: fixture)));
      await tester.pumpAndSettle();
      await _submit(tester, _bvid(1));
      expect(find.byKey(ValueKey('direct-${_bvid(1)}')), findsOneWidget);
      expect(fixture.tagRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty blacklist exposes rule types, add edit delete and cancel',
    (tester) async {
      _viewport(tester, const Size(390, 844));
      final key = GlobalKey();
      if (_evidencePath.isNotEmpty) {
        final font = File(_evidenceFont).readAsBytesSync();
        await (FontLoader(
          'BlockRuleEvidence',
        )..addFont(Future.value(ByteData.sublistView(font)))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      await tester.pumpWidget(_management(key: key));
      await tester.pumpAndSettle();
      await _capture(tester, key, '01-empty');

      final addCreator = find.byKey(const Key('add-creator-block-rule'));
      await tester.tap(addCreator);
      await tester.pumpAndSettle();
      await _enter(tester, 'abc');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('请输入有效的正整数 UID。'), findsOneWidget);
      await _enter(tester, '000314');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('UID 314'), findsOneWidget);

      await tester.tap(find.byKey(const Key('edit-creator-uid-314')));
      await tester.pumpAndSettle();
      await _enter(tester, '315');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('UID 314'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-creator-uid-314')));
      await tester.pumpAndSettle();
      await _enter(tester, '000315');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('UID 314'), findsNothing);
      expect(find.text('UID 315'), findsOneWidget);

      await tester.tap(addCreator);
      await tester.pumpAndSettle();
      await _pickKind(tester, '完整昵称（精确）');
      await _enter(tester, '数学实验室');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      final nickname = find.byKey(
        const ValueKey('block-rule-creatorName-数学实验室'),
      );
      expect(nickname, findsOneWidget);
      await tester.tap(
        find.descendant(of: nickname, matching: find.byTooltip('管理规则')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑规则'));
      await tester.pumpAndSettle();
      await _enter(tester, '物理实验室');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(nickname, findsNothing);
      expect(find.text('物理实验室'), findsOneWidget);

      await tester.tap(addCreator);
      await tester.pumpAndSettle();
      await _pickKind(tester, '昵称关键词（包含）');
      await _enter(tester, '演示剪辑');
      await tester.tap(_save);
      await tester.pumpAndSettle();

      final addVideo = find.byKey(const Key('add-video-block-rule'));
      await tester.tap(addVideo);
      await tester.pumpAndSettle();
      await _enter(tester, '系统基础');
      await _capture(tester, key, '02-tag-editor');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      final tag = find.byKey(const ValueKey('block-rule-videoTag-系统基础'));
      expect(tag, findsOneWidget);

      await tester.tap(addVideo);
      await tester.pumpAndSettle();
      await _pickKind(tester, '标题关键词（包含）');
      await _enter(tester, '直播预告');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      await _capture(tester, key, '03-saved-rules');
      await tester.tap(
        find.descendant(of: tag, matching: find.byTooltip('管理规则')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除规则'));
      await tester.pumpAndSettle();
      expect(tag, findsNothing);
      final list = await const ContentBlocklistService().load();
      expect(list.creators, {315: ''});
      expect(list.rules, {
        ContentBlockKind.creatorName: ['物理实验室'],
        ContentBlockKind.creatorKeyword: ['演示剪辑'],
        ContentBlockKind.videoTitleKeyword: ['直播预告'],
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact large-text rule editor survives duplicate validation and keyboard',
    (tester) async {
      _viewport(tester, const Size(320, 540));
      addTearDown(tester.view.resetViewInsets);
      const service = ContentBlocklistService();
      await service.saveRule(
        const ContentBlockRule(ContentBlockKind.videoTitleKeyword, 'C++'),
      );
      await tester.pumpWidget(_management(scale: 2));
      await tester.pumpAndSettle();
      final add = find.byKey(const Key('add-video-block-rule'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      await _pickKind(tester, '标题关键词（包含）');
      await _enter(tester, ' c++ ');
      tester.view.viewInsets = const FakeViewPadding(bottom: 175);
      await tester.pumpAndSettle();
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('这条规则已存在。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect((await service.load()).rules, {
        ContentBlockKind.videoTitleKeyword: ['C++'],
      });
    },
  );
}
