import 'video_preview.dart';

/// Local content rules are separate from Bilibili's server-side search options.
class SearchContentFilter {
  /// New installs start unrestricted; previously saved choices remain effective.
  const SearchContentFilter({
    this.learningOnly = false,
    this.minimumPlayCount = 0,
    this.titleKeywords = const [],
    this.ownerKeywords = const [],
  });

  /// Validates a decoded settings value without reading or writing storage.
  ///
  /// Migration must reject unsupported fields and malformed terms rather than
  /// silently dropping them. Legacy values may omit both keyword lists.
  /// Invalid values throw [FormatException]; ordinary browsing stays tolerant.
  factory SearchContentFilter.fromJsonStrict(Object? value) {
    const fields = {
      'learningOnly',
      'minimumPlayCount',
      'titleKeywords',
      'ownerKeywords',
    };
    if (value is! Map || value.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Invalid search filter fields');
    }
    final learningOnly = value['learningOnly'];
    final minimumPlayCount = value['minimumPlayCount'];
    if (learningOnly is! bool ||
        minimumPlayCount is! int ||
        minimumPlayCount < 0 ||
        minimumPlayCount > maximumPlayCount) {
      throw const FormatException('Invalid search filter limits');
    }

    List<String> keywords(String key) {
      if (!value.containsKey(key)) return const [];
      final raw = value[key];
      if (raw is! List || raw.any((term) => term is! String)) {
        throw FormatException('Invalid search filter keywords: $key');
      }
      return parseKeywords(raw.cast<String>().join('\n'));
    }

    return SearchContentFilter(
      learningOnly: learningOnly,
      minimumPlayCount: minimumPlayCount,
      titleKeywords: keywords('titleKeywords'),
      ownerKeywords: keywords('ownerKeywords'),
    );
  }

  final bool learningOnly;
  final int minimumPlayCount;
  final List<String> titleKeywords;
  final List<String> ownerKeywords;
  static const maximumPlayCount = 2000000000;
  static final _learning = RegExp(
    r'教程|教学|课程|讲解|入门|科普|知识|学习|讲座|公开课|训练|练习|考研|高考|考证|编程|算法|数学|物理|化学|英语|语法|历史|地理|医学|实验|原理|解析|制作流程|绘画|乐理|技巧|how to|tutorial|lecture|course|lesson',
    caseSensitive: false,
  );
  static final _entertainment = RegExp(
    r'搞笑|整活|鬼畜|娱乐八卦|明星八卦|追星|综艺|游戏实况|游戏集锦|直播切片|纯享|萌宠|沙雕|名场面|二创|混剪|热舞|宅舞',
    caseSensitive: false,
  );

  /// Identifies probable non-learning content, preserving tutorials and unknowns.
  bool isProbablyUnrelated(VideoSearchResult result) {
    final text = '${result.title} ${result.tags.join(' ')}';
    if (_learning.hasMatch(text)) return false;
    // A category alone cannot tell whether a music/game video teaches a skill.
    return _entertainment.hasMatch(text);
  }

  /// Parses literal exclusion terms, preserving display case and ignoring duplicates.
  static List<String> parseKeywords(String text) {
    final seen = <String>{};
    return List.unmodifiable(
      text
          .split(RegExp(r'[\n\r,，;；]'))
          .map((term) => term.trim())
          .where((term) => term.isNotEmpty && seen.add(term.toLowerCase())),
    );
  }

  static bool _matches(String text, List<String> terms) {
    final lower = text.toLowerCase();
    return terms.any(
      (term) =>
          term.trim().isNotEmpty && lower.contains(term.trim().toLowerCase()),
    );
  }

  /// Applies learning, popularity and literal terms without mutating raw results.
  bool includes(VideoSearchResult result) =>
      (!learningOnly || !isProbablyUnrelated(result)) &&
      result.playCount >= minimumPlayCount &&
      !_matches(result.title, titleKeywords) &&
      !_matches(result.ownerName, ownerKeywords);

  /// Creates a changed immutable draft for filter sheets and persisted preferences.
  SearchContentFilter copyWith({
    bool? learningOnly,
    int? minimumPlayCount,
    List<String>? titleKeywords,
    List<String>? ownerKeywords,
  }) => SearchContentFilter(
    learningOnly: learningOnly ?? this.learningOnly,
    minimumPlayCount: minimumPlayCount ?? this.minimumPlayCount,
    titleKeywords: titleKeywords ?? this.titleKeywords,
    ownerKeywords: ownerKeywords ?? this.ownerKeywords,
  );
}
