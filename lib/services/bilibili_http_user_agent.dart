import '../models/video_preview.dart';

/// The setting is deliberately not a global HttpClient hook. Only these
/// first-party API routes, as requested by compatible call sites, adopt it.
abstract final class BilibiliHttpUserAgent {
  static const _metadataPaths = {
    '/x/web-interface/view',
    '/x/web-interface/wbi/view',
    '/x/tag/archive/tags',
    '/x/web-interface/wbi/search/type',
    '/x/player/pagelist',
  };
  static const _ordinaryPlaybackPaths = {
    '/x/player/playurl',
    '/x/player/wbi/playurl',
  };

  static bool _isHttpsEndpoint(Uri uri) =>
      uri.scheme == 'https' &&
      (!uri.hasPort || uri.port == 443) &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment;

  static bool allowsMetadata(Uri uri) =>
      _isHttpsEndpoint(uri) &&
      (uri.host == 'api.bilibili.com' && _metadataPaths.contains(uri.path) ||
          uri.host == 's.search.bilibili.com' && uri.path == '/main/suggest');

  static bool allowsPlayback(Uri uri) =>
      _isHttpsEndpoint(uri) &&
      uri.host == 'api.bilibili.com' &&
      _ordinaryPlaybackPaths.contains(uri.path);

  /// Only the tested ordinary resolution selection uses this compatibility
  /// header. An excluded quality is not necessarily paid or protected.
  static bool allowsPlaybackQuality(int quality) =>
      quality == 16 || quality == 32 || quality == 64;

  static bool isKnownOrdinaryUpload(VideoPreview video) =>
      video.isKnownUnrestrictedUpload &&
      !video.isCourse &&
      !video.fromOfflineCache;

  /// The public upload response must positively report the ordinary rights
  /// fields. Missing, contradictory, or unrecognized flags cannot enable
  /// an override for a playback request.
  static bool isUnrestrictedUploadResponse(Map<Object?, Object?> data) {
    final rights = data['rights'];
    if (rights is! Map) return false;

    bool off(Object? value) => value == 0 || value == false;
    for (final key in [
      'pay',
      'ugc_pay',
      'ugc_pay_preview',
      'arc_pay',
      'movie',
    ]) {
      if (!off(rights[key])) return false;
    }
    for (final key in ['is_upower_exclusive', 'is_upower_play']) {
      if (!off(data[key])) return false;
    }
    for (final key in [
      'is_drm',
      'drm',
      'drm_tech_type',
      'is_preview',
      'need_pay',
      'is_restricted',
      'is_chargeable_season',
      'season_id',
      'ep_id',
    ]) {
      if (data.containsKey(key) && !off(data[key]) ||
          rights.containsKey(key) && !off(rights[key])) {
        return false;
      }
    }
    final collection = data['ugc_season'];
    return collection == null ||
        (collection is Map && off(collection['is_pay_season']));
  }
}
