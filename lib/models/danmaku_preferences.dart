/// 保存用户级弹幕显示偏好；数值均会在构造时归一化，避免损坏的本地数据进入布局。
class DanmakuPreferences {
  /// 使用明确默认值创建配置：默认关闭、90% 不透明度、15 逻辑像素字号、12 条轨道、9 秒滚动时长且不屏蔽文字。
  factory DanmakuPreferences({
    bool enabled = defaultEnabled,
    double opacity = defaultOpacity,
    double fontSize = defaultFontSize,
    int laneCount = defaultLaneCount,
    double scrollDurationSeconds = defaultScrollDurationSeconds,
    List<String> blockedKeywords = const <String>[],
  }) {
    return DanmakuPreferences._(
      enabled: enabled,
      opacity:
          _normalizeDouble(opacity, defaultOpacity, minOpacity, maxOpacity),
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

  final bool enabled;
  final double opacity;
  final double fontSize;
  final int laneCount;
  final double scrollDurationSeconds;
  final List<String> blockedKeywords;

  /// 从持久化字典读取配置；缺字段、错误类型和越界数字分别回退默认值或被合法范围截断，以兼容旧用户。
  factory DanmakuPreferences.fromJson(Map<String, dynamic> json) {
    final Object? rawKeywords = json['blockedKeywords'];
    return DanmakuPreferences(
      enabled:
          json['enabled'] is bool ? json['enabled'] as bool : defaultEnabled,
      opacity: _readDouble(json['opacity'], defaultOpacity),
      fontSize: _readDouble(json['fontSize'], defaultFontSize),
      laneCount: _readInteger(json['laneCount'], defaultLaneCount),
      scrollDurationSeconds: _readDouble(
        json['scrollDurationSeconds'],
        defaultScrollDurationSeconds,
      ),
      blockedKeywords: rawKeywords is List
          ? rawKeywords.map((Object? item) => item?.toString() ?? '').toList()
          : const <String>[],
    );
  }

  /// 输出仅包含 JSON 基础类型的稳定字典；滚动速度的单位是“完整穿屏所需视频秒数”。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'opacity': opacity,
        'fontSize': fontSize,
        'laneCount': laneCount,
        'scrollDurationSeconds': scrollDurationSeconds,
        'blockedKeywords': blockedKeywords,
      };

  /// 复制部分字段并再次执行边界归一化，供设置界面每次操作后立即生成安全配置。
  DanmakuPreferences copyWith({
    bool? enabled,
    double? opacity,
    double? fontSize,
    int? laneCount,
    double? scrollDurationSeconds,
    List<String>? blockedKeywords,
  }) =>
      DanmakuPreferences(
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        fontSize: fontSize ?? this.fontSize,
        laneCount: laneCount ?? this.laneCount,
        scrollDurationSeconds:
            scrollDurationSeconds ?? this.scrollDurationSeconds,
        blockedKeywords: blockedKeywords ?? this.blockedKeywords,
      );

  /// 规范屏蔽词：去除首尾空格、忽略空项，并按小写结果去重；保留首次输入的显示形式。
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

  /// 判断文本是否包含任一屏蔽词；匹配忽略大小写和关键词首尾空格，空关键词永不匹配。
  bool blocks(String content) {
    final String normalizedContent = content.toLowerCase();
    return blockedKeywords.any(
        (String keyword) => normalizedContent.contains(keyword.toLowerCase()));
  }

  /// 把 JSON 数字或数字字符串转成 double；无法解析时使用对应字段默认值，后续工厂还会检查有限值和范围。
  static double _readDouble(Object? value, double fallback) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? fallback;

  /// 把 JSON 整数或数字字符串转成 int；类型损坏时使用轨道数默认值，避免恢复阶段抛出格式异常。
  static int _readInteger(Object? value, int fallback) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? fallback;

  /// 将浮点字段限制在闭区间内；NaN 和无穷值不可用于 Slider 或绘制，统一降级为字段默认值。
  static double _normalizeDouble(
    double value,
    double fallback,
    double minimum,
    double maximum,
  ) =>
      value.isFinite ? value.clamp(minimum, maximum).toDouble() : fallback;
}
