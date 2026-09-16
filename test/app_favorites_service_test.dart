import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/services/app_favorites_service.dart';

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
