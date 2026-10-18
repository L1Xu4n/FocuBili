import 'video_preview.dart';

/// Device-local exclusions, identified by stable video/creator IDs, never names.
class ContentBlocklist {
  const ContentBlocklist({this.videos = const {}, this.creators = const {}});

  /// BV IDs are case sensitive; values are labels for the management page.
  final Map<String, String> videos;
  final Map<int, String> creators;

  bool blocks({required String bvid, required int ownerMid}) =>
      videos.containsKey(bvid) ||
      (ownerMid > 0 && creators.containsKey(ownerMid));

  bool includes(VideoSearchResult result) =>
      !blocks(bvid: result.bvid, ownerMid: result.ownerMid);
}
