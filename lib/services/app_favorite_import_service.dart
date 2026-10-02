import '../models/account_collection.dart';
import '../models/app_favorite.dart';
import 'app_favorites_service.dart';
import 'bilibili_account_data_service.dart';

/// 保存导入计数和中断原因；已经写入的收藏不会因后续请求失败而撤销。
class AppFavoriteImportResult {
  /// 创建完整或部分完成的导入结果。
  const AppFavoriteImportResult({
    this.imported = 0,
    this.duplicates = 0,
    this.unavailable = 0,
    this.folder,
    this.message,
  });

  final int imported;
  final int duplicates;
  final int unavailable;
  final AppFavoriteFolder? folder;
  final String? message;

  /// 为页面生成明确区分完成、暂停和失败的简短结果。
  String get summary =>
      '${message ?? '导入完成'}；'
      '新增 $imported 个，重复 $duplicates 个，失效 $unavailable 个。';
}

/// 将 B 站收藏分页复制到本机，不修改 B 站账号中的任何收藏。
class AppFavoriteImportService {
  /// 复用现有账号读取和本机存储服务。
  AppFavoriteImportService({
    required this.accountService,
    required this.favoritesService,
  });

  final BilibiliAccountDataService accountService;
  final AppFavoritesService favoritesService;

  /// 逐页持久化有效视频，支持停止和重试，重复 BV 不覆盖已有本机收藏。
  Future<AppFavoriteImportResult> importFolder({
    required FavoriteFolder source,
    AppFavoriteFolder? target,
    String? newFolderName,
    bool Function()? isCancelled,
    void Function(int imported)? onProgress,
  }) async {
    int imported = 0, duplicates = 0, unavailable = 0;
    AppFavoriteFolder? folder = target;
    final seen = <String>{};
    final pageSignatures = <String>{};
    int page = 1;
    final importTime = DateTime.now();

    // 结果函数始终报告已经成功持久化的数量。
    AppFavoriteImportResult result([String? message]) =>
        AppFavoriteImportResult(
          imported: imported,
          duplicates: duplicates,
          unavailable: unavailable,
          folder: folder,
          message: message,
        );

    try {
      if (!source.isAvailable) return result('这个 B 站收藏夹不可用');
      if (folder != null) {
        seen.addAll(
          (await favoritesService.loadItems(folder.id)).map((e) => e.bvid),
        );
      }
      while (true) {
        if (isCancelled?.call() == true) return result('导入已停止，已导入内容已保留');
        final response = await accountService.loadFavoriteVideos(
          source.mediaId,
          page: page,
        );
        if (isCancelled?.call() == true) return result('导入已停止，已导入内容已保留');
        if (!response.isSuccess) {
          return result(response.message ?? '读取 B 站收藏失败');
        }
        if (!pageSignatures.add(response.items.map((e) => e.bvid).join('|'))) {
          return result('分页未继续返回新内容，请稍后重试');
        }
        folder ??= await favoritesService.createFolder(
          newFolderName ?? source.title,
        );
        if (folder == null) return result('无法创建软件收藏夹，请重试');
        final additions = <AppFavoriteItem>[];
        final pageIds = <String>{};
        for (final video in response.items) {
          if (isCancelled?.call() == true) return result('导入已停止，已导入内容已保留');
          if (!video.isAvailable) {
            unavailable++;
            continue;
          }
          if (seen.contains(video.bvid) || !pageIds.add(video.bvid)) {
            duplicates++;
            continue;
          }
          additions.add(
            AppFavoriteItem(
              folderId: folder.id,
              bvid: video.bvid,
              title: video.title,
              coverUrl: video.coverUrl,
              ownerName: video.ownerName,
              durationText: _formatDuration(video.duration),
              addedAt:
                  video.favoritedAt ??
                  importTime.subtract(
                    Duration(microseconds: seen.length + additions.length),
                  ),
              partCount: video.partCount,
            ),
          );
        }
        if (isCancelled?.call() == true) return result('导入已停止，已导入内容已保留');
        final savedCount = await favoritesService.addItems(
          folder.id,
          additions,
        );
        if (savedCount == null) return result('本机保存失败，已导入内容已保留');
        duplicates += additions.length - savedCount;
        imported += savedCount;
        seen.addAll(pageIds);
        onProgress?.call(imported);
        if (!response.hasMore) return result();
        // 防止服务端反复返回相同页时无限请求。
        if (response.items.isEmpty) {
          return result('分页未继续返回新内容，请稍后重试');
        }
        page++;
      }
    } catch (_) {
      return result('导入中断，已导入内容已保留，请重试');
    }
  }

  /// 将收藏接口的总时长转换为软件收藏列表的时分秒文本。
  String _formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final tail =
        '${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
    return seconds >= 3600
        ? '${seconds ~/ 3600}:$tail'
        : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
