import 'dart:io';

import '../models/video_preview.dart';
import 'course_cache_library.dart';

/// Only the private library route can mint a grant for *one* checked lesson.
class CourseCachePlaybackGuard {
  CourseCachePlaybackGuard(this.library, this.entry);
  final CourseCacheLibrary library;
  final CourseCacheEntry entry;
  static bool _privatePath(String path) => path
      .replaceAll('\\', '/')
      .toLowerCase()
      .split('/')
      .contains('private_course_v1');

  /// Generic playback may never open a private media path, even via a link
  /// or when the caller omits or relabels its identity as an ordinary video.
  static Future<bool> isPrivateFile(File f) async =>
      _privatePath(f.absolute.path) ||
      _privatePath(await f.resolveSymbolicLinks());

  Future<CourseCacheEntry> validate(
    VideoPreview? v,
    VideoPart? p,
    String file,
    String? audio,
  ) async {
    if (v?.bvid != entry.video.bvid ||
        p?.cid != entry.cid ||
        p?.courseAid != entry.aid ||
        p?.courseEpisodeId != entry.ep) {
      throw const CourseCacheFailure('没有此章节的本机播放权限。');
    }
    final fresh = await library.open(entry);
    if (fresh.video != file || fresh.audio != audio) {
      throw const CourseCacheFailure('本地文件与已校验章节不符。');
    }
    return fresh.entry;
  }
}
