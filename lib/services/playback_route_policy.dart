import '../models/playback_line_preference.dart';

/// 只调整已校验地址的顺序，不重写签名、域名或删除最后可用的线路。
abstract final class PlaybackRoutePolicy {
  /// 对单条编码轨道排序，先应用主备偏好，再稳定地优先非 PCDN / 镜像地址。
  static List<String> order(
    Iterable<String> urls, {
    PlaybackLinePreference preference = PlaybackLinePreference.smart,
    bool preferNonPcdn = true,
  }) {
    final unique = urls.toSet().toList();
    if (unique.isEmpty) return const [];
    final ordered = preference == PlaybackLinePreference.backup
        ? [...unique.skip(1), unique.first]
        : unique;
    final buckets = <int, List<String>>{};
    for (final url in ordered) {
      final pcdn = isPcdn(url);
      final rank =
          (preferNonPcdn && pcdn ? 2 : 0) +
          (preference == PlaybackLinePreference.smart && !isMirror(url)
              ? 1
              : 0);
      (buckets[rank] ??= []).add(url);
    }
    return List.unmodifiable([
      for (final rank in buckets.keys.toList()..sort()) ...buckets[rank]!,
    ]);
  }

  /// 结合域名、os 标记和特殊资源路径识别疑似 PCDN；不把教育网节点误判为 PCDN。
  static bool isPcdn(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.host.contains('.mcdn.bilivideo.') ||
        uri.host == 'szbdyd.com' ||
        uri.host.endsWith('.szbdyd.com') ||
        uri.queryParameters['os'] == 'mcdn' ||
        RegExp(r'^/v\d+/resource(?:/|$)').hasMatch(uri.path);
  }

  /// 识别接口已提供的镜像流；排除 302 调度和带 PCDN 标记的伪镜像。
  static bool isMirror(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        !isPcdn(url) &&
        uri.path.startsWith('/upgcxcode/') &&
        RegExp(
          r'^(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)$',
        ).hasMatch(uri.host);
  }
}
