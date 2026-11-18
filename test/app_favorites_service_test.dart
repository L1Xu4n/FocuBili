import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/services/app_favorites_service.dart';

/// Rejects folder writes without changing the in-memory stored value.
class _RejectingPreferences implements SharedPreferences {
  _RejectingPreferences(this.delegate, {this.throws = false});
  final SharedPreferences delegate;
  final bool throws;

  @override
  String? getString(String key) => delegate.getString(key);

  @override
  Future<bool> setString(String key, String value) async {
    if (throws) throw StateError('storage unavailable');
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppFavoritesService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    service = AppFavoritesService();
  });

  test('创建、重命名与删除软件收藏夹', () async {
    expect(await service.loadFolders(), isEmpty);

    final AppFavoriteFolder? folder = await service.createFolder('  学习视频  ');
    expect(folder, isNotNull);
    expect(folder!.name, '学习视频');

    expect(await service.renameFolder(folder.id, '刷题集锦'), isTrue);
    final List<AppFavoriteFolder> folders = await service.loadFolders();
    expect(folders.single.name, '刷题集锦');

    expect(await service.deleteFolder(folder.id), isTrue);
    expect(await service.loadFolders(), isEmpty);
  });

  test(
    'successful rename notifies across service instances after persistence',
    () async {
      final folder = (await service.createFolder('Before'))!;
      final prefs = await SharedPreferences.getInstance();
      var notifications = 0;
      void listener() {
        notifications++;
        expect(prefs.getString('app_favorites.folders_v1'), contains('After'));
      }

      AppFavoritesService.folderNamesRevision.addListener(listener);
      addTearDown(
        () => AppFavoritesService.folderNamesRevision.removeListener(listener),
      );

      expect(
        await AppFavoritesService().renameFolder(folder.id, 'After'),
        isTrue,
      );
      expect(notifications, 1);
    },
  );

  test('invalid or failed renames do not publish a name change', () async {
    final folder = (await service.createFolder('Before'))!;
    final revision = AppFavoritesService.folderNamesRevision.value;
    expect(await service.renameFolder(folder.id, '  '), isFalse);
    expect(await service.renameFolder('missing', 'After'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    for (final throws in [false, true]) {
      final failing = AppFavoritesService(
        preferencesLoader: () async =>
            _RejectingPreferences(prefs, throws: throws),
      );
      expect(await failing.renameFolder(folder.id, 'After'), isFalse);
    }
    expect(AppFavoritesService.folderNamesRevision.value, revision);
    expect((await service.loadFolders()).single.name, 'Before');
  });

  test('空白名称不允许创建或重命名', () async {
    expect(await service.createFolder('   '), isNull);
    final AppFavoriteFolder? folder = await service.createFolder('收藏');
    expect(folder, isNotNull);
    expect(await service.renameFolder(folder!.id, '  '), isFalse);
  });

  test('同一 BV 不重复加入，移除后再次加入成功', () async {
    final AppFavoriteFolder? folder = await service.createFolder('默认');
    final AppFavoriteItem item = AppFavoriteItem(
      folderId: folder!.id,
      bvid: 'BV1GJ411x7h7',
      title: '示例视频',
      coverUrl: '',
      ownerName: 'UP 主',
      durationText: '03:00',
      addedAt: DateTime.now(),
    );

    expect(await service.addItem(item), isTrue);
    expect(await service.addItem(item), isTrue);
    expect((await service.loadItems(folder.id)).length, 1);

    expect(await service.removeItem(folder.id, 'BV1GJ411x7h7'), isTrue);
    expect(await service.loadItems(folder.id), isEmpty);
    expect(await service.addItem(item), isTrue);
    expect((await service.loadItems(folder.id)).length, 1);
  });

  test('删除收藏夹时一并清空其中视频', () async {
    final AppFavoriteFolder? folder = await service.createFolder('临时');
    final AppFavoriteItem item = AppFavoriteItem(
      folderId: folder!.id,
      bvid: 'BV1xx411c7mD',
      title: '删除测试',
      coverUrl: '',
      ownerName: '',
      durationText: '',
      addedAt: DateTime.now(),
    );
    await service.addItem(item);
    expect(await service.totalItemCount(), 1);

    await service.deleteFolder(folder.id);
    expect(await service.loadFolders(), isEmpty);
    expect(await service.totalItemCount(), 0);
  });
}
