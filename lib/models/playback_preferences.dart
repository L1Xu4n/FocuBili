/// 定义设置页可以选择的常用 B 站视频清晰度。
enum PreferredPlaybackQuality {
  p360(16, '流畅 360P'),
  p480(32, '清晰 480P'),
  p720(64, '高清 720P'),
  p1080(80, '高清 1080P'),
  p1080HighFrameRate(116, '高清 1080P60'),
  p4k(120, '超清 4K');

  /// 创建一档可持久化的清晰度编号和中文名称。
  const PreferredPlaybackQuality(this.id, this.label);

  final int id;
  final String label;

  /// 从本机保存的编号恢复清晰度，未知旧值安全回退到 720P。
  static PreferredPlaybackQuality fromId(int? id) {
    return PreferredPlaybackQuality.values.firstWhere(
      (PreferredPlaybackQuality quality) => quality.id == id,
      orElse: () => PreferredPlaybackQuality.p720,
    );
  }
}

/// 从当前视频真实档位中选择不高于用户偏好和服务端实际档位的最高一档。
int selectPlaybackQualityAtOrBelow({
  required int preferredQuality,
  required int actualQuality,
  required Iterable<int> availableQualities,
}) {
  final int ceiling = preferredQuality < actualQuality
      ? preferredQuality
      : actualQuality;
  final List<int> candidates =
      availableQualities
          .where((int quality) => quality > 0 && quality <= ceiling)
          .toSet()
          .toList(growable: true)
        ..sort((int left, int right) => right.compareTo(left));
  return candidates.isEmpty ? actualQuality : candidates.first;
}

/// 保存播放器手势和按网络区分的默认清晰度配置。
class PlaybackPreferences {
  /// 创建播放器偏好；旧用户继续默认启用双击，并以 720P 作为两种网络的安全默认值。
  const PlaybackPreferences({
    this.enableDoubleTapSeek = true,
    this.wifiDefaultQuality = PreferredPlaybackQuality.p720,
    this.mobileDefaultQuality = PreferredPlaybackQuality.p720,
  });

  final bool enableDoubleTapSeek;
  final PreferredPlaybackQuality wifiDefaultQuality;
  final PreferredPlaybackQuality mobileDefaultQuality;

  /// 返回只替换指定字段的新配置，避免页面直接修改旧对象。
  PlaybackPreferences copyWith({
    bool? enableDoubleTapSeek,
    PreferredPlaybackQuality? wifiDefaultQuality,
    PreferredPlaybackQuality? mobileDefaultQuality,
  }) {
    return PlaybackPreferences(
      enableDoubleTapSeek: enableDoubleTapSeek ?? this.enableDoubleTapSeek,
      wifiDefaultQuality: wifiDefaultQuality ?? this.wifiDefaultQuality,
      mobileDefaultQuality: mobileDefaultQuality ?? this.mobileDefaultQuality,
    );
  }
}
