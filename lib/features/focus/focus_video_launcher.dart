import 'package:flutter/material.dart';

import '../../models/focus_session.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../player/player_page.dart';

/// 统一从首页 Pin 或专注记录查询视频详情并跳回正确分P和播放位置。
abstract final class FocusVideoLauncher {
  /// 打开记录关联的视频；查询失败时在当前页面显示可读错误。
  static Future<bool> open(
    BuildContext context,
    FocusSession session, {
    BilibiliService? service,
  }) async {
    final String? bvid = session.sourceBvid;
    if (bvid == null || bvid.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条专注记录没有关联视频')));
      return false;
    }
    final BilibiliService lookupService = service ?? BilibiliVideoInfoService();
    try {
      final VideoPreview video = await lookupService.lookupVideo(bvid);
      if (!context.mounted) {
        return false;
      }
      final player = buildPlayerPage(video, session);
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          // 播放页构建函数恢复记录中的分P和最后观看位置。
          builder: (BuildContext pageContext) => player,
        ),
      );
      return true;
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is BilibiliLookupException
                  ? error.message
                  : '暂时无法打开关联视频，请检查网络后重试',
            ),
          ),
        );
      }
      return false;
    }
  }

  /// 创建专注记录对应的播放器参数；零位置交给原生观看历史恢复，避免强制跳回开头。
  static PlayerPage buildPlayerPage(VideoPreview video, FocusSession session) {
    if (video.isCourse &&
        session.sourcePartCid != null &&
        !video.parts.any((part) => part.cid == session.sourcePartCid)) {
      throw const BilibiliLookupException('原课程章节已失效，请从课程目录重新选择。');
    }
    return PlayerPage(
      video: video,
      initialPartCid: session.sourcePartCid,
      initialPosition: session.sourcePosition > Duration.zero
          ? session.sourcePosition
          : null,
      initialPositionSource: PlayerInitialPositionSource.focus,
    );
  }
}
