import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/profile/favorite_folder_card.dart';
import 'package:focubili/features/profile/favorite_folders_page.dart';
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

FavoriteFolder _folder(String name, {int count = 1}) => FavoriteFolder(
  mediaId: 1001,
  title: name,
  coverUrl: '',
  mediaCount: count,
  isAvailable: true,
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
