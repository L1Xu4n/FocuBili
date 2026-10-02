import '../models/offline_video_download.dart';
import 'offline_video_service.dart';

/// Resolves only verified completed files for an exact BV/CID pair.
class PlaybackSourceResolver {
  /// Reuses the offline library's ownership and file-size checks.
  const PlaybackSourceResolver(this.library);
  final OfflineVideoService library;

  /// Returns local media only when requested; ordinary playback defaults online.
  Future<OfflineVideoDownload?> resolve(
    String bvid,
    int cid, {
    required bool preferLocal,
    bool requireLocal = false,
  }) async {
    List<OfflineVideoDownload> files;
    try {
      files = await library.loadDownloads();
    } catch (_) {
      if (requireLocal) rethrow;
      return null;
    }
    for (final file in files) {
      if (file.bvid == bvid &&
          file.cid == cid &&
          (preferLocal || requireLocal)) {
        return file;
      }
    }
    if (requireLocal) throw const OfflineVideoException('本地缓存已丢失或损坏，请重新下载。');
    return null;
  }
}
