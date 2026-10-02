import 'video_preview.dart';

/// Local content rules are separate from Bilibili's server-side search options.
class SearchContentFilter {
  /// Enables learning-oriented filtering by default without imposing popularity.
  const SearchContentFilter({
    this.learningOnly = true,
    this.minimumPlayCount = 0,
  });

  final bool learningOnly;
  final int minimumPlayCount;
  static const maximumPlayCount = 2000000000;
  static final _learning = RegExp(
    r'教程|教学|课程|讲解|入门|科普|知识|学习|讲座|公开课|训练|练习|考研|高考|考证|编程|算法|数学|物理|化学|英语|语法|历史|地理|医学|实验|原理|解析|制作流程|绘画|乐理|技巧|how to|tutorial|lecture|course|lesson',
    caseSensitive: false,
  );
  static final _entertainment = RegExp(
    r'搞笑|整活|鬼畜|娱乐八卦|明星八卦|追星|综艺|游戏实况|游戏集锦|直播切片|纯享|萌宠|沙雕|名场面|二创|混剪|热舞|宅舞',
    caseSensitive: false,
  );
  static const _entertainmentCategories = {
    1,
    13,
    168,
    3,
    129,
    4,
    119,
    5,
    181,
    23,
    11,
    17,
    65,
    66,
    127,
    171,
    172,
    22,
    26,
    126,
  };

  /// Identifies probable non-learning content, preserving tutorials and unknowns.
  bool isProbablyUnrelated(VideoSearchResult result) {
    final text = '${result.title} ${result.tags.join(' ')}';
    if (_learning.hasMatch(text)) return false;
    if (_entertainment.hasMatch(text)) return true;
    return _entertainmentCategories.contains(result.categoryId);
  }

  /// Applies independent learning and popularity rules without mutating raw results.
  bool includes(VideoSearchResult result) =>
      (!learningOnly || !isProbablyUnrelated(result)) &&
      result.playCount >= minimumPlayCount;

  /// Creates a changed immutable draft for filter sheets and persisted preferences.
  SearchContentFilter copyWith({bool? learningOnly, int? minimumPlayCount}) =>
      SearchContentFilter(
        learningOnly: learningOnly ?? this.learningOnly,
        minimumPlayCount: minimumPlayCount ?? this.minimumPlayCount,
      );
}
