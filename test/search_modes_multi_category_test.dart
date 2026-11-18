import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/user_search.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

VideoSearchPage _videoPage(
  int page,
  String title, {
  int id = 1,
  int? totalPages,
}) => VideoSearchPage(
  results: [
    VideoSearchResult(
      bvid: 'BV${id.toString().padLeft(10, '0')}',
      title: title,
      ownerName: 'UP-$id',
      duration: const Duration(minutes: 20),
      thumbnailUrl: '',
      publishedAt: null,
      playCount: 100 * id,
      danmakuCount: id,
      episodeCountText: '共 2 P',
    ),
  ],
  page: page,
  totalPages: totalPages ?? page,
);

UserSearchPage _userPage(int page, String name) => UserSearchPage(
  results: [
    UserSearchResult(
      mid: 42,
      name: name,
      avatarUrl: '',
      signature: '',
      followerCount: 128,
      videoCount: 4,
      level: 6,
      isUploader: true,
      certification: '',
    ),
  ],
  page: page,
  totalPages: page,
);

class _Service implements BilibiliService, BilibiliUserSearchService {
  _Service({this.video = _defaultVideo, this.user = _defaultUser});

  final FutureOr<VideoSearchPage> Function(
    String input,
    int page,
    VideoSearchFilter filter,
  )
  video;
  final FutureOr<UserSearchPage> Function(String input, int page) user;
  final videoCalls = <(String, int, int?)>[];
  final videoOrders = <VideoSearchOrder>[];
  final userCalls = <(String, int)>[];
  final directCalls = <String>[];

  static VideoSearchPage _defaultVideo(
    String input,
    int page,
    VideoSearchFilter filter,
  ) => _videoPage(page, '视频 $input');
  static UserSearchPage _defaultUser(String input, int page) =>
      _userPage(page, '用户 $input');

  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    videoCalls.add((keyword, page, filter.categoryId));
    videoOrders.add(filter.order);
    return video(keyword, page, filter);
  }

  @override
  Future<UserSearchPage> searchUsers(
    String keyword, {
    int page = 1,
    UserSearchFilter filter = const UserSearchFilter(),
  }) async {
    userCalls.add((keyword, page));
    return user(keyword, page);
  }

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    directCalls.add(input);
    return const VideoPreview(
      bvid: 'BV1000000001',
      cid: 1,
      title: 'BV 直达内容',
      ownerName: '演示UP',
      duration: Duration(seconds: 10),
      parts: [
        VideoPart(
          pageNumber: 1,
          cid: 1,
          title: '演示',
          duration: Duration(seconds: 10),
        ),
      ],
    );
  }

  @override
  Future<List<String>> suggestKeywords(String input) async => const [];
}

const _rasterKey = Key('search-evidence-raster');
final _input = find.byKey(const Key('search-input-field'));
final _sheet = find.byTooltip('筛选');
final _retry = find.byKey(const Key('search-retry-failed-categories'));
final _summary = find.byKey(const Key('search-category-summary'));

