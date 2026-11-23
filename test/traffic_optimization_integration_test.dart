import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/offline_download_task.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/bilibili_cookie_store.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/cached_player_overlay_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/device_status_service.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/media_cache_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/offline_download_queue.dart';
import 'package:focubili/services/offline_video_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/player_overlay_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'classroom_access_test.dart' show course;
import 'classroom_account_race_test.dart' show AccountRacePlayer;

class _MemoryCookieStore implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => '';

  @override
  Future<void> clearBilibiliCookies() async {}

  @override
  Future<void> replaceCookies(String cookieHeader) async {}
}

class _FixedDeviceStatusService implements DeviceStatusService {
  _FixedDeviceStatusService(this.status);

  DeviceNetworkStatus status;

  @override
  Future<int?> loadBatteryPercent() async => 80;

  @override
  Future<DeviceNetworkType> loadNetworkType() async => status.type;

  @override
  Future<DeviceNetworkStatus> loadNetworkStatus() async => status;
}

class _FakeAndroidMediaCacheService implements MediaCacheService {
  _FakeAndroidMediaCacheService({this.capacityBytes = defaultMediaCacheBytes});

  int capacityBytes;
  bool busy = false;
  int setCalls = 0;

  @override
  Future<MediaCacheStatus> loadStatus() async => MediaCacheStatus(
    usedBytes: 64 * 1024 * 1024,
    capacityBytes: capacityBytes,
    isPlaybackActive: busy,
    storageKind: MediaCacheStorageKind.androidPersistent,
  );

  @override
  Future<MediaCacheStatus> setCapacityBytes(int value) async {
    setCalls += 1;
    if (busy) {
      throw const MediaCacheException('cache_busy', '播放中暂不能管理缓存。');
    }
    capacityBytes = value;
    return loadStatus();
  }

  @override
  Future<MediaCacheStatus> clearCache() async => loadStatus();
}

