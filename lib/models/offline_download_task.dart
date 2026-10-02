import 'video_preview.dart';

/// Describes a durable queue entry independently of completed library records.
enum DownloadTaskStatus { queued, downloading, paused, failed, completed }

/// Stores stable video identity and progress, never signed URLs or cookies.
class OfflineDownloadTask {
  /// Creates an immutable task for exactly one video part and requested quality.
  const OfflineDownloadTask({
    required this.video,
    required this.part,
    required this.quality,
    required this.createdAt,
    this.status = DownloadTaskStatus.queued,
    this.receivedBytes = 0,
    this.totalBytes,
    this.error,
    this.bytesPerSecond = 0,
  });

  final VideoPreview video;
  final VideoPart part;
  final int quality;
  final DateTime createdAt;
  final DownloadTaskStatus status;
  final int receivedBytes;
  final int? totalBytes;
  final String? error;
  // Transfer speed is transient; restored tasks always start at zero.
  final double bytesPerSecond;

  /// Formats the current network transfer rate for both UI and notifications.
  String get speedLabel => bytesPerSecond >= 1024 * 1024
      ? '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s'
      : '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';

  /// Deduplicates the same BV/CID even when it is submitted from another page.
  String get id => '${video.bvid}:${part.cid}';

  /// Returns bounded progress or null while the server has not supplied a size.
  double? get progress => totalBytes == null || totalBytes! <= 0
      ? null
      : (receivedBytes / totalBytes!).clamp(0.0, 1.0);

  /// Applies a state transition while keeping immutable download identity.
  OfflineDownloadTask copyWith({
    DownloadTaskStatus? status,
    int? receivedBytes,
    int? totalBytes,
    String? error,
    double? bytesPerSecond,
  }) => OfflineDownloadTask(
    video: video,
    part: part,
    quality: quality,
    createdAt: createdAt,
    status: status ?? this.status,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    error: error,
    bytesPerSecond: (status ?? this.status) == DownloadTaskStatus.downloading
        ? bytesPerSecond ?? this.bytesPerSecond
        : 0,
  );

  /// Serializes only the metadata needed to re-resolve an expired media URL.
  Map<String, Object?> toJson() => {
    'bvid': video.bvid,
    'title': video.title,
    'ownerName': video.ownerName,
    'coverUrl': video.thumbnailUrl,
    'cid': part.cid,
    'pageNumber': part.pageNumber,
    'partTitle': part.title,
    'durationMs': part.duration.inMilliseconds,
    'quality': quality,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'error': error,
  };

  /// Rejects malformed queue data so initialization never silently overwrites it.
  factory OfflineDownloadTask.fromJson(Map<String, dynamic> json) {
    final bvid = json['bvid'] as String;
    final cid = (json['cid'] as num).toInt();
    final quality = (json['quality'] as num).toInt();
    final received = (json['receivedBytes'] as num).toInt();
    final total = (json['totalBytes'] as num?)?.toInt();
    if (!RegExp(r'^BV[0-9A-Za-z]{10}$').hasMatch(bvid) ||
        cid <= 0 ||
        quality <= 0 ||
        received < 0 ||
        (total != null && total <= 0)) {
      throw const FormatException('Invalid download task');
    }
    final part = VideoPart(
      pageNumber: (json['pageNumber'] as num).toInt(),
      cid: cid,
      title: json['partTitle'] as String,
      duration: Duration(milliseconds: (json['durationMs'] as num).toInt()),
    );
    return OfflineDownloadTask(
      video: VideoPreview(
        bvid: bvid,
        cid: cid,
        title: json['title'] as String,
        ownerName: json['ownerName'] as String,
        thumbnailUrl: json['coverUrl'] as String,
        duration: part.duration,
        parts: [part],
      ),
      part: part,
      quality: quality,
      createdAt: DateTime.parse(json['createdAt'] as String),
      status: DownloadTaskStatus.values.byName(json['status'] as String),
      receivedBytes: received,
      totalBytes: total,
      error: json['error'] as String?,
    );
  }
}
