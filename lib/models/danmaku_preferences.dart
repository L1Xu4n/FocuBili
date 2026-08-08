/// 保存用户级弹幕显示偏好；数值均会在构造时归一化，避免损坏的本地数据进入布局。
class DanmakuPreferences {
  /// 使用明确默认值创建配置，并限制透明度、区域、字号、轨道、时长和描边的安全范围。
  factory DanmakuPreferences({
    bool enabled = defaultEnabled,
    double opacity = defaultOpacity,
    double fontSize = defaultFontSize,
    int laneCount = defaultLaneCount,
    double scrollDurationSeconds = defaultScrollDurationSeconds,
    double displayArea = defaultDisplayArea,
    double strokeWidth = defaultStrokeWidth,
    bool showScrolling = true,
    bool showTop = true,
    bool showBottom = true,
    bool mergeRepeated = true,
    List<String> blockedKeywords = const <String>[],
  }) {
    return DanmakuPreferences._(
      enabled: enabled,
      opacity: _normalizeDouble(
        opacity,
        defaultOpacity,
        minOpacity,
        maxOpacity,
      ),
      fontSize: _normalizeDouble(
        fontSize,
        defaultFontSize,
        minFontSize,
        maxFontSize,
      ),
      laneCount: laneCount.clamp(minLaneCount, maxLaneCount).toInt(),
      scrollDurationSeconds: _normalizeDouble(
        scrollDurationSeconds,
        defaultScrollDurationSeconds,
        minScrollDurationSeconds,
        maxScrollDurationSeconds,
      ),
      displayArea: _normalizeDouble(
        displayArea,
        defaultDisplayArea,
        minDisplayArea,
        maxDisplayArea,
      ),
      strokeWidth: _normalizeDouble(
        strokeWidth,
        defaultStrokeWidth,
        minStrokeWidth,
        maxStrokeWidth,
      ),
      showScrolling: showScrolling,
      showTop: showTop,
      showBottom: showBottom,
      mergeRepeated: mergeRepeated,
      blockedKeywords: normalizeKeywords(blockedKeywords),
    );
  }

  /// 创建已经归一化的不可变配置，仅供公开工厂和复制函数使用。
  const DanmakuPreferences._({
    required this.enabled,
    required this.opacity,
    required this.fontSize,
    required this.laneCount,
    required this.scrollDurationSeconds,
    required this.displayArea,
    required this.strokeWidth,
    required this.showScrolling,
    required this.showTop,
    required this.showBottom,
    required this.mergeRepeated,
    required this.blockedKeywords,
  });

  static const bool defaultEnabled = false;
  static const double defaultOpacity = 0.9;
  static const double minOpacity = 0.2;
  static const double maxOpacity = 1;
  static const double defaultFontSize = 15;
  static const double minFontSize = 10;
  static const double maxFontSize = 30;
  static const int defaultLaneCount = 12;
  static const int minLaneCount = 1;
  static const int maxLaneCount = 24;
  static const double defaultScrollDurationSeconds = 9;
  static const double minScrollDurationSeconds = 3;
  static const double maxScrollDurationSeconds = 20;
  static const double defaultDisplayArea = 0.75;
  static const double minDisplayArea = 0.25;
  static const double maxDisplayArea = 1;
  static const double defaultStrokeWidth = 1.4;
  static const double minStrokeWidth = 0;
  static const double maxStrokeWidth = 3;

  final bool enabled;
  final double opacity;
  final double fontSize;
  final int laneCount;
  final double scrollDurationSeconds;
  final double displayArea;
  final double strokeWidth;
  final bool showScrolling;
  final bool showTop;
  final bool showBottom;
  final bool mergeRepeated;
  final List<String> blockedKeywords;

