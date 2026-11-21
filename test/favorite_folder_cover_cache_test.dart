import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/favorite_folder_card.dart';
import 'package:focubili/features/profile/favorite_folders_page.dart';
import 'package:focubili/features/profile/favorite_videos_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';

class _Service extends BilibiliAccountDataService {
  int listCalls = 0;
  int coverCalls = 0;
  var folders = [_folder('原账号收藏')];
  String url = 'https://i0.hdslb.com/cover-before.jpg';
  Future<AccountDataPage<FavoriteVideo>>? heldCover;

  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() async {
    listCalls++;
    return AccountDataPage<FavoriteFolder>.success(
      items: folders,
      page: 1,
      hasMore: false,
    );
  }

  @override
  Future<AccountDataPage<FavoriteVideo>> loadFavoriteVideos(
    int mediaId, {
    int page = 1,
  }) async {
    coverCalls++;
    return heldCover ?? _coverPage(url);
  }
}

FavoriteFolder _folder(
  String name, {
  int count = 1,
  int id = 1001,
  bool? isPrivate,
}) => FavoriteFolder(
  mediaId: id,
  title: name,
  coverUrl: '',
  mediaCount: count,
  isAvailable: true,
  isPrivate: isPrivate,
);

AccountDataPage<FavoriteVideo> _coverPage(String url) =>
    AccountDataPage<FavoriteVideo>.success(
      page: 1,
      hasMore: false,
      items: [
        FavoriteVideo(
          bvid: 'BV1GJ411x7h7',
          title: '收藏视频',
          coverUrl: url,
          duration: const Duration(seconds: 1),
          partCount: 1,
          favoritedAt: null,
          playCount: 0,
          danmakuCount: 0,
          ownerName: 'UP',
          isAvailable: true,
        ),
      ],
    );

void main() {
  for (final size in [const Size(370, 760), const Size(1180, 800)]) {
    testWidgets('B站私密锁锚定封面右下角，公开与未知没有锁：$size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service()
        ..folders = [
          _folder('私密空收藏', count: 0, isPrivate: true),
          _folder('公开收藏', count: 0, id: 1002, isPrivate: false),
          _folder('旧接口未返回可见性', count: 0, id: 1003),
        ];
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(home: FavoriteFoldersPage(accountDataService: service)),
        );
        await tester.pumpAndSettle();
        final lock = find.byIcon(Icons.lock_outline_rounded);
        final card = find.byKey(const Key('favorite-folder-1001'));
        final cover = find.descendant(
          of: card,
          matching: find.byType(ClipRRect),
        );
        expect(find.byIcon(Icons.folder_outlined), findsNWidgets(3));
        expect(lock, findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('私密收藏夹')), findsOneWidget);
        final bounds = tester.getRect(cover);
        final position = tester.getCenter(lock);
        expect(bounds.right - position.dx, lessThan(16));
        expect(bounds.bottom - position.dy, lessThan(16));

        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await pointer.addPointer(location: position);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('私密收藏夹'), findsOneWidget);
        await pointer.removePointer();
        await tester.pumpAndSettle();
        expect(service.coverCalls, 0);
        await tester.tapAt(position);
        await tester.pumpAndSettle();
        expect(find.byType(FavoriteVideosPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'reopening reuses covers; explicit refresh updates or clears them',
    (tester) async {
      final service = _Service();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        FavoriteFoldersPage(accountDataService: service),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      String cover() => tester
          .widget<FavoriteFolderCard>(find.byType(FavoriteFolderCard))
          .coverUrl;
      await open();
      expect(cover(), service.url);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
      expect(find.byTooltip('原账号收藏'), findsOneWidget);
      expect(service.listCalls, 1);
      expect(service.coverCalls, 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await open();
      expect(cover(), service.url);
      expect(service.listCalls, 1);
      expect(service.coverCalls, 1);

      final previous = service.url;
      service.url = 'https://i0.hdslb.com/cover-after.jpg';
      final held = Completer<AccountDataPage<FavoriteVideo>>();
      service.heldCover = held.future;
      await tester.tap(find.byTooltip('刷新收藏夹'));
      await tester.pumpAndSettle();
      expect(cover(), previous);
      held.complete(_coverPage(service.url));
      await tester.pumpAndSettle();
      expect(cover(), service.url);

      service.folders = [_folder('原账号收藏', count: 0)];
      await tester.tap(find.byTooltip('刷新收藏夹'));
      await tester.pumpAndSettle();
      expect(cover(), isEmpty);
      expect(service.coverCalls, 2);
      service.folders = [];
      await tester.tap(find.byTooltip('刷新收藏夹'));
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteFolderCard), findsNothing);
    },
  );

  testWidgets('account change clears snapshot and fences a late old cover', (
    tester,
  ) async {
    final service = _Service();
    final oldCover = Completer<AccountDataPage<FavoriteVideo>>();
    service.heldCover = oldCover.future;
    await tester.pumpWidget(
      MaterialApp(home: FavoriteFoldersPage(accountDataService: service)),
    );
    await tester.pumpAndSettle();
    expect(find.text('原账号收藏'), findsOneWidget);
    service.folders = [_folder('新账号收藏')];
    service.heldCover = null;
    service.url = 'https://i0.hdslb.com/new-account.jpg';
    CacheLifecycle.accountChanged();
    await tester.pumpAndSettle();
    expect(find.text('原账号收藏'), findsNothing);
    expect(find.text('新账号收藏'), findsOneWidget);
    oldCover.complete(_coverPage('https://i0.hdslb.com/old-account.jpg'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FavoriteFolderCard>(find.byType(FavoriteFolderCard))
          .coverUrl,
      service.url,
    );
  });
}
