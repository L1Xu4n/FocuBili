import 'video_preview.dart';

/// All user-entered rules are single values, not regular expressions.
enum ContentBlockKind {
  creatorUid,
  creatorName,
  creatorKeyword,
  videoTag,
  videoTitleKeyword,
}

class ContentBlockRule {
  const ContentBlockRule(this.kind, this.value);

  final ContentBlockKind kind;
  final String value;
  static const maximumCharacters = 100;

  static final _digits = RegExp(r'^[0-9]+$');
  static final _controls = RegExp(r'[\u0000-\u001f\u007f]');

  static String normalizeText(String value) => value.trim().toLowerCase();

  /// Preserves the entered display spelling, while canonicalizing numeric IDs.
  ContentBlockRule validated() {
    final trimmed = value.trim();
    if (kind == ContentBlockKind.creatorUid) {
      final uid = _digits.hasMatch(trimmed) ? int.tryParse(trimmed) : null;
      if (uid == null || uid <= 0) {
        throw ArgumentError('请输入有效的正整数 UID。');
      }
      return ContentBlockRule(kind, uid.toString());
    }
    if (trimmed.isEmpty ||
        trimmed.runes.length > maximumCharacters ||
        _controls.hasMatch(trimmed)) {
      throw ArgumentError('请输入一条 1 到 $maximumCharacters 字的规则，不换行。');
    }
    return ContentBlockRule(kind, trimmed);
  }
}

/// Device-local exclusions. Labels accompanying stable IDs do not match names.
class ContentBlocklist {
  const ContentBlocklist({
    this.videos = const {},
    this.creators = const {},
    this.rules = const {},
  });

  /// BV IDs are case sensitive; values are labels for the management page.
  final Map<String, String> videos;
  final Map<int, String> creators;

  /// UID rules use [creators], preserving the existing stable-ID blocks.
  final Map<ContentBlockKind, List<String>> rules;

  bool get isNotEmpty =>
      videos.isNotEmpty ||
      creators.isNotEmpty ||
      rules.values.any((v) => v.isNotEmpty);

  bool get hasTagRules => rules[ContentBlockKind.videoTag]?.isNotEmpty ?? false;

  static bool _matches(
    String text,
    List<String>? values, {
    bool exact = false,
  }) {
    if (values == null || values.isEmpty) return false;
    final candidate = ContentBlockRule.normalizeText(text);
    if (candidate.isEmpty) return false;
    return values.any((value) {
      final normalized = ContentBlockRule.normalizeText(value);
      if (normalized.isEmpty) return false;
      return exact ? candidate == normalized : candidate.contains(normalized);
    });
  }

  bool blocksCreator({required int uid, String nickname = ''}) =>
      (uid > 0 && creators.containsKey(uid)) ||
      _matches(nickname, rules[ContentBlockKind.creatorName], exact: true) ||
      _matches(nickname, rules[ContentBlockKind.creatorKeyword]);

  bool blocks({
    required String bvid,
    required int ownerMid,
    String ownerName = '',
    String title = '',
    Iterable<String> tags = const [],
  }) {
    if (videos.containsKey(bvid) ||
        blocksCreator(uid: ownerMid, nickname: ownerName) ||
        _matches(title, rules[ContentBlockKind.videoTitleKeyword])) {
      return true;
    }
    final blockedTags = rules[ContentBlockKind.videoTag];
    return blockedTags != null &&
        blockedTags.isNotEmpty &&
        tags.any((tag) => _matches(tag, blockedTags, exact: true));
  }

  bool includes(
    VideoSearchResult result, {
    int? knownOwnerMid,
    Iterable<String> knownTags = const [],
  }) => !blocks(
    bvid: result.bvid,
    ownerMid: knownOwnerMid ?? result.ownerMid,
    ownerName: result.ownerName,
    title: result.title,
    tags: result.tags.followedBy(knownTags),
  );

  bool includesPreview(VideoPreview video) => !blocks(
    bvid: video.bvid,
    ownerMid: video.ownerMid,
    ownerName: video.ownerName,
    title: video.title,
    tags: video.tags,
  );
}
