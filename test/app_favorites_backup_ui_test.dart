import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

// 转场期间页面显示不定进度条，用限定帧时间替代等待所有动画完成。
Future<void> advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> tapAction(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await advance(tester);
}

Future<void> choose(
  WidgetTester tester,
  String key, {
  String? method = 'file',
}) async {
  await tapAction(tester, find.byKey(const Key('app-favorites-backup-menu')));
  await tapAction(tester, find.byKey(Key(key)));
  if (method != null) {
    await tapAction(tester, find.byKey(Key('app-favorites-method-$method')));
  }
}

void mockClipboard(Future<Object?> Function(MethodCall) handle) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method.startsWith('Clipboard.')) return handle(call);
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
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
      await choose(tester, 'import-app-favorites-backup');
      expect(find.textContaining('3 个收藏夹、3 条收藏'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await favorites.loadFolders(), isEmpty);
      await choose(tester, 'import-app-favorites-backup');
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
    await choose(tester, 'import-app-favorites-backup');
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
    await advance(tester);
    await tapAction(tester, find.byKey(const Key('app-favorites-method-file')));
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
    await choose(tester, 'import-app-favorites-backup');
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

  testWidgets('文本和文件使用相同 JSON；剪贴板往返需确认且再次合并不会重复', (tester) async {
    String? clipboard;
    var reads = 0, writes = 0;
    mockClipboard((call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          final args = call.arguments as Map;
          clipboard = args['text'] as String;
          writes++;
        case 'Clipboard.getData':
          reads++;
          return {'text': clipboard};
      }
      return null;
    });
    final files = MemoryFiles();
    await tester.pumpWidget(
      MaterialApp(
        home: AppFavoriteFoldersPage(
          key: const Key('source'),
          favoritesService: MemoryFavorites(sample()),
          fileService: files,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester, 'export-all-app-favorites', method: 'text');
    expect(clipboard, utf8.decode(sample().toBytes()));
    expect(writes, 1);
    expect(reads, 0);
    expect(files.saved, isNull);
    expect(find.textContaining('已复制到剪贴板'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(AppFavoriteFoldersPage)),
    ).removeCurrentSnackBar();
    await advance(tester);

    // 换一套空的实际持久化服务，测试导回而非重复查看导出源。
    final favorites = AppFavoritesService();
    await tester.pumpWidget(
      MaterialApp(
        home: AppFavoriteFoldersPage(
          key: const Key('destination'),
          favoritesService: favorites,
          fileService: files,
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await choose(tester, 'import-app-favorites-backup', method: 'text');
      expect(reads, i, reason: '打开导入页不能主动读取剪贴板');
      await tapAction(tester, find.text('从剪贴板粘贴'));
      expect(reads, i + 1);
      await tapAction(tester, find.text('预览导入'));
      expect(find.textContaining('3 个收藏夹、3 条收藏'), findsWidgets);
      if (i == 0) expect(await favorites.loadFolders(), isEmpty);
      await tapAction(tester, find.text('合并导入'));
      await tester.pumpAndSettle();
      expect(await favorites.totalItemCount(), 3);
      expect((await favorites.loadFolders()).map((f) => f.id), [
        'study',
        'empty',
        'music',
      ]);
      expect(find.textContaining('跳过 ${i == 0 ? 0 : 3} 条重复'), findsOneWidget);
      // 移除上一轮提示，避免影响下一次验证和动画。
      ScaffoldMessenger.of(
        tester.element(find.byType(AppFavoriteFoldersPage)),
      ).removeCurrentSnackBar();
      await advance(tester);
    }
  });

  testWidgets('单收藏夹复制仅含所选目录，剪贴板失败不误报成功', (tester) async {
    String? clipboard;
    final blocked = Completer<void>();
    var fail = false;
    mockClipboard((call) async {
      if (call.method == 'Clipboard.setData') {
        if (fail) throw PlatformException(code: 'denied');
        await blocked.future;
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    final files = MemoryFiles();
    await tester.pumpWidget(
      MaterialApp(
        home: AppFavoriteFoldersPage(
          favoritesService: MemoryFavorites(sample()),
          fileService: files,
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> selectFolder() async {
      await tapAction(
        tester,
        find.byKey(const Key('app-favorite-actions-study')),
      );
      await tapAction(
        tester,
        find.byKey(const Key('export-app-favorite-study')),
      );
      await tapAction(
        tester,
        find.byKey(const Key('app-favorites-method-text')),
      );
    }

    await selectFolder();
    expect(find.textContaining('已复制到剪贴板'), findsNothing);
    expect(
      tester
          .widget<PopupMenuButton>(
            find.byKey(const Key('app-favorites-backup-menu')),
          )
          .enabled,
      isFalse,
    );
    blocked.complete();
    await advance(tester);
    expect(AppFavoritesBackup.fromText(clipboard!).folders.single.id, 'study');
    expect(AppFavoritesBackup.fromText(clipboard!).itemCount, 2);
    expect(files.saved, isNull);
    expect(find.textContaining('已复制到剪贴板'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(AppFavoriteFoldersPage)),
    ).removeCurrentSnackBar();
    await advance(tester);
    fail = true;
    await selectFolder();
    expect(find.textContaining('无法写入剪贴板'), findsOneWidget);
    expect(find.textContaining('已复制到剪贴板'), findsNothing);
  });

  testWidgets('取消方式、空剪贴板、无效手输、取消预览都不写入，可改正文本', (tester) async {
    var requests = 0;
    mockClipboard((call) async {
      if (call.method == 'Clipboard.getData') {
        requests++;
        if (requests == 1) return null;
        throw PlatformException(code: 'read_denied');
      }
      return null;
    });
    final favorites = MemoryFavorites();
    await tester.pumpWidget(
      MaterialApp(home: AppFavoriteFoldersPage(favoritesService: favorites)),
    );
    await tester.pumpAndSettle();
    await choose(tester, 'import-app-favorites-backup', method: null);
    await tapAction(tester, find.text('取消'));
    expect(requests, 0);
    await choose(tester, 'import-app-favorites-backup', method: 'text');
    final field = find.byKey(const Key('app-favorites-backup-text'));
    await tapAction(tester, find.text('从剪贴板粘贴'));
    expect(find.textContaining('剪贴板没有文本'), findsOneWidget);
    await tapAction(tester, find.text('从剪贴板粘贴'));
    expect(find.textContaining('无法读取剪贴板'), findsOneWidget);
    await tester.enterText(field, '{bad');
    await tapAction(tester, find.text('预览导入'));
    expect(find.textContaining('未导入任何内容'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, '{bad');
    expect(favorites.backup, isNull);
    await tester.enterText(field, utf8.decode(sample().toBytes()));
    await tapAction(tester, find.text('预览导入'));
    expect(find.text('合并导入'), findsOneWidget);
    await tapAction(tester, find.text('取消'));
    expect(favorites.backup, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消文本输入后迟到的剪贴板内容不会重开预览或写收藏', (tester) async {
    final pending = Completer<Object?>();
    mockClipboard(
      (call) async =>
          call.method == 'Clipboard.getData' ? pending.future : null,
    );
    final favorites = MemoryFavorites();
    await tester.pumpWidget(
      MaterialApp(home: AppFavoriteFoldersPage(favoritesService: favorites)),
    );
    await tester.pumpAndSettle();
    await choose(tester, 'import-app-favorites-backup', method: 'text');
    await tapAction(tester, find.text('从剪贴板粘贴'));
    await tapAction(tester, find.text('取消'));
    pending.complete({'text': utf8.decode(sample().toBytes())});
    await advance(tester);
    expect(find.text('合并导入'), findsNothing);
    expect(favorites.backup, isNull);
    expect(tester.takeException(), isNull);
  });
}
