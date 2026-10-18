/// 仅接受官方课堂 ss/ep 链接；课堂编号不会转成 AV/BV。
abstract final class BilibiliCourseLink {
  static final _keyPattern = RegExp(r'^cheese:ss([1-9][0-9]*)$');
  static final _pathPattern = RegExp(r'^/cheese/play/(ss|ep)([1-9][0-9]*)/?$');
  static const _hosts = {'www.bilibili.com', 'm.bilibili.com', 'bilibili.com'};

  static bool _validId(String? text) =>
      text != null && (int.tryParse(text) ?? 0) > 0;

  static bool isStorageKey(String value) {
    final match = _keyPattern.firstMatch(value);
    return match != null && _validId(match.group(1));
  }

  static Uri? fromStorageKey(String value) {
    final key = value.trim();
    if (!isStorageKey(key)) return null;
    return Uri.https('www.bilibili.com', '/cheese/play/ss${key.substring(9)}');
  }

  static Uri? parse(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !const {'https', 'http'}.contains(uri.scheme.toLowerCase()) ||
        !_hosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return null;
    }
    final match = _pathPattern.firstMatch(uri.path);
    if (match == null || !_validId(match.group(2))) return null;
    return Uri.https(
      'www.bilibili.com',
      '/cheese/play/${match.group(1)}${match.group(2)}',
    );
  }

  /// 接受分享文字，所有候选仍须通过官方域名和路径校验。
  static Uri? fromInput(String input) {
    final direct = parse(input) ?? fromStorageKey(input);
    if (direct != null) return direct;
    for (final match in RegExp(r'https?://[^\s<>"\u3000]+').allMatches(input)) {
      final text = match
          .group(0)!
          .replaceFirst(RegExp(r'[，。！？、；：）】》\)\],.!?;]+$'), '');
      final course = parse(text);
      if (course != null) return course;
    }
    return null;
  }
}
