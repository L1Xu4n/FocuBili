import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/models/app_favorites_backup.dart';
import 'package:focubili/models/playback_queue.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/app_favorites_file_service.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BackupFiles extends AppFavoritesFileService {
  AppFavoritesBackup? saved;

  @override
  Future<bool> saveBackup(AppFavoritesBackup backup) async {
    saved = backup;
    return true;
  }
}

class _VideoLookup extends BilibiliVideoInfoService {
  final requests = <String>[];

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    requests.add(input);
    return VideoPreview.placeholder();
  }
}

const _first = 'BV1GJ411x7h7';
const _second = 'BV1xx411c7mD';
const _third = 'BV1ab411c7Zk';

AppFavoriteItem _item(String folderId, String bvid, String title, int hours) =>
    AppFavoriteItem(
      folderId: folderId,
      bvid: bvid,
      title: title,
      coverUrl: '',
      ownerName: '测试作者',
      durationText: '01:00',
      addedAt: DateTime(2026, 11, 1, hours),
      partCount: 2,
    );

Finder _folderCard(String id) => find.byKey(Key('app-favorite-folder-$id'));

/// Tooltips render the same label as rich text, even inside their own card's
/// element subtree. Target the plain, visible title acted on by the user.
Finder _folderTitle(AppFavoriteFolder folder) => find.descendant(
  of: _folderCard(folder.id),
  matching: find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == folder.name,
  ),
);

Finder _folderHandle(String id) =>
    find.byKey(ValueKey('reorder-app-favorite-folder-$id'));
Finder _itemHandle(String id) =>
    find.byKey(ValueKey('reorder-app-favorite-item-$id'));
Finder _checkbox(String id) => find.byKey(ValueKey('select-local-video-$id'));

Future<void> _holdAndMove(
  WidgetTester tester,
  Finder from,
  Finder to, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
  bool cancel = false,
}) async {
  final gesture = await tester.startGesture(tester.getCenter(from), kind: kind);
  var moved = false;
  try {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump();
    moved = true;
  } finally {
    if (cancel || !moved) {
      await gesture.cancel();
    } else {
      await gesture.up();
    }
  }
  await tester.pumpAndSettle();
}

