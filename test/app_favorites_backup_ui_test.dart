import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/models/app_favorites_backup.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/services/app_favorites_file_service.dart';
import 'package:focubili/services/app_favorites_service.dart';

import 'app_favorites_backup_test.dart' show sample;

/// 模拟系统选择文件和取消另存为，不打开测试宿主的真实文件窗口。
class MemoryFiles extends AppFavoritesFileService {
  AppFavoritesBackup? selected;
  AppFavoritesBackup? saved;
  bool saveSucceeded = true;
  Completer<AppFavoritesBackup?>? pending;

  @override
  Future<AppFavoritesBackup?> pickBackup() async =>
      pending == null ? selected : await pending!.future;

  @override
  Future<bool> saveBackup(AppFavoritesBackup backup) async {
    saved = backup;
    return saveSucceeded;
  }
}

/// 页面测试只模拟快照的读取和保存；持久化与并发队列由备份服务测试覆盖。
class MemoryFavorites extends AppFavoritesService {
  MemoryFavorites([AppFavoritesBackup? initial]) : backup = initial;
  AppFavoritesBackup? backup;

  @override
  Future<List<AppFavoriteFolder>> loadFolders() async => backup?.folders ?? [];

  @override
  Future<List<AppFavoriteItem>> loadItems(String folderId) async =>
      backup?.items[folderId] ?? [];

  @override
  Future<int> totalItemCount() async => backup?.itemCount ?? 0;

  @override
  Future<AppFavoritesBackupImportResult> importBackup(
    AppFavoritesBackup incoming,
  ) async {
    backup = incoming;
    return AppFavoritesBackupImportResult(
      createdFolders: incoming.folders.length,
      importedItems: incoming.itemCount,
      duplicates: 0,
    );
  }

  @override
  Future<AppFavoritesBackup> exportBackup({String? folderId}) async =>
      folderId == null
      ? backup!
      : AppFavoritesBackup(
          folders: backup!.folders
              .where((folder) => folder.id == folderId)
              .toList(),
          items: backup!.items,
          exportedAt: backup!.exportedAt,
        );
}

/// 打开本地文件菜单后选择明确的导入或导出动作。
Future<void> choose(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(const Key('app-favorites-backup-menu')));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.byKey(Key(key)));
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [const Size(320, 640), const Size(1200, 800)]) {
    testWidgets('本地导入在 $size 预览、取消和完成后刷新', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final files = MemoryFiles()..selected = sample();
      final favorites = MemoryFavorites();
      await tester.pumpWidget(
        MaterialApp(
          home: AppFavoriteFoldersPage(
            favoritesService: favorites,
            fileService: files,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('app-favorites-backup-menu')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('import-bilibili-favorites')).hitTestable(),
        findsOneWidget,
      );
      await choose(tester, 'import-app-favorites-file');
      expect(find.textContaining('3 个收藏夹、3 条收藏'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await favorites.loadFolders(), isEmpty);
      await choose(tester, 'import-app-favorites-file');
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const Key('confirm-app-favorites-file-import')),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('学习'), findsOneWidget);
      expect(find.text('空收藏夹'), findsOneWidget);
      expect(find.textContaining('导入完成：新建 3'), findsOneWidget);
      expect(await favorites.totalItemCount(), 3);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('大字体窄屏下入口和导入确认均可点击', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = MemoryFiles()..selected = sample();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AppFavoriteFoldersPage(fileService: files),
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester, 'import-app-favorites-file');
    expect(
      find.byKey(const Key('confirm-app-favorites-file-import')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('搜索后仍导出完整收藏，支持单目录导出，取消不会提示成功', (tester) async {
    final files = MemoryFiles();
    final favorites = MemoryFavorites(sample());
    await tester.pumpWidget(
      MaterialApp(
        home: AppFavoriteFoldersPage(
          favoritesService: favorites,
          fileService: files,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('app-favorite-folders-search')),
      '不存在',
    );
    await tester.pump();
    await choose(tester, 'export-all-app-favorites');
    await tester.pumpAndSettle();
    expect(files.saved!.itemCount, 3);
    expect(files.saved!.folders, hasLength(3));
    await tester.enterText(
      find.byKey(const Key('app-favorite-folders-search')),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app-favorite-actions-empty')));
    await tester.pumpAndSettle();
    files.saveSucceeded = false;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('export-app-favorite-empty')));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(files.saved!.folders.single.id, 'empty');
    expect(files.saved!.itemCount, 0);
    expect(find.text('已导出 1 个收藏夹、0 条收藏。'), findsNothing);
  });

  testWidgets('文件选择期间禁用重复入口，取消后恢复', (tester) async {
    final files = MemoryFiles()..pending = Completer<AppFavoritesBackup?>();
    await tester.pumpWidget(
      MaterialApp(home: AppFavoriteFoldersPage(fileService: files)),
    );
    await tester.pumpAndSettle();
    await choose(tester, 'import-app-favorites-file');
    final menu = tester.widget<PopupMenuButton>(
      find.byKey(const Key('app-favorites-backup-menu')),
    );
    expect(menu.enabled, isFalse);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('create-app-favorite-folder')),
          )
          .onPressed,
      isNull,
    );
    files.pending!.complete(null);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuButton>(
            find.byKey(const Key('app-favorites-backup-menu')),
          )
          .enabled,
      isTrue,
    );
    expect(find.byType(AlertDialog), findsNothing);
  });
}