const _sampleVideo = VideoPreview(
  bvid: 'BV1xx411c7mD',
  cid: 1001,
  title: '测试离线视频',
  ownerName: '测试 UP',
  ownerMid: 1,
  duration: Duration(minutes: 5),
  thumbnailUrl: '',
  parts: <VideoPart>[
    VideoPart(
      cid: 1001,
      pageNumber: 1,
      title: 'P1',
      duration: Duration(minutes: 5),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'offline download stops immediately on local FileSystemException without mirror retry or second playurl',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'focubili_offline_fs_test_',
      );
      addTearDown(() => root.delete(recursive: true));

      int playurlCalls = 0;
      int downloadAttempts = 0;
      final OfflineVideoService service = OfflineVideoService(
        directoryLoader: () async => root,
        cookieStore: _MemoryCookieStore(),
        requestText: (Uri uri, Map<String, String> headers) async {
          playurlCalls += 1;
          return jsonEncode(<String, Object?>{
            'code': 0,
            'data': <String, Object?>{
              'quality': 64,
              'accept_quality': <int>[64],
              'dash': <String, Object?>{
                'video': <Object?>[
                  <String, Object?>{
                    'id': 64,
                    'codecs': 'avc1.640028',
                    'bandwidth': 1000000,
                    'base_url': 'https://upos-a.bilivideo.com/v1.m4s',
                    'backup_url': <String>[
                      'https://upos-b.bilivideo.com/v1.m4s',
                    ],
                  },
                ],
                'audio': <Object?>[
                  <String, Object?>{
                    'id': 30280,
                    'codecs': 'mp4a.40.2',
                    'bandwidth': 128000,
                    'base_url': 'https://upos-a.bilivideo.com/a1.m4s',
                    'backup_url': <String>[
                      'https://upos-b.bilivideo.com/a1.m4s',
                    ],
                  },
                ],
              },
            },
          });
        },
        downloadFile: (Uri uri, Map<String, String> headers, File output, _) {
          downloadAttempts += 1;
          throw const FileSystemException('No space left on device');
        },
      );

      await expectLater(
        service.download(_sampleVideo, quality: 64),
        throwsA(
          isA<OfflineVideoException>().having(
            (OfflineVideoException e) => e.message,
            'message',
            contains('本地存储'),
          ),
        ),
      );
      expect(playurlCalls, 1);
      expect(downloadAttempts, 1);
    },
  );

  test(
    'OfflineDownloadQueue pauses task when wifiOnlyOfflineDownloads is enabled on metered or unknown network',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'focubili_queue_wifi_test_',
      );
      addTearDown(() => root.delete(recursive: true));

      int downloadCalls = 0;
      final OfflineVideoService library = OfflineVideoService(
        directoryLoader: () async => root,
        cookieStore: _MemoryCookieStore(),
        requestText: (Uri uri, Map<String, String> headers) async {
          downloadCalls += 1;
          throw StateError('Should not start network transfer');
        },
      );

      SharedPreferences.setMockInitialValues(<String, Object>{
        PlaybackPreferencesService.wifiOnlyOfflineDownloadsKey: true,
      });

      final _FixedDeviceStatusService network = _FixedDeviceStatusService(
        const DeviceNetworkStatus(
          type: DeviceNetworkType.mobile,
          metered: DeviceNetworkMeteredStatus.metered,
        ),
      );

      final OfflineDownloadQueue queue = OfflineDownloadQueue(
        library: library,
        deviceStatusService: network,
      );
      addTearDown(queue.dispose);

      await queue.initialize();
      await queue.enqueue(_sampleVideo, part: _sampleVideo.initialPart, quality: 64);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(downloadCalls, 0);
      expect(queue.tasks, hasLength(1));
      expect(queue.tasks.single.status, DownloadTaskStatus.paused);
      expect(queue.tasks.single.error, contains('仅未计量网络下载'));
    },
  );

  test(
    'SettingsTransferService supports codecPreference, wifiOnlyOfflineDownloads, and Android Media3 capacity symmetry with cache_busy rollback',
    () async {
      final Directory imageRoot = await Directory.systemTemp.createTemp(
        'focubili_settings_android_cache_',
      );
      addTearDown(() => imageRoot.delete(recursive: true));

      final ImageResourceCache imageCache = ImageResourceCache(
        directory: () async => Directory('${imageRoot.path}/focubili_images_v1'),
      );
      addTearDown(imageCache.dispose);

      final SubscriptionService subscriptions = SubscriptionService();
      final _FakeAndroidMediaCacheService mediaCache =
          _FakeAndroidMediaCacheService(capacityBytes: 1024 * 1024 * 1024);

      final SettingsTransferService transfer = SettingsTransferService(
        runtimeAdapter: DeviceSettingsRuntimeAdapter(
          subscriptions: subscriptions,
          imageCache: imageCache,
          mediaCache: mediaCache,
          appPlatform: AppPlatform.android,
        ),
      );

      await const PlaybackPreferencesService().saveCodecPreference(
        PlaybackCodecPreference.dataSaver,
      );
      await const PlaybackPreferencesService().saveWifiOnlyOfflineDownloads(
        true,
      );

      final String exported = await transfer.exportSettings();
      final Map<String, Object> parsed = transfer.parseSettings(exported);
      expect(
        parsed[PlaybackPreferencesService.codecPreferenceKey],
        PlaybackCodecPreference.dataSaver.name,
      );
      expect(
        parsed[PlaybackPreferencesService.wifiOnlyOfflineDownloadsKey],
        isTrue,
      );
      expect(
        parsed[DeviceSettingsRuntimeAdapter.androidMediaCapacityKey],
        1024 * 1024 * 1024,
      );
      expect(
        SettingsTransferService.isPortableZipKey(
          PlaybackPreferencesService.codecPreferenceKey,
        ),
        isTrue,
      );

      // Importing identical Android capacity skips setCapacityBytes even when busy.
      mediaCache.busy = true;
      await transfer.importSettings(<String, Object>{
        DeviceSettingsRuntimeAdapter.androidMediaCapacityKey:
            1024 * 1024 * 1024,
      });
      expect(mediaCache.setCalls, 0);

      // Importing a different capacity while busy fails and rolls back regular keys.
      await expectLater(
        transfer.importSettings(<String, Object>{
          PlaybackPreferencesService.codecPreferenceKey:
              PlaybackCodecPreference.compatible.name,
          DeviceSettingsRuntimeAdapter.androidMediaCapacityKey:
              256 * 1024 * 1024,
        }),
        throwsA(isA<StateError>()),
      );
      expect(mediaCache.setCalls, 1);
      final PlaybackPreferences afterRollback =
          await const PlaybackPreferencesService().load();
      expect(afterRollback.codecPreference, PlaybackCodecPreference.dataSaver);

      // When idle, resetSettings restores Android Media3 capacity to default 512 MiB.
      mediaCache.busy = false;
      await transfer.resetSettings();
      expect(mediaCache.capacityBytes, defaultMediaCacheBytes);
    },
  );

  test(
    'CachedPlayerOverlayService migrates same-documentId cues on refresh and caches danmaku segments with singleflight',
    () async {
      DateTime now = DateTime.utc(2026, 1, 1);
      final _FakeOverlayDelegate delegate = _FakeOverlayDelegate();
      final SubtitleMemoryCache subtitleCache = SubtitleMemoryCache();
      final CachedPlayerOverlayService service = CachedPlayerOverlayService(
        delegate,
        cache: subtitleCache,
        clock: () => now,
        danmakuCapacitySegments: 2,
      );
      addTearDown(() {
        service.dispose();
        subtitleCache.dispose();
      });

      // First track + cue load caches document v1.
      delegate.documentId = 'doc-v1';
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      final SubtitleCueLoadResult firstCues = await service.loadSubtitleCues(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        trackId: 'zh',
      );
      expect(firstCues.cues.single.content, 'cue-1');
      expect(delegate.cueLoads, 1);

      // Refreshing tracks with identical documentId preserves cached cues without refetch.
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      final SubtitleCueLoadResult reusedCues = await service.loadSubtitleCues(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        trackId: 'zh',
      );
      expect(reusedCues.cues.single.content, 'cue-1');
      expect(delegate.cueLoads, 1);

      // Refreshing tracks with a different documentId invalidates cached cues.
      delegate.documentId = 'doc-v2';
      await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 1);
      final SubtitleCueLoadResult refreshedCues = await service
          .loadSubtitleCues(bvid: 'BV1xx411c7mD', cid: 1, trackId: 'zh');
      expect(refreshedCues.cues.single.content, 'cue-2');
      expect(delegate.cueLoads, 2);

      // Concurrent danmaku reads coalesce via singleflight and hit LRU cache on repeat.
      final Completer<DanmakuSegmentLoadResult> gate =
          Completer<DanmakuSegmentLoadResult>();
      delegate.pendingDanmaku = gate.future;
      final Future<DanmakuSegmentLoadResult> d1 = service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 1,
      );
      final Future<DanmakuSegmentLoadResult> d2 = service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 1,
      );
      gate.complete(
        const DanmakuSegmentLoadResult(
          segmentIndex: 1,
          status: DanmakuLoadStatus.available,
          message: '',
          entries: <DanmakuEntry>[
            DanmakuEntry(
              position: Duration(seconds: 5),
              mode: 1,
              color: 0xFFFFFF,
              content: 'hello',
            ),
          ],
        ),
      );
      final List<DanmakuSegmentLoadResult> results = await Future.wait([
        d1,
        d2,
      ]);
      expect(results.first.entries.single.content, 'hello');
      expect(results.last.entries.single.content, 'hello');
      expect(delegate.danmakuLoads, 1);

      delegate.pendingDanmaku = null;
      await service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 1,
      );
      expect(delegate.danmakuLoads, 1);

      // Eviction at 2-segment capacity drops segment 1 after loading 2 and 3.
      await service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 2,
      );
      await service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 3,
      );
      expect(delegate.danmakuLoads, 3);
      await service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 1,
      );
      expect(delegate.danmakuLoads, 4);

      // Clearing subtitles/overlay cache evicts cached danmaku immediately.
      CacheLifecycle.clearSubtitles();
      await service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 1,
      );
      expect(delegate.danmakuLoads, 5);

      // TTL expiration (30 min) triggers fresh fetch.
      now = now.add(const Duration(minutes: 31));
      await service.loadDanmakuSegment(
        bvid: 'BV1xx411c7mD',
        cid: 1,
        segmentIndex: 1,
      );
      expect(delegate.danmakuLoads, 6);
    },
  );

  test(
    'OfflineDownloadQueue re-checks unmetered policy before mirror retry and pauses mid-transfer',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'focubili_queue_mid_switch_',
      );
      addTearDown(() => root.delete(recursive: true));

      final _FixedDeviceStatusService network = _FixedDeviceStatusService(
        const DeviceNetworkStatus(
          type: DeviceNetworkType.wifi,
          metered: DeviceNetworkMeteredStatus.unmetered,
        ),
      );
      final List<Uri> attemptedUrls = <Uri>[];
      final OfflineVideoService library = OfflineVideoService(
        directoryLoader: () async => root,
        cookieStore: _MemoryCookieStore(),
        requestText: (Uri uri, Map<String, String> headers) async =>
            jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'accept_quality': <int>[64],
                'dash': <String, Object?>{
                  'video': <Object?>[
                    <String, Object?>{
                      'id': 64,
                      'codecs': 'avc1.640028',
                      'bandwidth': 1000000,
                      'base_url': 'https://upos-a.bilivideo.com/v1.m4s',
                      'backup_url': <String>[
                        'https://upos-b.bilivideo.com/v1.m4s',
                      ],
                    },
                  ],
                  'audio': <Object?>[
                    <String, Object?>{
                      'id': 30280,
                      'codecs': 'mp4a.40.2',
                      'bandwidth': 128000,
                      'base_url': 'https://upos-a.bilivideo.com/a1.m4s',
                    },
                  ],
                },
              },
            }),
        downloadFile: (Uri uri, Map<String, String> headers, File output, _) {
          attemptedUrls.add(uri);
          // Simulate Wi-Fi dropping to cellular right when primary mirror fails.
          network.status = const DeviceNetworkStatus(
            type: DeviceNetworkType.mobile,
            metered: DeviceNetworkMeteredStatus.metered,
          );
          throw const SocketException('Wi-Fi disconnected');
        },
      );

      SharedPreferences.setMockInitialValues(<String, Object>{
        PlaybackPreferencesService.wifiOnlyOfflineDownloadsKey: true,
      });

      final OfflineDownloadQueue queue = OfflineDownloadQueue(
        library: library,
        deviceStatusService: network,
      );
      addTearDown(queue.dispose);

      await queue.initialize();
      await queue.enqueue(
        _sampleVideo,
        part: _sampleVideo.initialPart,
        quality: 64,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(attemptedUrls, hasLength(1));
      expect(attemptedUrls.single.host, 'upos-a.bilivideo.com');
      expect(queue.tasks.single.status, DownloadTaskStatus.paused);
      expect(queue.tasks.single.error, contains('仅未计量网络下载'));
    },
  );

  test(
    'WindowsPlaybackService never reuses online classroom sources and preserves account protection if a subsequent local open fails before stop',
    () async {
      final _CountingCourseSources sources = _CountingCourseSources();
      final AccountRacePlayer player = AccountRacePlayer();
      final WindowsPlaybackService service = WindowsPlaybackService(
        player: player,
        sourceService: sources,
      );
      addTearDown(service.dispose);

      await service.openVideo(course);
      expect(sources.courseLoads, 1);

      // P1-1: switching online classroom audio-only or quality must re-run loadCourse.
      await service.setAudioOnly(true);
      expect(sources.courseLoads, 2);
      await service.setAudioOnly(false);
      expect(sources.courseLoads, 3);
      await service.selectQuality(32);
      expect(sources.courseLoads, 4);

      // P1-2a: failed local UGC open before stop followed by selectQuality must keep classroom protection.
      await expectLater(
        service.openLocalFile(
          filePath: 'C:/nonexistent/focubili_missing_file_for_test.mp4',
          video: VideoPreview.placeholder(),
        ),
        throwsStateError,
      );
      await service.selectQuality(64);
      expect(sources.courseLoads, 5);
      final int stopsBeforeAccountChangeAfterSwitch = player.stops;
      CacheLifecycle.accountChanged();
      await Future<void>.delayed(Duration.zero);
      expect(player.stops, greaterThan(stopsBeforeAccountChangeAfterSwitch));
      expect(player.state.playing, isFalse);
      await expectLater(service.play(), throwsStateError);

      // P1-2b: failed local UGC open before stop followed immediately by account change also stops classroom.
      await service.openVideo(course);
      await expectLater(
        service.openLocalFile(
          filePath: 'C:/nonexistent/focubili_missing_file_for_test.mp4',
          video: VideoPreview.placeholder(),
        ),
        throwsStateError,
      );
      final int stopsBeforeAccountChange = player.stops;
      CacheLifecycle.accountChanged();
      await Future<void>.delayed(Duration.zero);
      expect(player.stops, greaterThan(stopsBeforeAccountChange));
      expect(player.state.playing, isFalse);
      await expectLater(service.play(), throwsStateError);
    },
  );
}

