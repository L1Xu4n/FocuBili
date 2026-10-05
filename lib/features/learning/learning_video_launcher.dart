import 'learning_add_sheet.dart';
import 'package:flutter/material.dart';

import '../../models/learning_list_entry.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../../services/learning_list_service.dart';
import '../player/player_page.dart';

/// 统一从学习清单查询视频详情，并恢复任务保存的分P和播放时间点。
abstract final class LearningVideoLauncher {
  /// 打开学习任务对应的视频；查询失败时在当前页面显示不打断操作的提示。
  static Future<bool> open(
    BuildContext context,
    LearningListEntry entry, {
    BilibiliService? service,
    LearningListService? learningListService,
  }) async {
    final String bvid = entry.bvid.trim();
    if (bvid.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条学习任务没有有效的视频编号')));
      return false;
    }
    final BilibiliService videoService = service ?? BilibiliVideoInfoService();
    try {
      final VideoPreview video = await videoService.lookupVideo(bvid);
      if (!context.mounted) {
        return false;
      }
      if (!video.parts.any((part) => part.cid == entry.partCid)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('原分 P 已失效，请重新选择；旧任务进度保留。')),
        );
        await LearningAddSheet.show(
          context,
          video: video,
          service: learningListService ?? LearningListService(),
        );
        return false;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          // 播放页构建函数恢复学习任务的分P、时间点和同一份本机清单服务。
          builder: (BuildContext pageContext) => buildPlayerPage(
            video,
            entry,
            videoService: videoService,
            learningListService: learningListService,
          ),
        ),
      );
      return true;
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('暂时无法打开学习视频，请检查网络后重试')));
      }
      return false;
    }
  }

  /// 按保存的 CID 创建带学习位置的播放器；CID 失效时拒绝套用旧进度。
  static PlayerPage buildPlayerPage(
    VideoPreview video,
    LearningListEntry entry, {
    BilibiliService? videoService,
    LearningListService? learningListService,
  }) {
    final VideoPart part = _findPart(video, entry);
    return PlayerPage(
      video: video,
      bilibiliService: videoService,
      learningListService: learningListService,
      initialPartCid: part.cid,
      initialPosition: entry.position > Duration.zero ? entry.position : null,
      initialPositionSource: PlayerInitialPositionSource.learning,
    );
  }

  /// 按 CID 找回同一分 P；页码变化不会把旧进度应用到其他分 P。
  static VideoPart _findPart(VideoPreview video, LearningListEntry entry) {
    for (final VideoPart part in video.parts) {
      if (part.cid == entry.partCid) {
        return part;
      }
    }
    throw const BilibiliLookupException('原分 P 已失效，请重新选择');
  }
}
