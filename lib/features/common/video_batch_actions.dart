import 'package:flutter/material.dart';
import '../../models/public_profile.dart';
import '../../services/bilibili_account_data_service.dart';
import '../../services/app_favorites_service.dart';
import '../../services/bilibili_interaction_service.dart';
import '../../services/bilibili_service.dart';
import '../../services/learning_list_service.dart';
import '../learning/learning_add_sheet.dart';
import 'video_save_destination_dialog.dart';
import 'video_favorites_batch_dialog.dart';

/// 两种独立视频列表的共同保存路径；没有选目标或按取消，不写入任何内容。
class VideoBatchActions {
  VideoBatchActions({
    required this.learningService,
    required this.videoService,
    AppFavoritesService? appFavoritesService,
    BilibiliAccountDataService? accountService,
    BilibiliInteractionService? interactionService,
  }) : appFavoritesService = appFavoritesService ?? AppFavoritesService(),
       accountService = accountService ?? BilibiliAccountDataService(),
       interactionService = interactionService ?? BilibiliInteractionService();

  final LearningListService learningService;
  final BilibiliService videoService;
  final AppFavoritesService appFavoritesService;
  final BilibiliAccountDataService accountService;
  final BilibiliInteractionService interactionService;

  Future<bool> run(
    BuildContext context, {
    required List<CreatorVideo> videos,
    String ownerName = '',
    VideoSaveDestination? destination,
  }) async {
    final seen = <String>{};
    final items = videos
        .where((e) => e.bvid.isNotEmpty && seen.add(e.bvid))
        .toList(growable: false);
    if (items.isEmpty) return false;
    try {
      final target =
          destination ??
          await chooseVideoSaveDestination(context, count: items.length);
      if (!context.mounted || target == null) return false;
      if (target == VideoSaveDestination.learning) {
        final result = await LearningAddSheet.showSelectedVideos(
          context,
          items: items,
          service: learningService,
          videoService: videoService,
        );
        if (result == null || !context.mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '学习清单：新增 ${result.addedIds.length} 项、已有 ${result.existingIds.length} 项，原有进度已保留。',
            ),
          ),
        );
        return true;
      }
      return await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => VideoFavoritesBatchDialog(
              items: items,
              ownerName: ownerName,
              local: appFavoritesService,
              account: accountService,
              interactions: interactionService,
              details: videoService,
            ),
          ) ??
          false;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未完成保存，请检查后重试。')));
      }
      return false;
    }
  }
}
