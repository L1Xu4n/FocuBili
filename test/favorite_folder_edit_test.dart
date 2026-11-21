import 'dart:async';

import 'package:focubili/features/profile/favorite_folders_page.dart';
import 'package:focubili/features/profile/favorite_videos_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';
import 'package:focubili/services/bilibili_interaction_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _folder = FavoriteFolder(
  mediaId: 7,
  ownerMid: 42,
  title: '原收藏夹',
  coverUrl: '',
  mediaCount: 0,
  isAvailable: true,
  isPrivate: false,
);
const _edit = Key('edit-bilibili-favorite-folder');
const _name = Key('favorite-folder-edit-title');
const _save = Key('favorite-folder-edit-save');

class _Folders extends BilibiliAccountDataService {
  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() async =>
      AccountDataPage.success(items: [_folder], page: 1, hasMore: false);
  @override
  Future<AccountDataPage<FavoriteVideo>> loadFavoriteVideos(
    int mediaId, {
    int page = 1,
  }) async => AccountDataPage.success(items: [], page: 1, hasMore: false);
}

class _Editor extends BilibiliInteractionService {
  int reads = 0, writes = 0;
  bool canRename = true;
  String? loadError;
  Completer<FavoriteFolderEditable>? pending;
  @override
  Future<FavoriteFolderEditable> loadFavoriteFolderForEdit({
    required int mediaId,
    required int expectedMid,
    required bool Function() isCurrent,
  }) async {
    expect((mediaId, expectedMid), (7, 42));
    expect(isCurrent(), isTrue);
    reads++;
    if (loadError case final error?) throw BilibiliInteractionException(error);
    return (title: _folder.title, isPrivate: false, canRename: canRename);
  }

  @override
  Future<FavoriteFolderEditable> editFavoriteFolder({
    required int mediaId,
    required int expectedMid,
    required FavoriteFolderEditable original,
    required String title,
    required bool isPrivate,
    required bool Function() isCurrent,
  }) async {
    expect(isCurrent(), isTrue);
    writes++;
    return await pending?.future ??
        (title: title, isPrivate: isPrivate, canRename: canRename);
  }
}

void main() {
  testWidgets(
    'explicit save updates details title and list cover lock without a reload',
    (tester) async {
      final editor = _Editor();
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteFoldersPage(
            accountDataService: _Folders(),
            interactionService: editor,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('favorite-folder-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_edit));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      await tester.enterText(find.byKey(_name), '新收藏夹');
      await tester.tap(find.text('私密'));
      expect(editor.writes, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(editor.writes, 0);

      await tester.tap(find.byKey(_edit));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(_name), '新收藏夹');
      await tester.tap(find.text('私密'));
      await tester.pumpAndSettle();
      editor.pending = Completer();
      await tester.tap(find.byKey(_save));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_name)).enabled, isFalse);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      editor.pending!.completeError(const BilibiliInteractionException('保存失败'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败'), findsOneWidget);
      editor.pending = null;
      await tester.tap(find.byKey(_save));
      await tester.pumpAndSettle();
      expect(find.text('新收藏夹'), findsOneWidget);
      expect(editor.writes, 2);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('新收藏夹'), findsOneWidget);
      expect(find.byTooltip('私密收藏夹'), findsOneWidget);
    },
  );

  testWidgets(
    'default title is locked, unknown visibility offers no save, account switch closes eligibility',
    (tester) async {
      final editor = _Editor()..canRename = false;
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            folder: _folder,
            editableOwnerMid: 42,
            interactionService: editor,
            accountDataService: _Folders(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_edit));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_name)).readOnly, isTrue);
      expect(find.text('B 站默认收藏夹不可改名'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      editor.loadError = '未能确认收藏夹可见性，暂不能编辑。';
      await tester.tap(find.byKey(_edit));
      await tester.pumpAndSettle();
      expect(find.byKey(_save), findsNothing);
      expect(find.text('未能确认收藏夹可见性，暂不能编辑。'), findsOneWidget);
      CacheLifecycle.accountChanged();
      await tester.pumpAndSettle();
      expect(find.text('账号已变化，请关闭后重新打开。'), findsOneWidget);
      expect(editor.writes, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byKey(_edit), findsNothing);
    },
  );

  testWidgets('read-only preview without ownership origin has no editor', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FavoriteVideosPage(
          folder: _folder,
          accountDataService: _Folders(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_edit), findsNothing);
  });
}
