import '../models/video_preview.dart';

/// Optional capability implemented by backends that support offline media.
abstract interface class LocalFilePlaybackService {
  /// Opens a local file without requesting online metadata or sending credentials.
  Future<void> openLocalFile({
    required String filePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
  });
}

/// 可选的分离音视频缓存能力，旧的单文件后端和测试替身继续沿用原接口。
abstract interface class LocalTrackPlaybackService
    implements LocalFilePlaybackService {
  /// 以同一时间轴打开本地视频和音频文件，不请求在线媒体。
  Future<void> openLocalTracks({
    required String videoFilePath,
    required String audioFilePath,
    String title = '',
    Duration? initialPosition,
    VideoPreview? video,
    VideoPart? part,
  });
}