class _CountingCourseSources extends BilibiliDesktopPlaybackSourceService {
  int courseLoads = 0;

  @override
  Future<DesktopPlaybackSources> loadCourse({
    required VideoPreview video,
    required VideoPart part,
    required int quality,
  }) async {
    courseLoads += 1;
    return DesktopPlaybackSources(
      videoUrls: const <String>['https://synthetic.bilivideo.com/course-v.m4s'],
      audioUrls: const <String>['https://synthetic.bilivideo.com/course-a.m4s'],
      referer: 'https://www.bilibili.com/cheese/play/ep1',
      cookieHeader: '',
      actualQuality: quality,
      qualities: const <PlaybackQuality>[
        PlaybackQuality(id: 64, label: '720P'),
        PlaybackQuality(id: 32, label: '480P'),
      ],
      videoCodec: 'avc1',
      audioCodec: 'mp4a.40.2',
      returnedQuality: 64,
      videoAlternatives: const <DesktopVideoAlternative>[
        DesktopVideoAlternative(
          actualQuality: 64,
          codec: 'avc1',
          bandwidth: 1000000,
          urls: <String>['https://synthetic.bilivideo.com/course-v64.m4s'],
        ),
        DesktopVideoAlternative(
          actualQuality: 32,
          codec: 'avc1',
          bandwidth: 500000,
          urls: <String>['https://synthetic.bilivideo.com/course-v32.m4s'],
        ),
      ],
    );
  }
}