  /// 从持久化字典读取配置；旧版本缺失的新字段会采用兼容默认值。
  factory DanmakuPreferences.fromJson(Map<String, dynamic> json) {
    final Object? rawKeywords = json['blockedKeywords'];
    return DanmakuPreferences(
      enabled: json['enabled'] is bool
          ? json['enabled'] as bool
          : defaultEnabled,
      opacity: _readDouble(json['opacity'], defaultOpacity),
      fontSize: _readDouble(json['fontSize'], defaultFontSize),
      laneCount: _readInteger(json['laneCount'], defaultLaneCount),
      scrollDurationSeconds: _readDouble(
        json['scrollDurationSeconds'],
        defaultScrollDurationSeconds,
      ),
      displayArea: _readDouble(json['displayArea'], defaultDisplayArea),
      strokeWidth: _readDouble(json['strokeWidth'], defaultStrokeWidth),
      showScrolling: json['showScrolling'] is bool
          ? json['showScrolling'] as bool
          : true,
      showTop: json['showTop'] is bool ? json['showTop'] as bool : true,
      showBottom: json['showBottom'] is bool
          ? json['showBottom'] as bool
          : true,
      mergeRepeated: json['mergeRepeated'] is bool
          ? json['mergeRepeated'] as bool
          : true,
      blockedKeywords: rawKeywords is List
          ? rawKeywords.map((Object? item) => item?.toString() ?? '').toList()
          : const <String>[],
    );
  }

  /// 输出仅包含 JSON 基础类型的稳定字典，供 SharedPreferences 安全保存。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'opacity': opacity,
    'fontSize': fontSize,
    'laneCount': laneCount,
    'scrollDurationSeconds': scrollDurationSeconds,
    'displayArea': displayArea,
    'strokeWidth': strokeWidth,
    'showScrolling': showScrolling,
    'showTop': showTop,
    'showBottom': showBottom,
    'mergeRepeated': mergeRepeated,
    'blockedKeywords': blockedKeywords,
  };

  /// 复制部分字段并再次执行边界归一化，供设置界面即时生成安全配置。
  DanmakuPreferences copyWith({
    bool? enabled,
    double? opacity,
    double? fontSize,
    int? laneCount,
    double? scrollDurationSeconds,
    double? displayArea,
    double? strokeWidth,
    bool? showScrolling,
    bool? showTop,
    bool? showBottom,
    bool? mergeRepeated,
    List<String>? blockedKeywords,
  }) => DanmakuPreferences(
    enabled: enabled ?? this.enabled,
    opacity: opacity ?? this.opacity,
    fontSize: fontSize ?? this.fontSize,
    laneCount: laneCount ?? this.laneCount,
    scrollDurationSeconds: scrollDurationSeconds ?? this.scrollDurationSeconds,
    displayArea: displayArea ?? this.displayArea,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    showScrolling: showScrolling ?? this.showScrolling,
    showTop: showTop ?? this.showTop,
    showBottom: showBottom ?? this.showBottom,
    mergeRepeated: mergeRepeated ?? this.mergeRepeated,
    blockedKeywords: blockedKeywords ?? this.blockedKeywords,
  );

  /// 判断 B 站普通弹幕模式是否允许显示；高级模式在当前安全渲染器中明确忽略。
  bool allowsMode(int mode) {
    return switch (mode) {
      4 => showBottom,
      5 => showTop,
      1 || 2 || 3 || 6 => showScrolling,
      _ => false,
    };
  }

  /// 规范屏蔽词：去除首尾空格、忽略空项，并按小写结果去重。
  static List<String> normalizeKeywords(Iterable<String> keywords) {
    final Set<String> seen = <String>{};
    final List<String> result = <String>[];
    for (final String keyword in keywords) {
      final String trimmed = keyword.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed.toLowerCase())) {
        result.add(trimmed);
      }
    }
    return List<String>.unmodifiable(result);
  }

  /// 判断文本是否包含任一屏蔽词；匹配忽略大小写，空关键词永不匹配。
  bool blocks(String content) {
    final String normalizedContent = content.toLowerCase();
    return blockedKeywords.any(
      (String keyword) => normalizedContent.contains(keyword.toLowerCase()),
    );
  }

  /// 把 JSON 数字或数字字符串转成 double，无法解析时使用对应默认值。
  static double _readDouble(Object? value, double fallback) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? fallback;

  /// 把 JSON 整数或数字字符串转成 int，无法解析时使用对应默认值。
  static int _readInteger(Object? value, int fallback) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? fallback;

  /// 将浮点字段限制在闭区间内；NaN 和无穷值统一降级为字段默认值。
  static double _normalizeDouble(
    double value,
    double fallback,
    double minimum,
    double maximum,
  ) => value.isFinite ? value.clamp(minimum, maximum).toDouble() : fallback;
}
