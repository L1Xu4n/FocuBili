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

  /// 创建带学习位置的播放器，保存的 CID 失效时播放器会按分P序号安全回退。
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

  /// 优先按 CID 找回任务分P，旧数据 CID 失效时再按页码匹配。
  static VideoPart _findPart(VideoPreview video, LearningListEntry entry) {
    for (final VideoPart part in video.parts) {
      if (part.cid == entry.partCid) {
        return part;
      }
    }
    for (final VideoPart part in video.parts) {
      if (part.pageNumber == entry.partPageNumber) {
        return part;
      }
    }
    return video.initialPart;
  }
}