class _FakeOverlayDelegate implements PlayerOverlayService {
  String documentId = 'doc-v1';
  int cueLoads = 0;
  int danmakuLoads = 0;
  Future<DanmakuSegmentLoadResult>? pendingDanmaku;

  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async => SubtitleTrackLoadResult(
    status: SubtitleLoadStatus.available,
    message: '',
    tracks: <SubtitleTrack>[
      SubtitleTrack(
        id: 'zh',
        language: 'zh',
        label: '中文',
        isLocked: false,
        documentId: documentId,
      ),
    ],
  );

  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async {
    cueLoads += 1;
    return SubtitleCueLoadResult(
      status: SubtitleLoadStatus.available,
      message: '',
      cues: <SubtitleCue>[
        SubtitleCue(
          from: Duration.zero,
          to: const Duration(seconds: 5),
          content: 'cue-$cueLoads',
        ),
      ],
    );
  }

  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    danmakuLoads += 1;
    if (pendingDanmaku != null) return pendingDanmaku!;
    return DanmakuSegmentLoadResult(
      segmentIndex: segmentIndex,
      status: DanmakuLoadStatus.available,
      message: '',
      entries: <DanmakuEntry>[
        DanmakuEntry(
          position: Duration(seconds: segmentIndex),
          mode: 1,
          color: 0xFFFFFF,
          content: 'seg-$segmentIndex',
        ),
      ],
    );
  }
}
