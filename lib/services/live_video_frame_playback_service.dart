/// A visible frame and the backend's bounded media position when it was read.
class LiveVideoFrame {
  const LiveVideoFrame({
    required this.path,
    required this.position,
    required this.bvid,
    required this.cid,
  });

  final String path;
  final Duration position;
  final String bvid;
  final int cid;
}

/// Optional read-only capability. This must not pause, seek, open media or
/// substitute a thumbnail. A missing, protected or unverifiable frame is null.
abstract interface class LiveVideoFramePlaybackService {
  Future<LiveVideoFrame?> captureLiveVideoFrame();
}

/// No precise decoder timestamp is available from some rendered surfaces.
/// Refuse stale/discontinuous windows instead of labeling an ambiguous frame.
Duration? liveVideoFramePosition(Duration before, Duration after) {
  if (before.isNegative ||
      after < before ||
      after - before > const Duration(milliseconds: 350)) {
    return null;
  }
  return before + (after - before) ~/ 2;
}
