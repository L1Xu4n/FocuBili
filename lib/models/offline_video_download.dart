/// 标识一条离线下载任务的当前状态。
enum OfflineDownloadStatus { downloading, ready, failed }

/// 表示一条已下载到本机的离线视频，支持直接播放、删除和统计占用空间。
///
/// 下载文件保存在应用私有目录，卸载应用或清理数据时会随应用一起移除；
/// 离线缓存不写入 B 站账号，也不影响原视频的在线播放。
class OfflineVideoDownload {
  /// 创建一条不可变的离线视频记录。
  const OfflineVideoDownload({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.coverUrl,
    required this.ownerName,
    required this.filePath,
    required this.sizeBytes,
    required this.qualityId,
    required this.qualityLabel,
    required this.duration,
    required this.downloadedAt,
    required this.status,
  });

  /// 视频 BV 号。
  final String bvid;

  /// 下载时对应的分P编号，离线文件只包含该分P。
  final int cid;

  /// 视频标题。
  final String title;

  /// 视频封面 HTTPS 地址；无法确认安全地址时为空字符串。
  final String coverUrl;

  /// 视频作者昵称。
  final String ownerName;

  /// 本地视频文件的绝对路径。
  final String filePath;

  /// 下载文件占用的字节数。
  final int sizeBytes;

  /// 下载清晰度编号。
  final int qualityId;

  /// 清晰度中文名称（例如“清晰 480P”）。
  final String qualityLabel;

  /// 视频总时长。
  final Duration duration;

  /// 下载完成时间。
  final DateTime downloadedAt;

  /// 当前下载状态。
  final OfflineDownloadStatus status;

  /// 序列化为可写入本机 JSON 的对象。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'bvid': bvid,
      'cid': cid,
      'title': title,
      'coverUrl': coverUrl,
      'ownerName': ownerName,
      'filePath': filePath,
      'sizeBytes': sizeBytes,
      'qualityId': qualityId,
      'qualityLabel': qualityLabel,
      'durationMs': duration.inMilliseconds,
      'downloadedAt': downloadedAt.toIso8601String(),
      'status': status.name,
    };
  }

  /// 从本机 JSON 恢复离线视频记录；结构不合法时返回 null 交由上层丢弃。
  static OfflineVideoDownload? tryParse(Map<String, dynamic> json) {
    final String? bvid = json['bvid'];
    final String? filePath = json['filePath'];
    final String? title = json['title'];
    final String? ownerName = json['ownerName'];
    final DateTime? downloadedAt = DateTime.tryParse(
      json['downloadedAt']?.toString() ?? '',
    );
    final String normalizedBvid = bvid?.trim() ?? '';
    if (normalizedBvid.isEmpty ||
        (title?.trim().isEmpty ?? true) ||
        (ownerName?.trim().isEmpty ?? true) ||
        filePath == null ||
        filePath.isEmpty ||
        downloadedAt == null) {
      return null;
    }
    return OfflineVideoDownload(
      bvid: normalizedBvid,
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      title: title!.trim(),
      coverUrl: json['coverUrl']?.toString() ?? '',
      ownerName: ownerName!.trim(),
      filePath: filePath,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      qualityId: (json['qualityId'] as num?)?.toInt() ?? 32,
      qualityLabel: json['qualityLabel']?.toString() ?? '流畅 360P',
      duration: Duration(
        milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
      ),
      downloadedAt: downloadedAt,
      status: OfflineDownloadStatus.values.asNameMap()[
            json['status']?.toString()
          ] ??
          OfflineDownloadStatus.failed,
    );
  }
}
