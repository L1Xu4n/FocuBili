import 'dart:async';
import 'package:flutter/material.dart';

import '../../models/offline_video_download.dart';
import '../../platform/app_platform.dart';
import '../../services/cache_lifecycle.dart';
import '../../services/windows_playback_service.dart';
import '../../services/course_cache_playback_guard.dart';
import '../../services/course_cache_library.dart';
import '../../services/native_playback_service.dart';
import '../../services/offline_video_service.dart';
import '../player/player_page.dart';

/// Re-checks file ownership and the short-lived proof every time the existing
/// player resolves the local source. Never exposes a paid entry in the BV library.
class _OneChapter extends OfflineVideoService {
  _OneChapter(this.store, this.entry);
  final CourseCacheLibrary store;
  final CourseCacheEntry entry;
  @override
  Future<List<OfflineVideoDownload>> loadDownloads() async {
    final r = await store.open(entry);
    final e = r.entry;
    return [
      OfflineVideoDownload(
        bvid: e.video.bvid,
        cid: e.cid,
        title: e.chapterTitle,
        coverUrl: '',
        ownerName: 'B站课堂',
        filePath: r.video,
        audioFilePath: r.audio,
        qualityId: e.quality,
        qualityLabel: '本地',
        sizeBytes: e.videoBytes + e.audioBytes,
        audioSizeBytes: e.audioBytes,
        duration: e.duration,
        downloadedAt: e.checkedAt!,
        status: OfflineDownloadStatus.ready,
      ),
    ];
  }
}

class CourseCachePlaybackPage extends StatefulWidget {
  const CourseCachePlaybackPage({
    super.key,
    required this.library,
    required this.entry,
  });
  final CourseCacheLibrary library;
  final CourseCacheEntry entry;
  @override
  State<CourseCachePlaybackPage> createState() =>
      _CourseCachePlaybackPageState();
}

class _CourseCachePlaybackPageState extends State<CourseCachePlaybackPage>
    with WidgetsBindingObserver {
  late final _one = _OneChapter(widget.library, widget.entry);
  PlaybackService? _native;
  Timer? _timer;
  bool _invalid = false;
  int _seen = -1;
  void _libraryChanged() {
    if (_seen == widget.library.listVersion) return;
    _seen = widget.library.listVersion;
    unawaited(_check());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CacheLifecycle.account.addListener(_revoke);
    _seen = widget.library.listVersion;
    widget.library.addListener(_libraryChanged);
    final e = widget.entry;
    if (!e.usableAt(DateTime.now())) {
      _invalid = true;
      return;
    }
    if (AppPlatformDetector.current == AppPlatform.android) {
      _native = NativePlaybackService(
        courseCacheMid: e.mid,
        courseCacheUntil: e.until,
      );
    } else if (AppPlatformDetector.current == AppPlatform.windows) {
      _native = WindowsPlaybackService(
        courseCacheGuard: CourseCachePlaybackGuard(widget.library, e),
      );
    }
    _timer = Timer(e.until!.difference(DateTime.now()), _revoke);
  }

  void _revoke() {
    if (mounted && !_invalid) {
      _timer?.cancel();
      setState(() => _invalid = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_check());
    }
  }

  Future<void> _check() async {
    try {
      await widget.library.open(widget.entry);
    } catch (_) {
      _revoke();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    CacheLifecycle.account.removeListener(_revoke);
    widget.library.removeListener(_libraryChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _invalid
      ? Scaffold(
          appBar: AppBar(title: const Text('离线课堂')),
          body: const Center(child: Text('课程校验已到期或账号已变化，请返回课程缓存。')),
        )
      : PlayerPage(
          video: widget.entry.video,
          initialPartCid: widget.entry.cid,
          forceOffline: true,
          offlineVideoService: _one,
          playbackService: _native,
        );
}
