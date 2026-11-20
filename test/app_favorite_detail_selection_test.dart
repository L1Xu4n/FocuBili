import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/models/playback_queue.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _VideoLookup extends BilibiliVideoInfoService {
  _VideoLookup([this.videos = const {}]);
  final Map<String, VideoPreview> videos;
  final requests = <String>[];

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    requests.add(input);
    return videos[input] ?? VideoPreview.placeholder();
  }
}

AppFavoriteItem _item(
  AppFavoriteFolder folder,
  String id,
  String title,
  int rank,
) => AppFavoriteItem(
  folderId: folder.id,
  bvid: id,
  title: title,
  coverUrl: '',
  ownerName: 'UP 主',
  durationText: '',
  addedAt: DateTime(2026, 7, 15, 12, rank),
  partCount: 2,
);

Finder _checkbox(String id) => find.byKey(ValueKey('select-local-video-$id'));

Future<void> _sweep(WidgetTester tester, String start, String end) async {
  final gesture = await tester.startGesture(tester.getCenter(_checkbox(start)));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(_checkbox(end)));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('软件收藏夹多选仅移除筛选中确认的视频，且不影响其他收藏夹', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final favorites = AppFavoritesService();
    final folder = (await favorites.createFolder('数学收藏'))!;
    final other = (await favorites.createFolder('备课收藏'))!;
    await favorites.addItems(folder.id, [
      _item(folder, 'BVran1', '数学一', 6),
      _item(folder, 'BVhidden', '英语一', 5),
      _item(folder, 'BVran2', '数学二', 4),
      _item(folder, 'BVran3', '数学三', 3),
      _item(folder, 'BVran4', '数学四', 2),
    ]);
    await favorites.addItem(_item(other, 'BVran2', '数学二', 1));
    final lookup = _VideoLookup();
    PlayerLaunchRequest? launch;
    await tester.pumpWidget(
      MaterialApp(
        home: AppFavoriteDetailPage(
          folder: folder,
          favoritesService: favorites,
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
    final search = find.byKey(const Key('app-favorite-videos-search'));

    // Filter without a selection, and preserve the same playback queue.
    await tester.enterText(search, '数学');
    await tester.pumpAndSettle();
    await tester.tap(find.text('数学一'));
    await tester.pumpAndSettle();
    expect(lookup.requests, ['BVran1']);
    expect(launch?.queue.items.map((item) => item.bvid), [
      'BVran1',
      'BVran2',
      'BVran3',
      'BVran4',
    ]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.longPress(find.text('数学一'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(tester.widget<Checkbox>(_checkbox('BVran1')).value, isTrue);
    await _sweep(tester, 'BVran2', 'BVran3');
    expect(find.text('已选 3 项'), findsOneWidget);
    await _sweep(tester, 'BVran3', 'BVran3');
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(await favorites.loadItems(folder.id), hasLength(5));
    expect(lookup.requests, ['BVran1']);

    await tester.tap(find.byTooltip('移除所选'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不影响其他收藏夹'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(await favorites.loadItems(folder.id), hasLength(5));

    await tester.tap(find.byTooltip('移除所选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('数学一'), findsNothing);
    expect(find.text('数学二'), findsNothing);
    expect(find.text('数学三'), findsOneWidget);
    expect(find.text('数学四'), findsOneWidget);
    expect(find.text('英语一'), findsNothing);
    expect((await favorites.loadItems(folder.id)).map((item) => item.bvid), [
      'BVhidden',
      'BVran3',
      'BVran4',
    ]);
    expect((await favorites.loadItems(other.id)).single.bvid, 'BVran2');
  });

  testWidgets('收藏多选可加入单支或多支的真实分 P，取消不写入且不移除收藏', (tester) async {
    const size = Size(320, 760);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final favorites = AppFavoritesService();
    final learning = LearningListService();
    final folder = (await favorites.createFolder('课内资料'))!;
    const regularId = 'BV1GJ411x7h7';
    const courseId = 'cheese:ss501';
    const skippedId = 'BV1xx411c7mD';
    await favorites.addItems(folder.id, [
      _item(folder, regularId, '收藏普通视频', 3),
      _item(folder, courseId, '收藏课堂课程', 2),
      _item(folder, skippedId, '跳过的视频', 1),
    ]);
    const regularPart2 = VideoPart(
      pageNumber: 2,
      cid: 202,
      title: '普通分 P',
      duration: Duration(minutes: 2),
    );
    final lookup = _VideoLookup({
      regularId: const VideoPreview(
        bvid: regularId,
        cid: 101,
        title: '普通视频',
        ownerName: '作者',
        parts: [
          VideoPart(
            pageNumber: 1,
            cid: 101,
            title: '普通开头',
            duration: Duration(minutes: 1),
          ),
          regularPart2,
        ],
      ),
      courseId: const VideoPreview(
        bvid: courseId,
        courseSeasonId: 501,
        cid: 202,
        title: '课堂课程',
        ownerName: '老师',
        parts: [
          VideoPart(
            pageNumber: 1,
            cid: 202,
            title: '课堂章节',
            duration: Duration(minutes: 3),
            courseEpisodeId: 900,
          ),
        ],
      ),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppFavoriteDetailPage(
          folder: folder,
          favoritesService: favorites,
          bilibiliService: lookup,
          learningService: learning,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final add = find.byTooltip('添加到学习清单');
    final remove = find.byTooltip('移除所选');
    final confirm = find.text('确认加入');
    final select = find.byTooltip('多选');
    expect(find.text('多选'), findsNothing);
    expect(select, findsOneWidget);
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.playlist_add_rounded),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.delete_outline_rounded),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('收藏普通视频'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    final addRect = tester.getRect(add);
    final removeRect = tester.getRect(remove);
    final appBar = find.byType(AppBar);
    expect(tester.widget<AppBar>(appBar).bottom, isNull);
    expect(tester.getRect(appBar).contains(addRect.center), isTrue);
    expect(tester.getRect(appBar).contains(removeRect.center), isTrue);
    expect(addRect.center.dy, removeRect.center.dy);
    expect(addRect.right, lessThanOrEqualTo(removeRect.left));
    expect(removeRect.right, lessThanOrEqualTo(size.width));
    expect(find.text('添加到学习清单'), findsNothing);
    expect(find.text('移除所选'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(lookup.requests, [regularId]);
    expect(find.text('加入学习清单'), findsOneWidget);
    expect(find.text('P1 课堂章节'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await learning.loadEntries(), isEmpty);
    expect(tester.widget<Checkbox>(_checkbox(regularId)).value, isTrue);

    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('P1 普通开头'));
    await tester.tap(find.text('P2 普通分 P'));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect((await learning.loadEntries()).single.stableId, '$regularId:202');
    expect(find.byType(Checkbox), findsNothing);

    const savedProgress = Duration(seconds: 31);
    await learning.updateProgress(
      regularId,
      part: regularPart2,
      position: savedProgress,
    );
    final state = await learning.createFolder('课程学科');
    final subject = state.folders.single.id;
    await tester.longPress(find.text('收藏课堂课程'));
    await tester.pumpAndSettle();
    await tester.tap(_checkbox(regularId));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(lookup.requests, [regularId, regularId, regularId, courseId]);
    await tester.tap(find.text('P1 普通开头'));
    final subjectPicker = find.byKey(const Key('add-learning-folder'));
    await tester.tap(subjectPicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程学科').last);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    final entries = {
      for (final entry in await learning.loadEntries()) entry.stableId: entry,
    };
    expect(entries.keys, unorderedEquals(['$regularId:202', '$courseId:202']));
    expect(entries['$regularId:202']!.position, savedProgress);
    expect(entries['$regularId:202']!.folderId, isNull);
    expect(entries['$courseId:202']!.folderId, subject);
    expect((await favorites.loadItems(folder.id)).map((item) => item.bvid), [
      regularId,
      courseId,
      skippedId,
    ]);
    expect(tester.takeException(), isNull);
  });
}