Future<void> _mount(
  WidgetTester t,
  _Service service, {
  Size size = const Size(1250, 880),
  String? fontFamily,
}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    RepaintBoundary(
      key: _rasterKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: fontFamily),
        home: SearchPage(service: service),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _submit(WidgetTester t, String input) async {
  await t.enterText(_input, input);
  await t.testTextInput.receiveAction(TextInputAction.search);
  await t.pump();
}

Future<void> _mode(WidgetTester t, String label) async {
  await t.tap(
    find.descendant(
      of: find.byKey(const Key('search-mode-selector')),
      matching: find.text(label),
    ),
  );
  await t.pump();
}

Future<void> _openSheet(WidgetTester t) async {
  await t.tap(_sheet);
  await t.pumpAndSettle();
}

Finder _category(int? id) => find.byKey(Key('search-category-${id ?? 'all'}'));

Future<void> _choose(WidgetTester t, List<int?> ids) async {
  for (final id in ids) {
    final target = _category(id);
    await t.ensureVisible(target);
    await t.pump();
    await t.tap(target);
    await t.pump();
  }
}

Future<void> _apply(WidgetTester t) async {
  await t.tap(find.text('应用筛选'));
  await t.pumpAndSettle();
}

void main() {
  for (final size in [const Size(390, 844), const Size(1250, 880)]) {
    testWidgets(
      'mode switches committed query immediately and preserves draft in $size',
      (t) async {
        final service = _Service();
        await _mount(t, service, size: size);
        await t.enterText(_input, '未提交草稿');
        await _mode(t, '用户');
        await t.pumpAndSettle();
        expect(service.userCalls, isEmpty);
        await _mode(t, '视频');
        await _submit(t, 'Flutter');
        await t.pumpAndSettle();
        expect(find.text('视频 Flutter'), findsOneWidget);
        await t.enterText(_input, '尚未提交');
        await _mode(t, '用户');
        await t.pumpAndSettle();
        expect(service.userCalls, [('Flutter', 1)]);
        expect(find.text('用户 Flutter'), findsOneWidget);
        expect(t.widget<TextField>(_input).controller?.text, '尚未提交');
        expect(find.text('视频 Flutter'), findsNothing);
        await _mode(t, '视频');
        await t.pumpAndSettle();
        expect(service.videoCalls, [
          ('Flutter', 1, null),
          ('Flutter', 1, null),
        ]);
        expect(find.text('视频 Flutter'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'late pages from both old modes cannot replace the new active reply',
    (t) async {
      var count = 0;
      final delayedVideo = Completer<VideoSearchPage>();
      final delayedUser = Completer<UserSearchPage>();
      final service = _Service(
        video: (_, page, filter) =>
            ++count == 1 ? delayedVideo.future : _videoPage(page, '真实最新'),
        user: (_, page) => delayedUser.future,
      );
      await _mount(t, service);
      await _submit(t, '关键词');
      expect(service.videoCalls, [('关键词', 1, null)]);
      await _mode(t, '用户');
      expect(service.userCalls, [('关键词', 1)]);
      await _mode(t, '视频');
      await t.pumpAndSettle();
      expect(find.text('真实最新'), findsOneWidget);

      delayedVideo.complete(_videoPage(1, '迟到旧视频'));
      delayedUser.complete(_userPage(1, '迟到旧用户'));
      await t.pumpAndSettle();
      expect(find.text('真实最新'), findsOneWidget);
      expect(find.text('迟到旧视频'), findsNothing);
      expect(find.text('迟到旧用户'), findsNothing);
    },
  );

  testWidgets('direct BV is not submitted as a username on tab switch', (
    t,
  ) async {
    final service = _Service();
    await _mount(t, service);
    await _submit(t, 'https://www.bilibili.com/video/BV1000000001/');
    await t.pumpAndSettle();
    expect(find.text('BV 直达内容'), findsOneWidget);
    await _mode(t, '用户');
    await t.pumpAndSettle();
    expect(service.userCalls, isEmpty);
    expect(find.text('BV 直达内容'), findsNothing);
    await _mode(t, '视频');
    await t.pumpAndSettle();
    expect(service.directCalls, hasLength(2));
    expect(find.text('BV 直达内容'), findsOneWidget);
  });

  testWidgets(
    'one failing category keeps successful results and has targeted retry',
    (t) async {
      var initialFailure = true;
      final service = _Service(
        video: (input, page, filter) {
          if (filter.categoryId == 188 && initialFailure) {
            initialFailure = false;
            throw const BilibiliLookupException('网络异常');
          }
          return _videoPage(
            page,
            filter.categoryId == 36 ? '知识结果' : '科技结果',
            id: filter.categoryId!,
          );
        },
      );
      await _mount(t, service, size: const Size(390, 844));
      await _openSheet(t);
      await _choose(t, [36, 188]);
      await _apply(t);
      expect(service.videoCalls, isEmpty);
      await _submit(t, 'Flutter');
      await t.pumpAndSettle();
      expect(service.videoCalls, [('Flutter', 1, 36), ('Flutter', 1, 188)]);
      expect(find.text('知识结果'), findsOneWidget);
      expect(find.text('科技结果'), findsNothing);
      expect(_retry, findsOneWidget);
      await t.tap(_retry);
      await t.pumpAndSettle();
      expect(service.videoCalls.last, ('Flutter', 1, 188));
      expect(
        service.videoCalls.where((request) => request.$3 == 36),
        hasLength(1),
      );
      expect(find.text('知识结果'), findsOneWidget);
      expect(find.text('科技结果'), findsOneWidget);
      expect(_retry, findsNothing);
      expect(find.textContaining('按各区名次'), findsOneWidget);
    },
  );

  testWidgets(
    'multi, one and all modes use the matching requests; users have no category',
    (t) async {
      final service = _Service(
        video: (_, page, filter) => _videoPage(
          page,
          '分区 ${filter.categoryId}',
          id: filter.categoryId ?? 1,
        ),
      );
      await _mount(t, service);
      await _openSheet(t);
      await _choose(t, [36, 188]);
      await _apply(t);
      await _submit(t, 'Flutter');
      await t.pumpAndSettle();
      expect(_summary, findsOneWidget);
      expect(service.videoCalls, [('Flutter', 1, 36), ('Flutter', 1, 188)]);

      await _mode(t, '用户');
      await t.pumpAndSettle();
      expect(_summary, findsNothing);
      expect(service.userCalls, [('Flutter', 1)]);
      expect(_sheet, findsNothing);
      await _mode(t, '视频');
      await t.pumpAndSettle();
      expect(_summary, findsOneWidget);

      await _openSheet(t);
      await _choose(t, [188]);
      await _apply(t);
      expect(service.videoCalls.last, ('Flutter', 1, 36));
      expect(_summary, findsNothing);
      await _openSheet(t);
      await _choose(t, [null]);
      await _apply(t);
      expect(service.videoCalls.last, ('Flutter', 1, null));
    },
  );

  testWidgets(
    'local filters reuse loaded category rows offline without using unsubmitted text',
    (t) async {
      var offline = false;
      final service = _Service(
        video: (input, page, filter) {
          if (offline) throw StateError('offline');
          return _videoPage(
            page,
            filter.categoryId == 36 ? '要保留' : '待屏蔽',
            id: filter.categoryId!,
          );
        },
      );
      await _mount(t, service, size: const Size(390, 844));
      await _openSheet(t);
      await _choose(t, [36, 188]);
      await _apply(t);
      await _submit(t, 'Flutter');
      await t.pumpAndSettle();
      expect(find.text('待屏蔽'), findsOneWidget);
      offline = true;
      // Local rule edits must not search this unfinished replacement.
      await t.enterText(_input, '未提交');
      await _openSheet(t);
      final keywords = find.byKey(const Key('search-title-keywords'));
      await t.ensureVisible(keywords);
      await t.enterText(keywords, '待屏蔽');
      await _apply(t);
      expect(find.text('待屏蔽'), findsNothing);
      expect(find.text('要保留'), findsOneWidget);
      await _openSheet(t);
      await t.ensureVisible(keywords);
      await t.enterText(keywords, '');
      await _apply(t);
      expect(find.text('待屏蔽'), findsOneWidget);
      expect(service.videoCalls, [('Flutter', 1, 36), ('Flutter', 1, 188)]);
    },
  );

  testWidgets(
    'load more advances each eligible category once and does not auto-scan',
    (t) async {
      final service = _Service(
        video: (_, page, filter) {
          final category = filter.categoryId!;
          return _videoPage(
            page,
            '分区 $category 第 $page 页',
            id: page * 1000 + category,
            totalPages: category == 36 ? 1 : 3,
          );
        },
      );
      await _mount(t, service);
      await _openSheet(t);
      await _choose(t, [36, 188]);
      await _apply(t);
      await _submit(t, 'Flutter');
      await t.pumpAndSettle();
      expect(service.videoCalls, [('Flutter', 1, 36), ('Flutter', 1, 188)]);
      final more = find.byKey(const Key('search-load-more'));
      await t.tap(more);
      await t.pumpAndSettle();
      expect(service.videoCalls.last, ('Flutter', 2, 188));
      expect(service.videoCalls, hasLength(3));
      expect(find.text('分区 188 第 2 页'), findsOneWidget);
      expect(find.text('分区 36 第 1 页'), findsOneWidget);
      expect(find.text('分区 188 第 3 页'), findsNothing);
    },
  );

  testWidgets(
    'all failures show an explicit retry without pretending there are no matches',
    (t) async {
      var offline = true;
      final service = _Service(
        video: (_, page, filter) {
          if (offline) throw StateError('offline');
          return _videoPage(
            page,
            '分区 ${filter.categoryId} 恢复',
            id: filter.categoryId!,
          );
        },
      );
      await _mount(t, service);
      await _openSheet(t);
      await _choose(t, [36, 188]);
      await _apply(t);
      await _submit(t, 'Flutter');
      await t.pumpAndSettle();
      expect(find.text('知识、科技未加载完 · 重试'), findsOneWidget);
      expect(find.text('所选分区暂未加载，重试后查看结果。'), findsOneWidget);
      expect(find.byKey(const Key('search-load-more')), findsNothing);
      offline = false;
      await t.tap(_retry);
      await t.pumpAndSettle();
      expect(find.text('分区 36 恢复'), findsOneWidget);
      expect(find.text('分区 188 恢复'), findsOneWidget);
      expect(_retry, findsNothing);
    },
  );

  final evidenceDirectory = Platform.environment['FOCUBILI_SEARCH_EVIDENCE'];
  testWidgets('multi-category search raster evidence', (t) async {
    final font = Platform.environment['FOCUBILI_DESKTOP_INPUT_FONT'];
    final iconFont = Platform.environment['FOCUBILI_DESKTOP_INPUT_ICON_FONT'];
    await t.runAsync(() async {
      for (final (path, family) in [
        (font, 'SearchEvidence'),
        (iconFont, 'MaterialIcons'),
      ]) {
        if (path == null) continue;
        final data = await File(path).readAsBytes();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(data)))).load();
      }
    });
    Future<void> capture(String name) async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(_rasterKey),
      );
      await t.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        image.dispose();
        await File(
          '$evidenceDirectory/$name.png',
        ).writeAsBytes(bytes.buffer.asUint8List());
      });
    }

    var failed = true;
    final service = _Service(
      video: (_, page, filter) {
        if (filter.categoryId == 188 && failed) {
          failed = false;
          throw const BilibiliLookupException('演示：分区暂不可用');
        }
        final id = filter.categoryId ?? 36;
        return _videoPage(
          page,
          id == 36 ? '知识分区 · Flutter 布局入门' : '科技分区 · Flutter 渲染原理',
          id: id,
        );
      },
    );
    await _mount(
      t,
      service,
      fontFamily: font == null ? null : 'SearchEvidence',
    );
    await _openSheet(t);
    await _choose(t, [36, 188]);
    await t.pumpAndSettle();
    await capture('choices');
    await _apply(t);
    await _submit(t, 'Flutter');
    await t.pumpAndSettle();
    await capture('partial');
    if (_retry.evaluate().isNotEmpty) {
      await t.tap(_retry);
      await t.pumpAndSettle();
      await capture('recovered');
    }
  }, skip: evidenceDirectory == null);
}