void main() {
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Resolve the plugin's singleton Future in setUp, outside the widget's
    // fake clock. Each case owns its mock store and passes it explicitly.
    preferences = await SharedPreferences.getInstance();
  });

  void favoriteWidgetTest(
    String description,
    Size size,
    Future<void> Function(WidgetTester, AppFavoritesService Function())
    exercise,
  ) {
    testWidgets(description, (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(size);
      final store = preferences;
      AppFavoritesService createService() =>
          AppFavoritesService(preferencesLoader: () async => store);
      try {
        await exercise(tester, createService);
      } finally {
        // Dismiss tooltips, routes and overlay state while their own fake
        // clock is still alive, before the next case changes the surface.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  for (final wide in [false, true]) {
    favoriteWidgetTest(
      '本机收藏夹在${wide ? '桌面双列' : '手机单列'}排序，长按行才打开管理菜单',
      wide ? const Size(1120, 760) : const Size(360, 650),
      (tester, createService) async {
        final favorites = createService();
        final first = (await favorites.createFolder('首个目录'))!;
        final second = (await favorites.createFolder('次个目录'))!;
        final third = (await favorites.createFolder('第三目录'))!;
        await favorites.addItem(_item(first.id, _first, '视频一', 1));
        final files = _BackupFiles();
        final lookup = _VideoLookup();
        Future<void> open() async {
          await tester.pumpWidget(
            MaterialApp(
              home: AppFavoriteFoldersPage(
                favoritesService: createService(),
                bilibiliService: lookup,
                fileService: files,
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<List<String>> currentOrder() async => [
          for (final folder in await favorites.loadFolders()) folder.id,
        ];

        await open();
        expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
        expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
        final firstRow = _folderTitle(first);
        final secondRow = _folderTitle(second);
        if (wide) {
          expect(tester.getCenter(firstRow).dy, tester.getCenter(secondRow).dy);
          expect(
            tester.getCenter(firstRow).dx,
            lessThan(tester.getCenter(secondRow).dx),
          );
        }
        await tester.tap(_folderHandle(first.id));
        await tester.pumpAndSettle();
        expect(find.text('导出此收藏夹'), findsNothing);
        expect(await currentOrder(), [first.id, second.id, third.id]);

        final kind = wide ? PointerDeviceKind.mouse : PointerDeviceKind.touch;
        await _holdAndMove(
          tester,
          _folderHandle(first.id),
          secondRow,
          kind: kind,
          cancel: true,
        );
        expect(await currentOrder(), [first.id, second.id, third.id]);

        await _holdAndMove(
          tester,
          _folderHandle(first.id),
          secondRow,
          kind: kind,
        );
        expect(await currentOrder(), [second.id, first.id, third.id]);
        expect(find.text('导出此收藏夹'), findsNothing);
        expect(find.byType(AppFavoriteDetailPage), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await open();
        if (wide) {
          expect(
            tester.getCenter(secondRow).dx,
            lessThan(tester.getCenter(firstRow).dx),
          );
        } else {
          expect(
            tester.getCenter(secondRow).dy,
            lessThan(tester.getCenter(firstRow).dy),
          );
        }

        await tester.tap(firstRow);
        await tester.pumpAndSettle();
        expect(find.byType(AppFavoriteDetailPage), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        await tester.longPress(firstRow);
        await tester.pumpAndSettle();
        expect(find.text('导出此收藏夹'), findsOneWidget);
        expect(find.text('重命名'), findsOneWidget);
        expect(find.text('删除收藏夹'), findsOneWidget);
        await tester.tap(find.text('导出此收藏夹'));
        await tester.pumpAndSettle();
        expect(files.saved?.folders.single.id, first.id);
        expect(files.saved?.items[first.id]?.single.bvid, _first);

        await tester.longPress(firstRow);
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除收藏夹'));
        await tester.pumpAndSettle();
        expect(find.text('删除软件收藏夹'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(await currentOrder(), [second.id, first.id, third.id]);
        expect(lookup.requests, isEmpty);
      },
    );
  }

  favoriteWidgetTest('普通滚动不会重排本机收藏夹', const Size(360, 640), (
    tester,
    createService,
  ) async {
    final favorites = createService();
    final ids = [
      for (var n = 0; n < 12; n++) (await favorites.createFolder('目录 $n'))!.id,
    ];
    await tester.pumpWidget(
      MaterialApp(home: AppFavoriteFoldersPage(favoritesService: favorites)),
    );
    await tester.pumpAndSettle();

    final list = find.byKey(const Key('app-favorite-folders-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    await tester.drag(find.text('目录 2'), const Offset(0, -110));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    expect([
      for (final folder in await favorites.loadFolders()) folder.id,
    ], ids);
    expect(find.text('导出此收藏夹'), findsNothing);
  });

  favoriteWidgetTest('保持手柄在底部边缘时滚动，放手使用当前所在的目录', const Size(360, 650), (
    tester,
    createService,
  ) async {
    final favorites = createService();
    final ids = [
      for (var n = 0; n < 16; n++) (await favorites.createFolder('目录 $n'))!.id,
    ];
    await tester.pumpWidget(
      MaterialApp(home: AppFavoriteFoldersPage(favoritesService: favorites)),
    );
    await tester.pumpAndSettle();

    final list = find.byKey(const Key('app-favorite-folders-list'));
    final viewport = tester.getRect(list);
    // Stay inside the edge-scroll zone but above the list's bottom padding.
    final pointer = Offset(viewport.center.dx, viewport.bottom - 34);
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final gesture = await tester.startGesture(
      tester.getCenter(_folderHandle(ids.first)),
    );
    var targetIndex = -1;
    var canDrop = false;
    try {
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      await gesture.moveTo(pointer);
      for (var frame = 0; frame < 40 && targetIndex == -1; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (position.pixels < 150) continue;
        for (var i = 1; i < ids.length; i++) {
          final row = _folderCard(ids[i]);
          if (row.evaluate().isNotEmpty &&
              tester.getRect(row).contains(pointer)) {
            targetIndex = i;
            break;
          }
        }
      }
      expect(
        position.pixels,
        greaterThanOrEqualTo(150),
        reason:
            'Holding still at the edge must move more than one scroll step.',
      );
      expect(targetIndex, greaterThan(0));
      canDrop = true;
    } finally {
      if (canDrop) {
        await gesture.up();
      } else {
        await gesture.cancel();
      }
    }
    await tester.pumpAndSettle();

    final expected = ids.toList();
    expected.insert(targetIndex, expected.removeAt(0));
    expect([
      for (final folder in await favorites.loadFolders()) folder.id,
    ], expected);
    expect(tester.takeException(), isNull);
  });

  favoriteWidgetTest('视频拖动不播放或多选，重新打开后按新顺序播放并保留快速扫选', const Size(360, 760), (
    tester,
    createService,
  ) async {
    final favorites = createService();
    final folder = (await favorites.createFolder('主目录'))!;
    final other = (await favorites.createFolder('另一个目录'))!;
    await favorites.addItems(folder.id, [
      _item(folder.id, _first, '视频一', 1),
      _item(folder.id, _second, '视频二', 2),
      _item(folder.id, _third, '视频三', 3),
    ]);
    await favorites.addItem(_item(other.id, _third, '视频三', 1));
    final lookup = _VideoLookup();
    PlayerLaunchRequest? launch;
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppFavoriteDetailPage(
            folder: folder,
            favoritesService: createService(),
            bilibiliService: lookup,
          ),
          onGenerateRoute: (settings) {
            if (settings.name != AppRoutes.player) return null;
            launch = settings.arguments as PlayerLaunchRequest;
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('播放器')),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<List<String>> currentOrder() async => [
      for (final item in await favorites.loadItems(folder.id)) item.bvid,
    ];

    await open();
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    expect(find.byTooltip('多选'), findsOneWidget);
    expect(await currentOrder(), [_third, _second, _first]);
    await tester.tap(_itemHandle(_third));
    await tester.pumpAndSettle();
    await _holdAndMove(tester, _itemHandle(_third), find.text('视频一'));
    expect(lookup.requests, isEmpty);
    expect(find.byType(Checkbox), findsNothing);
    expect(await currentOrder(), [_second, _first, _third]);

    await tester.pumpWidget(const SizedBox.shrink());
    await open();
    final firstRow = find.text('视频一');
    final secondRow = find.text('视频二');
    expect(
      tester.getCenter(secondRow).dy,
      lessThan(tester.getCenter(firstRow).dy),
    );
    await tester.tap(firstRow);
    await tester.pumpAndSettle();
    expect(lookup.requests, [_first]);
    expect(
      [for (final item in launch!.queue.items) item.bvid],
      [_second, _first, _third],
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    final search = find.byKey(const Key('app-favorite-videos-search'));
    await tester.enterText(search, '视频');
    await tester.pumpAndSettle();
    expect(_itemHandle(_third), findsNothing);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(_itemHandle(_third), findsOneWidget);

    await tester.longPress(secondRow);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(_itemHandle(_third), findsNothing);
    await _holdAndMove(tester, _checkbox(_first), _checkbox(_third));
    expect(find.text('已选 3 项'), findsOneWidget);
    await tester.tap(_checkbox(_first));
    await tester.tap(find.byTooltip('移除所选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await currentOrder(), [_second, _first, _third]);
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.byTooltip('移除所选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(await currentOrder(), [_first]);
    expect((await favorites.loadItems(other.id)).single.bvid, _third);
    expect(lookup.requests, [_first]);
    expect(tester.takeException(), isNull);
  });
}
