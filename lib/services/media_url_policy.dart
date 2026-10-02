/// Limits remote media to HTTPS on known Bilibili CDN suffixes.
/// This is a trust allowlist, not a general-purpose DNS/SSRF validator.
abstract final class MediaUrlPolicy {
  /// Upgrades only standard-port known-CDN HTTP URLs; no plaintext transfer is allowed.
  static String? normalize(String value) {
    var uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.scheme == 'http' && uri.port == 80) {
      uri = uri.replace(scheme: 'https', port: 443);
    }
    return isSafe(uri.toString()) ? uri.toString() : null;
  }

  /// Rejects credentials, fragments, literal IPs and untrusted CDN hosts.
  static bool isSafe(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !uri.hasAuthority ||
        uri.port < 1 ||
        uri.port > 65535) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (!RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$').hasMatch(host)) return false;
    return const [
      'bilivideo.com',
      'bilivideo.cn',
    ].any((domain) => host == domain || host.endsWith('.$domain'));
  }
}
