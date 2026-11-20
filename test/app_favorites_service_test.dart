import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/models/app_favorites_backup.dart';
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

/// Models the optimistic preference cache when the write never reaches disk.
class _RejectingCachedPreferences extends _RejectingPreferences {
  _RejectingCachedPreferences(super.delegate, {required super.throws});

  final cached = <String, String>{};
  int reloads = 0;

  @override
  String? getString(String key) => cached[key] ?? super.getString(key);

  @override
  Future<bool> setString(String key, String value) {
    cached[key] = value;
    return super.setString(key, value);
  }

  @override
  Future<void> reload() async {
    reloads++;
    cached.clear();
  }
}

/// Advances only this zone's microtasks, like an individual widget test.
class _MicrotaskClock {
  final _pending = Queue<void Function()>();
  late final zone = Zone.current.fork(
    specification: ZoneSpecification(
      scheduleMicrotask: (_, _, zone, task) {
        _pending.add(() => zone.run(task));
      },
    ),
  );

  void pump() {
    while (_pending.isNotEmpty) {
      _pending.removeFirst()();
    }
  }
}

AppFavoriteItem _video(String folderId, String bvid, int hours) =>
    AppFavoriteItem(
      folderId: folderId,
      bvid: bvid,
      title: 'title $bvid',
      coverUrl: '',
      ownerName: 'UP 主',
      durationText: '03:00',
      addedAt: DateTime.utc(2026, 11, 1, hours),
      partCount: 2,
    );

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

  test('排序只移动当前目录，不覆盖其他实例保存的元数据或新增目录', () async {
    final a = (await service.createFolder('第一'))!;
    final b = (await service.createFolder('第二'))!;
    final c = (await service.createFolder('第三'))!;
    final peer = AppFavoritesService();
    final rename = peer.renameFolder(b.id, '已重命名');
    final reorder = service.reorderFolders([c.id, a.id, b.id]);
    expect(await rename, isTrue);
    expect(await reorder, isTrue);
    final loaded = await peer.loadFolders();
    expect(loaded.map((folder) => folder.id), [c.id, a.id, b.id]);
    expect(loaded.last.name, '已重命名');
    expect(loaded.last.createdAt, b.createdAt);

    final add = peer.createFolder('新增');
    final stale = service.reorderFolders([b.id, a.id, c.id]);
    final d = (await add)!;
    expect(await stale, isFalse);
    expect((await service.loadFolders()).map((folder) => folder.id), [
      c.id,
      a.id,
      b.id,
      d.id,
    ]);
    expect(await service.reorderFolders([a.id, b.id, c.id, c.id]), isFalse);
  });

  test('视频旧数据默认最新优先，手动排序在导出和新设备导入后保持', () async {
    final a = (await service.createFolder('数学'))!;
    final b = (await service.createFolder('英语'))!;
    final first = _video(a.id, 'BV1GJ411x7h7', 1);
    final second = _video(a.id, 'BV1xx411c7mD', 2);
    final third = _video(a.id, 'BV1ab411c7Zk', 3);
    final latest = _video(a.id, 'BV1ac411c7Zk', 4);
    await service.addItems(a.id, [second, first, third]);
    await service.addItem(_video(b.id, first.bvid, 1));
    expect((await service.loadItems(a.id)).map((item) => item.bvid), [
      third.bvid,
      second.bvid,
      first.bvid,
    ]);

    expect(await service.reorderFolders([b.id, a.id]), isTrue);
    expect(
      await service.reorderItems(a.id, [first.bvid, third.bvid, second.bvid]),
      isTrue,
    );
    await service.addItem(latest);
    expect(
      await service.reorderItems(a.id, [second.bvid, first.bvid, third.bvid]),
      isFalse,
    );
    expect(
      (await AppFavoritesService().loadItems(a.id)).map((item) => item.bvid),
      [latest.bvid, first.bvid, third.bvid, second.bvid],
    );
    final snapshot = AppFavoritesBackup.fromBytes(
      (await service.exportBackup()).toBytes(),
    );
    expect(snapshot.folders.map((folder) => folder.id), [b.id, a.id]);
    expect(snapshot.items[a.id]!.map((item) => item.addedAt), [
      latest.addedAt,
      first.addedAt,
      third.addedAt,
      second.addedAt,
    ]);

    SharedPreferences.setMockInitialValues({});
    final receiver = AppFavoritesService();
    final imported = await receiver.importBackup(snapshot);
    expect(imported.createdFolders, 2);
    expect((await receiver.loadFolders()).map((folder) => folder.id), [
      b.id,
      a.id,
    ]);
    expect((await receiver.loadItems(a.id)).map((item) => item.bvid), [
      latest.bvid,
      first.bvid,
      third.bvid,
      second.bvid,
    ]);
    expect((await receiver.loadItems(b.id)).single.bvid, first.bvid);

    final removal = receiver.removeItem(a.id, latest.bvid);
    final stale = service.reorderItems(a.id, [
      first.bvid,
      second.bvid,
      third.bvid,
      latest.bvid,
    ]);
    expect(await removal, isTrue);
    expect(await stale, isFalse);
    expect((await receiver.loadItems(a.id)).map((item) => item.bvid), [
      first.bvid,
      third.bvid,
      second.bvid,
    ]);
  });

  test('拒绝或异常的排序写入不会留下缓存中的假顺序', () async {
    final a = (await service.createFolder('第一'))!;
    final b = (await service.createFolder('第二'))!;
    final first = _video(a.id, 'BV1GJ411x7h7', 1);
    final newer = _video(a.id, 'BV1xx411c7mD', 2);
    await service.addItems(a.id, [first, newer]);
    final revision = AppFavoritesService.contentsRevision.value;
    final prefs = await SharedPreferences.getInstance();
    for (final throws in [false, true]) {
      final backend = _RejectingCachedPreferences(prefs, throws: throws);
      final failing = AppFavoritesService(
        preferencesLoader: () async => backend,
      );
      expect(await failing.reorderFolders([b.id, a.id]), isFalse);
      expect(
        await failing.reorderItems(a.id, [first.bvid, newer.bvid]),
        isFalse,
      );
      expect(backend.reloads, 2);
      expect((await failing.loadFolders()).map((folder) => folder.id), [
        a.id,
        b.id,
      ]);
      expect((await failing.loadItems(a.id)).map((item) => item.bvid), [
        newer.bvid,
        first.bvid,
      ]);
    }
    expect(AppFavoritesService.contentsRevision.value, revision);
  });

  test(
    'a drained write queue does not depend on the previous test zone',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final before = _MicrotaskClock();
      final after = _MicrotaskClock();
      String? first, second;
      final a = AppFavoritesService(preferencesLoader: () async => prefs);
      final b = AppFavoritesService(preferencesLoader: () async => prefs);

      before.zone.run(() {
        unawaited(
          a.createFolder('first').then((folder) => first = folder?.name),
        );
      });
      // Nothing drives the previous clock after its test has ended.
      await Future<void>.delayed(Duration.zero);
      before.pump();
      expect(first, 'first');

      after.zone.run(() {
        unawaited(
          b.createFolder('second').then((folder) => second = folder?.name),
        );
      });
      after.pump();
      expect(second, 'second');
    },
  );
}
