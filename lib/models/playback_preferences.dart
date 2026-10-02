/// 定义设置页可以选择的常用 B 站视频清晰度。
enum PreferredPlaybackQuality {
  p360(16, '流畅 360P'),
  p480(32, '清晰 480P'),
  p720(64, '高清 720P'),
  p1080(80, '高清 1080P'),
  p1080HighBitrate(112, '高清 1080P 高码率'),
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

/// 标识双击预览与真实播放器共用的三个动作。
enum DoubleTapAction { rewind, togglePlayback, forward }

/// 用画面比例保存触发区域，横竖屏和不同分辨率使用同一规则。
class DoubleTapRegions {
  /// 创建左右宽度与居中有效高度；默认沿用左右各 35% 的范围。
  const DoubleTapRegions({
    this.leftWidth = 0.35,
    this.rightWidth = 0.35,
    this.height = 1,
  });

  final double leftWidth;
  final double rightWidth;
  final double height;

  /// 限制非法比例，并为中间播放暂停区域至少保留 10% 宽度。
  static double normalize(
    double value,
    double minimum,
    double maximum,
    double fallback,
  ) => value.isFinite ? value.clamp(minimum, maximum).toDouble() : fallback;

  /// 返回校验后的区域配置，供编辑、保存和命中判断共用。
  DoubleTapRegions copyWith({
    double? leftWidth,
    double? rightWidth,
    double? height,
  }) => DoubleTapRegions(
    leftWidth: normalize(leftWidth ?? this.leftWidth, 0.1, 0.45, 0.35),
    rightWidth: normalize(rightWidth ?? this.rightWidth, 0.1, 0.45, 0.35),
    height: normalize(height ?? this.height, 0.4, 1, 1),
  );

  /// 解析本机配置；缺失字段和损坏数值使用默认区域。
  factory DoubleTapRegions.fromMap(Map<String, dynamic> map) =>
      DoubleTapRegions(
        leftWidth: (map['leftWidth'] as num?)?.toDouble() ?? 0.35,
        rightWidth: (map['rightWidth'] as num?)?.toDouble() ?? 0.35,
        height: (map['height'] as num?)?.toDouble() ?? 1,
      ).copyWith();

  /// 将三个比例一次保存，避免左右区域只写入一半。
  Map<String, double> toMap() => {
    'leftWidth': leftWidth,
    'rightWidth': rightWidth,
    'height': height,
  };

  /// 判断归一化落点的动作；左右区域之外都切换播放暂停。
  DoubleTapAction actionAt(double x, double y) {
    final regions = copyWith();
    final top = (1 - regions.height) / 2;
    if (y < top || y > 1 - top) return DoubleTapAction.togglePlayback;
    if (x < regions.leftWidth) return DoubleTapAction.rewind;
    if (x > 1 - regions.rightWidth) return DoubleTapAction.forward;
    return DoubleTapAction.togglePlayback;
  }
}

/// 保存播放器手势和按网络区分的默认清晰度配置。
class PlaybackPreferences {
  static const double defaultControlScale = 1;
  static const double minControlScale = 0.8;
  static const double maxControlScale = 2;

  /// 校验播放栏缩放比例，并按 5% 档位保存，异常值恢复 100%。
  static double normalizeControlScale(double value) => value.isFinite
      ? (value.clamp(minControlScale, maxControlScale) * 20).round() / 20
      : defaultControlScale;
  static const defaultSpeeds = <double>[0.75, 1, 1.25, 1.5, 2, 3];
  static const double defaultSubtitleFontSize = 16;
  static const double minSubtitleFontSize = 12;
  static const double maxSubtitleFontSize = 36;

  /// 将字幕字号限制在可读范围内，损坏或非有限值恢复原有的 16 号默认值。
  static double normalizeSubtitleFontSize(double value) => value.isFinite
      ? value.clamp(minSubtitleFontSize, maxSubtitleFontSize).roundToDouble()
      : defaultSubtitleFontSize;

  /// Filters corrupt stored rates, deduplicates and always retains normal speed.
  static List<double> normalizeSpeeds(Iterable<double> values) {
    final speeds = <double>{1};
    for (final value in values) {
      if (value.isFinite && value >= 0.5 && value <= 5) {
        speeds.add((value * 100).round() / 100);
      }
    }
    return List.unmodifiable(speeds.toList()..sort());
  }

  /// Formats rates without unnecessary trailing zeros, shared by settings/player.
  static String speedLabel(double speed) =>
      '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}x';

  /// 创建播放器偏好；旧用户继续默认启用双击，并以 720P 作为两种网络的安全默认值。
  const PlaybackPreferences({
    this.enableDoubleTapSeek = true,
    this.doubleTapRegions = const DoubleTapRegions(),
    this.showPlaybackActionAnimation = true,
    this.controlScale = defaultControlScale,
    this.enableTwoFingerVideoTransform = true,
    this.showNoteTimeMarkers = true,
    this.subtitleFontSize = defaultSubtitleFontSize,
    this.wifiDefaultQuality = PreferredPlaybackQuality.p720,
    this.mobileDefaultQuality = PreferredPlaybackQuality.p720,
    this.preferOfflineCache = false,
    this.playbackSpeeds = defaultSpeeds,
  });

  final bool enableDoubleTapSeek;
  final DoubleTapRegions doubleTapRegions;
  final bool showPlaybackActionAnimation;
  final double controlScale;
  final bool enableTwoFingerVideoTransform;
  final bool showNoteTimeMarkers;
  final double subtitleFontSize;
  final PreferredPlaybackQuality wifiDefaultQuality;
  final PreferredPlaybackQuality mobileDefaultQuality;
  final bool preferOfflineCache;
  final List<double> playbackSpeeds;

  /// 返回只替换指定字段的新配置，避免页面直接修改旧对象。
  PlaybackPreferences copyWith({
    bool? enableDoubleTapSeek,
    DoubleTapRegions? doubleTapRegions,
    bool? showPlaybackActionAnimation,
    double? controlScale,
    bool? enableTwoFingerVideoTransform,
    bool? showNoteTimeMarkers,
    double? subtitleFontSize,
    PreferredPlaybackQuality? wifiDefaultQuality,
    PreferredPlaybackQuality? mobileDefaultQuality,
    bool? preferOfflineCache,
    List<double>? playbackSpeeds,
  }) {
    return PlaybackPreferences(
      enableDoubleTapSeek: enableDoubleTapSeek ?? this.enableDoubleTapSeek,
      doubleTapRegions: doubleTapRegions?.copyWith() ?? this.doubleTapRegions,
      showPlaybackActionAnimation:
          showPlaybackActionAnimation ?? this.showPlaybackActionAnimation,
      controlScale: controlScale == null
          ? this.controlScale
          : normalizeControlScale(controlScale),
      showNoteTimeMarkers: showNoteTimeMarkers ?? this.showNoteTimeMarkers,
      subtitleFontSize: subtitleFontSize == null
          ? this.subtitleFontSize
          : normalizeSubtitleFontSize(subtitleFontSize),
      enableTwoFingerVideoTransform:
          enableTwoFingerVideoTransform ?? this.enableTwoFingerVideoTransform,
      wifiDefaultQuality: wifiDefaultQuality ?? this.wifiDefaultQuality,
      mobileDefaultQuality: mobileDefaultQuality ?? this.mobileDefaultQuality,
      preferOfflineCache: preferOfflineCache ?? this.preferOfflineCache,
      playbackSpeeds: playbackSpeeds == null
          ? this.playbackSpeeds
          : normalizeSpeeds(playbackSpeeds),
    );
  }
}
