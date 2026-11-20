import 'package:focubili/core/router/app_router.dart';
import 'package:focubili/features/profile/app_favorite_detail_page.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/models/playback_queue.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _VideoLookup extends BilibiliVideoInfoService {
  final requests = <String>[];

  @override
  Future<VideoPreview> lookupVideo(String input) async {
    requests.add(input);
    return VideoPreview.placeholder();
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

    await tester.tap(find.text('移除所选'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不影响其他收藏夹'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    expect(await favorites.loadItems(folder.id), hasLength(5));

    await tester.tap(find.text('移除所选'));
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
}
