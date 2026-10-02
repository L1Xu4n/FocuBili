import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/app_favorite_folders_page.dart';
import 'package:focubili/models/account_collection.dart';
import 'package:focubili/models/app_favorite.dart';
import 'package:focubili/services/app_favorite_import_service.dart';
import 'package:focubili/services/app_favorites_service.dart';
import 'package:focubili/services/bilibili_account_data_service.dart';

const source = FavoriteFolder(
  mediaId: 42,
  title: 'B 站学习收藏',
  coverUrl: '',
  mediaCount: 4,
  isAvailable: true,
);

/// 创建带 P 数和原收藏时间的有效或失效视频。
FavoriteVideo video(String bvid, {bool available = true}) => FavoriteVideo(
  bvid: bvid,
  title: '学习视频 $bvid',
  coverUrl: '',
  ownerName: '老师',
  duration: const Duration(seconds: 125),
  partCount: 3,
  favoritedAt: DateTime(2026, 9, 1),
  playCount: 0,
  danmakuCount: 0,
  isAvailable: available,
);

/// 提供固定分页，模拟重复视频和中途网络故障。
class AccountPages extends BilibiliAccountDataService {
  /// 接收每一页的固定响应，调用过程不访问网络。
  AccountPages(this.pages, {this.folders = const [source]});
  final List<AccountDataPage<FavoriteVideo>> pages;
  final List<FavoriteFolder> folders;
  final requested = <int>[];

  /// 返回一份可以选择的 B 站收藏夹列表。
  @override
  Future<AccountDataPage<FavoriteFolder>> loadFavoriteFolders() async =>
      AccountDataPage.success(items: folders, page: 1, hasMore: false);

  /// 根据真实页码读取测试响应，并记录是否继续翻页。
  @override
  Future<AccountDataPage<FavoriteVideo>> loadFavoriteVideos(
    int mediaId, {
    int page = 1,
  }) async {
    requested.add(page);
    return pages[page - 1];
  }
}

/// 模拟本机写入失败，确认导入结果不会误报成功。
class RejectingFavorites extends AppFavoritesService {
  /// 拒绝整页写入而保留原本的软件收藏。
  @override
  Future<int?> addItems(
    String folderId,
    List<AppFavoriteItem> incoming,
  ) async => null;
}

/// 验证分页、失败保留、停止和入口的实际行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('跨页去重、跳过失效，并保存 P 数与收藏时间', () async {
    final favorites = AppFavoritesService();
    final account = AccountPages([
      AccountDataPage.success(
        items: [video('BV1GJ411x7h7'), video('BV1xx411c7mD', available: false)],
        page: 1,
        hasMore: true,
      ),
      AccountDataPage.success(
        items: [video('BV1GJ411x7h7'), video('BV1xx411c7mE')],
        page: 2,
        hasMore: false,
      ),
    ]);
    final result = await AppFavoriteImportService(
      accountService: account,
      favoritesService: favorites,
    ).importFolder(source: source);
    expect(account.requested, [1, 2]);
    expect(result.imported, 2);
    expect(result.duplicates, 1);
    expect(result.unavailable, 1);
    expect(result.message, isNull);
    final items = await favorites.loadItems(result.folder!.id);
    expect(items, hasLength(2));
    expect(items.first.partCount, 3);
    expect(items.first.durationText, '2:05');
    expect(items.first.addedAt, DateTime(2026, 9, 1));
  });

  test('中途断网保留第一页，重试跳过重复页仍继续读取新视频', () async {
    final favorites = AppFavoritesService();
    final account = AccountPages([
      AccountDataPage.success(
        items: [video('BV1GJ411x7h7')],
        page: 1,
        hasMore: true,
      ),
      AccountDataPage<FavoriteVideo>.networkError(page: 2),
    ]);
    final service = AppFavoriteImportService(
      accountService: account,
      favoritesService: favorites,
    );
    final first = await service.importFolder(source: source);
    expect(first.imported, 1);
    expect(first.message, isNotNull);
    account.pages[1] = AccountDataPage.success(
      items: [video('BV1xx411c7mD')],
      page: 2,
      hasMore: true,
    );
    account.pages.add(
      AccountDataPage.success(
        items: [video('BV1xx411c7mE')],
        page: 3,
        hasMore: false,
      ),
    );
    final retry = await service.importFolder(
      source: source,
      target: first.folder,
    );
    expect(retry.imported, 2);
    expect(retry.duplicates, 1);
    expect(retry.message, isNull);
    expect(await favorites.loadFolders(), hasLength(1));
    expect(await favorites.loadItems(first.folder!.id), hasLength(3));
  });

  test('本机写入失败不计入成功数量，提前停止不读取账号数据', () async {
    final favorites = RejectingFavorites();
    final account = AccountPages([
      AccountDataPage.success(
        items: [video('BV1GJ411x7h7')],
        page: 1,
        hasMore: false,
      ),
    ]);
    final service = AppFavoriteImportService(
      accountService: account,
      favoritesService: favorites,
    );
    final stopped = await service.importFolder(
      source: source,
      isCancelled: () => true,
    );
    expect(account.requested, isEmpty);
    expect(stopped.imported, 0);
    final failed = await service.importFolder(source: source);
    expect(failed.imported, 0);
    expect(failed.message, contains('保存失败'));
    expect(await favorites.loadItems(failed.folder!.id), isEmpty);
  });

  testWidgets('软件收藏夹入口可选择来源并完成导入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final favorites = AppFavoritesService();
    final account = AccountPages(
      [
        AccountDataPage.success(
          items: [video('BV1GJ411x7h7')],
          page: 1,
          hasMore: false,
        ),
      ],
      folders: [
        source,
        for (var index = 1; index < 20; index++)
          FavoriteFolder(
            mediaId: 42 + index,
            title: '其他收藏夹 $index',
            coverUrl: '',
            mediaCount: 1,
            isAvailable: true,
          ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppFavoriteFoldersPage(
          favoritesService: favorites,
          accountService: account,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-bilibili-favorites')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(source.title));
    await tester.pumpAndSettle();
    final start = find.byKey(const Key('start-favorite-import'));
    expect(start.hitTestable(), findsOneWidget);
    final controls = find.byKey(const Key('favorite-import-controls'));
    final beforeScroll = tester.getRect(controls);
    await tester.drag(
      find.byKey(const Key('favorite-import-sources')),
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(controls), beforeScroll);
    expect(start.hitTestable(), findsOneWidget);
    // 存储队列可能由前面的普通单元测试创建，切回真实异步区完成其微任务。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('start-favorite-import')));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('新增 1 个'), findsOneWidget);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 2),
    );
    expect(await favorites.totalItemCount(), 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(source.title), findsOneWidget);
  });
}
