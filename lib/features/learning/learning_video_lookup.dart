import '../../models/learning_list_entry.dart';
import '../../models/video_preview.dart';
import '../../services/bilibili_service.dart';
import '../../services/offline_video_service.dart';
import '../../services/playback_source_resolver.dart';

/// Finds metadata for the exact saved BV/CID. An online response omitting the
/// part is returned only so callers can report it as removed and retain progress.
/// Reuse known online metadata when continuing within the same video.
Future<VideoPreview> lookupLearningVideo(
  LearningListEntry entry, {
  required BilibiliService videoService,
  required OfflineVideoService offlineVideoService,
  required bool preferCache,
  VideoPreview? knownOnlineVideo,
}) async {
  final bvid = entry.bvid.trim();
  Future<VideoPreview?>? cacheLookup;
  Future<VideoPreview?> lookupCache() =>
      cacheLookup ??= PlaybackSourceResolver(offlineVideoService)
          .resolve(bvid, entry.partCid, preferLocal: true)
          .then((file) {
            if (file == null) return null;
            return file.toPreview(
              fallbackPart: VideoPart(
                pageNumber: entry.partPageNumber,
                cid: entry.partCid,
                title: entry.partTitle,
                duration: entry.duration > Duration.zero
                    ? entry.duration
                    : file.duration,
              ),
            );
          });

  if (preferCache) {
    final cached = await lookupCache();
    if (cached != null) return cached;
  }
  try {
    final video = knownOnlineVideo ?? await videoService.lookupVideo(bvid);
    if (video.bvid != bvid) {
      throw const BilibiliLookupException('视频编号与学习任务不匹配。');
    }
    if (!video.fromOfflineCache) {
      if (video.parts.any((part) => part.cid == entry.partCid)) return video;
      return await lookupCache() ?? video;
    }
    // Generic lookup can return metadata for a different *cached* part even
    // if its metadata describes this CID. Playback still needs the exact file.
    final cached = await lookupCache();
    if (cached != null) return cached;
    throw const BilibiliLookupException('该分 P 没有可用的本地缓存。');
  } catch (_) {
    final cached = await lookupCache();
    if (cached != null) return cached;
    rethrow;
  }
}
