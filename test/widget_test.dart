import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/app.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/profile/login_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/device_status_service.dart';
import 'package:focubili/services/danmaku_preferences_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/player_overlay_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/search_history_service.dart';
import 'package:focubili/services/first_launch_service.dart';
import 'package:focubili/services/watch_history_service.dart';
import 'package:focubili/services/video_shot_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:focubili/models/player_overlay_data.dart';

/// 记录视频详情请求地址并返回固定 JSON，验证服务解析时不依赖真实网络。
class _RecordingJsonRequest {
  Uri? requestedUri;

  /// 保存服务请求的地址，并返回一份最小的公开视频详情响应。
  Future<String> call(Uri uri) async {
    requestedUri = uri;
    if (uri.path == '/x/tag/archive/tags') {
      return '''
        {
          "code": 0,
          "data": [
            {"tag_name": "地理"},
            {"tag_name": "科普"}
          ]
        }
      ''';
    }
    return '''
      {
        "code": 0,
        "message": "0",
        "data": {
          "aid": 116916878313252,
          "bvid": "BV1GJ411x7h7",
          "cid": 137649199,
          "title": "真实接口标题",
          "duration": 213,
          "desc": "这是一段@真实简介\\nhttps://example.com/course！",
          "desc_v2": [
            {"raw_text": "这是一段", "type": 2, "biz_id": 0},
            {"raw_text": "@真实简介", "type": 1, "biz_id": 778899},
            {"raw_text": "\\nhttps://example.com/course！", "type": 2, "biz_id": 0}
          ],
          "pubdate": 1704067200,
          "pic": "http://i0.hdslb.com/main.jpg",
          "owner": {
            "mid": 3546574294616231,
            "name": "真实接口 UP 主",
            "face": "//i0.hdslb.com/avatar.jpg"
          },
          "stat": {
            "view": 120000,
            "danmaku": 321,
            "reply": 45,
            "favorite": 67,
            "coin": 89,
            "share": 12,
            "like": 345
          },
          "pages": [
            {"page": 1, "cid": 137649199, "part": "第一P", "duration": 120},
            {"page": 2, "cid": 137649200, "part": "第二P", "duration": 93}
          ],
          "ugc_season": {
            "id": 9900,
            "title": "独立视频合集",
            "intro": "合集简介",
            "cover": "https://archive.biliimg.com/collection.jpg",
            "mid": 7788,
            "ep_count": 2,
            "sections": [
              {
                "episodes": [
                  {
                    "aid": 123456,
                    "bvid": "BV1GJ411x7h7",
                    "cid": 137649199,
                    "title": "合集第一支视频",
                    "arc": {
                      "pic": "http://i0.hdslb.com/one.jpg",
                      "duration": 213,
                      "pubdate": 1704067200,
                      "stat": {"view": 100, "danmaku": 10}
                    }
                  },
                  {
                    "aid": 654321,
                    "bvid": "BV1Q541167Qg",
                    "cid": 137649300,
                    "title": "合集第二支视频",
                    "arc": {
                      "pic": "http://i0.hdslb.com/two.jpg",
                      "duration": 300,
                      "stat": {"view": 200, "danmaku": 20}
                    }
                  }
                ]
              }
            ]
          }
        }
      }
    ''';
  }
}

/// 为合集切换测试返回第二支完整视频，其他能力保持空结果。
class _CollectionSwitchVideoService implements BilibiliService {
  int lookupRequests = 0;

  /// 返回合集中的第二支完整视频并记录查询次数。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookupRequests += 1;
    return _createSecondCollectionVideo();
  }

  /// 合集切换测试不使用关键词搜索，因此返回空页。
  @override
  Future<VideoSearchPage> searchVideos(
    String keyword, {
    int page = 1,
    VideoSearchFilter filter = const VideoSearchFilter(),
  }) async {
    return VideoSearchPage(
      results: const <VideoSearchResult>[],
      page: page,
      totalPages: page,
    );
  }

  /// 合集切换测试不使用搜索建议，因此返回空列表。
  @override
  Future<List<String>> suggestKeywords(String input) async {
    return const <String>[];
  }
}

/// 为横向拖动组件测试提供一张固定雪碧预览图。
class _FakeVideoShotService implements VideoShotService {
  int requests = 0;

  /// 返回包含两个时间点的固定截图元数据。
  @override
  Future<VideoShotPreview?> loadPreview({
    required String bvid,
    required int cid,
  }) async {
    requests += 1;
    return const VideoShotPreview(
      imageUrls: <String>['https://i0.hdslb.com/test-sprite.jpg'],
      sampleSeconds: <int>[0, 30],
      columns: 2,
      rows: 1,
      frameWidth: 160,
      frameHeight: 90,
    );
  }
}

/// 返回固定关键词搜索 JSON，验证真实搜索结果转换不依赖外网。
class _SearchJsonRequest {
  Uri? requestedUri;

  /// 保存搜索地址，并返回一条带 HTML 高亮标题的视频结果。
  Future<String> call(Uri uri) async {
    requestedUri = uri;
    return '''
      {
        "code": 0,
        "message": "OK",
        "data": {
          "page": 1,
          "numPages": 3,
          "result": [
            {
              "bvid": "BV1GJ411x7h7",
              "title": "学习<em class='keyword'>编程</em>",
              "author": "测试 UP 主",
              "duration": "1:02:03",
              "pic": "//i0.hdslb.com/test.jpg",
              "pubdate": 1704067200,
              "play": 120000,
              "danmaku": 321,
              "episode_count_text": "全12集"
            }
          ]
        }
      }
    ''';
  }
}

/// 返回固定搜索候选 JSON，验证输入建议解析时不依赖真实网络。
class _SuggestionJsonRequest {
  Uri? requestedUri;

  /// 保存候选词地址，并返回两条带重复项的建议用于验证去重。
  Future<String> call(Uri uri) async {
    requestedUri = uri;
    return '''
      {
        "result": {
          "tag": [
            {"value": "星球研究所"},
            {"value": "星球研究所视频"},
            {"value": "星球研究所"}
          ]
        }
      }
    ''';
  }
}

/// 提供无 Android 平台依赖的播放器替身，让组件测试只检查 Flutter 控制层交互。
class _FakePlaybackService implements PlaybackService {
  /// 创建用于播放器组件测试的无网络服务替身。
  _FakePlaybackService({
    this.savedState,
    this.rejectQuality = false,
    this.emitReadyOnOpen = true,
    this.duration = _defaultDuration,
  });

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  static const Duration _defaultDuration = Duration(minutes: 3, seconds: 32);
  final Duration duration;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  double _speed = 1;
  int _quality = 64;
  int? openedCid;
  int openVideoRequests = 0;
  final List<int> openedCids = <int>[];
  final List<int> openedQualities = <int>[];
  Completer<void>? retryOpenCompleter;
  final SavedPlaybackState? savedState;
  final bool rejectQuality;
  final bool emitReadyOnOpen;
  int pictureInPictureRequests = 0;
  int pauseRequests = 0;
  int seekByRequests = 0;
  int seekToRequests = 0;
  int frameCaptureRequests = 0;
  final List<Duration> frameCapturePositions = <Duration>[];
  final List<int?> frameCaptureCids = <int?>[];
  double brightness = 0.5;
  double volume = 0.5;

  /// 把假播放器状态提供给待测播放页面。
  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  /// 测试环境没有原生视频纹理，因此返回空编号并保留 Flutter 的黑色底图。
  @override
  Future<int?> initialize() async => null;

  /// 模拟打开视频完成，记录分P和清晰度，并在需要时等待测试控制的重试请求。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
  }) async {
    final VideoPart targetPart = part ?? video.initialPart;
    openVideoRequests += 1;
    openedCid = targetPart.cid;
    openedCids.add(targetPart.cid);
    openedQualities.add(quality);
    final Completer<void>? pendingRetry = retryOpenCompleter;
    if (openVideoRequests > 1 &&
        pendingRetry != null &&
        !pendingRetry.isCompleted) {
      await pendingRetry.future;
    }
    _quality = quality;
    if (emitReadyOnOpen) {
      _emit();
    }
  }

  /// 模拟原生播放器开始播放并推送新状态。
  @override
  Future<void> play() async {
    _isPlaying = true;
    _emit();
  }

  /// 模拟原生播放器暂停并推送新状态。
  @override
  Future<void> pause() async {
    pauseRequests += 1;
    _isPlaying = false;
    _emit();
  }

  /// 模拟按相对时长快进或快退，并把位置限制在视频有效范围内。
  @override
  Future<void> seekBy(Duration offset) async {
    seekByRequests += 1;
    final int nextMilliseconds =
        (_position.inMilliseconds + offset.inMilliseconds)
            .clamp(0, duration.inMilliseconds)
            .toInt();
    _position = Duration(milliseconds: nextMilliseconds);
    _emit();
  }

  /// 模拟跳转到给定位置，并把位置限制在视频有效范围内。
  @override
  Future<void> seekTo(Duration position) async {
    seekToRequests += 1;
    _position = Duration(
      milliseconds: position.inMilliseconds
          .clamp(0, duration.inMilliseconds)
          .toInt(),
    );
    _emit();
  }

  /// 模拟原生播放器切换倍速并推送新状态。
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    _speed = speed;
    _emit();
  }

  /// 模拟原生播放器切换清晰度并推送新状态。
  @override
  Future<void> selectQuality(int quality) async {
    _emit(phase: PlaybackPhase.loading, currentQuality: quality);
    if (!rejectQuality) {
      _quality = quality;
    }
    _emit();
  }

  /// 记录组件是否请求 Android 原生画中画，并在测试中直接返回成功。
  @override
  Future<bool> enterPictureInPicture(double aspectRatio) async {
    pictureInPictureRequests += 1;
    return true;
  }

  /// 记录截图时真实分P和播放位置，并返回测试用的固定本机路径。
  @override
  Future<String?> captureCurrentFrame() async {
    frameCaptureRequests += 1;
    frameCapturePositions.add(_position);
    frameCaptureCids.add(openedCid);
    return 'C:\\fake-video-note-frame.jpg';
  }

  /// 返回测试预先设置的最后观看分P和进度。
  @override
  Future<SavedPlaybackState?> loadSavedPlaybackState(String bvid) async {
    return savedState;
  }

  /// 返回固定亮度和音量，避免组件测试依赖 Android 系统服务。
  @override
  Future<SystemPlaybackLevels> getSystemPlaybackLevels() async {
    return SystemPlaybackLevels(brightness: brightness, volume: volume);
  }

  /// 记录播放器竖向手势设置的测试亮度。
  @override
  Future<void> setScreenBrightness(double value) async {
    brightness = value;
  }

  /// 记录播放器竖向手势设置的测试音量。
  @override
  Future<void> setMediaVolume(double value) async {
    volume = value;
  }

  /// 向测试页面广播指定阶段的假播放器状态，默认模拟可正常播放的就绪状态。
  void _emit({
    PlaybackPhase phase = PlaybackPhase.ready,
    String? message,
    int? currentQuality,
  }) {
    _states.add(
      PlaybackSnapshot(
        phase: phase,
        isPlaying: _isPlaying,
        position: _position,
        duration: duration,
        speed: _speed,
        currentQuality: currentQuality ?? _quality,
        availableQualities: const <PlaybackQuality>[
          PlaybackQuality(id: 64, label: '高清 720P'),
          PlaybackQuality(id: 32, label: '清晰 480P'),
        ],
        message: message,
      ),
    );
  }

  /// 向播放器页面推送一条错误快照，供重试按钮相关组件测试使用。
  void emitPlaybackError(String message) {
    _emit(phase: PlaybackPhase.error, message: message);
  }

  /// 向播放器页面推送加载快照，验证加载提示不会暴露可点击的重试入口。
  void emitLoading() {
    _emit(phase: PlaybackPhase.loading, message: '正在准备播放…');
  }

  /// 向播放器页面推送一次就绪快照，供观看记录只在真正可播放后写入的测试使用。
  void emitReady() {
    _emit();
  }

  /// 关闭测试使用的状态流，模拟页面离开时释放播放器。
  @override
  Future<void> dispose() => _states.close();
}

/// 记录播放器请求的观看历史，避免组件测试依赖 SharedPreferences 真正写入磁盘。
class _RecordingWatchHistoryService extends WatchHistoryService {
  /// 创建只把写入内容保存在内存中的观看记录服务替身。
  _RecordingWatchHistoryService();

  final List<WatchHistoryEntry> recordedEntries = <WatchHistoryEntry>[];

  /// 保存一份传入的记录副本，并返回当前测试可检查的内存记录列表。
  @override
  Future<List<WatchHistoryEntry>> record(WatchHistoryEntry entry) async {
    recordedEntries.add(entry);
    return List<WatchHistoryEntry>.unmodifiable(recordedEntries);
  }
}

/// 为全屏播放器测试提供稳定的电量读数，避免组件测试依赖真实 Android 电池。
class _FakeDeviceStatusService implements DeviceStatusService {
  /// 创建返回固定电量或未知状态的设备状态服务替身。
  const _FakeDeviceStatusService(this.batteryPercent);

  final int? batteryPercent;

  /// 返回构造时传入的电量百分比，不访问任何原生方法通道。
  @override
  Future<int?> loadBatteryPercent() async => batteryPercent;
}

/// 为播放器组件测试提供固定字幕轨道和条目，不访问 Android 通道或真实字幕地址。
class _FakePlayerOverlayService implements PlayerOverlayService {
  /// 创建可配置字幕元数据和字幕文字的本地服务替身。
  _FakePlayerOverlayService({
    required this.tracksResult,
    required this.cuesResult,
    this.danmakuResult = const DanmakuSegmentLoadResult.empty(),
  });

  final SubtitleTrackLoadResult tracksResult;
  final SubtitleCueLoadResult cuesResult;
  final DanmakuSegmentLoadResult danmakuResult;
  final List<int> danmakuSegmentRequests = <int>[];

  /// 返回测试配置的字幕轨道列表，不接触登录会话或网络。
  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async => tracksResult;

  /// 返回测试配置的字幕条目，不接触临时字幕地址或 Cookie。
  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async => cuesResult;

  /// 页面当前字幕测试不加载弹幕，因此返回空片段以满足叠加服务的完整接口。
  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    danmakuSegmentRequests.add(segmentIndex);
    return danmakuResult;
  }
}

/// 创建包含两个分P的固定视频，供播放器多P切换组件测试使用。
VideoPreview _createMultiPartVideo() {
  return const VideoPreview(
    bvid: 'BV1GJ411x7h7',
    cid: 137649199,
    title: '多P测试视频',
    ownerName: '焦点哔哩',
    duration: Duration(minutes: 2),
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 137649199,
        title: '第一P',
        duration: Duration(minutes: 2),
      ),
      VideoPart(
        pageNumber: 2,
        cid: 137649200,
        title: '第二P',
        duration: Duration(minutes: 3),
      ),
    ],
  );
}

/// 创建带超长分P标题的测试视频，验证折叠和展开选集不会产生布局异常。
VideoPreview _createLongPartTitleVideo() {
  return const VideoPreview(
    bvid: 'BV1GJ411x7h7',
    cid: 137649199,
    title: '超长分P标题测试视频',
    ownerName: '焦点哔哩',
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 137649199,
        title: '这一条非常非常长的分P标题用于验证在按钮内部超过两行后能够竖向循环显示并且不会造成布局溢出',
        duration: Duration(minutes: 2),
      ),
      VideoPart(
        pageNumber: 2,
        cid: 137649200,
        title: '短标题',
        duration: Duration(minutes: 3),
      ),
    ],
  );
}

/// 创建会触发全屏标题滚动分支的超长标题视频。
VideoPreview _createLongTitleVideo() {
  return const VideoPreview(
    bvid: 'BV1GJ411x7h7',
    cid: 137649199,
    title: 'J26最新版，包含所有干货！七天就能从小白到大神！少走99%的弯路！存下吧！很难找全的！',
    ownerName: '焦点哔哩',
    parts: <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 137649199,
        title: '超长标题测试',
        duration: Duration(minutes: 3),
      ),
    ],
  );
}

/// 创建同时具有两个分P和两支独立合集视频的测试详情，用于验证概念不会混淆。
VideoPreview _createCollectionVideo() {
  return VideoPreview(
    aid: 123456,
    bvid: 'BV1GJ411x7h7',
    cid: 137649199,
    title: '合集中的当前视频',
    ownerName: '合集UP主',
    ownerMid: 7,
    description: '这是一段视频简介。',
    stats: const VideoStats(
      viewCount: 120000,
      danmakuCount: 321,
      likeCount: 345,
      coinCount: 89,
      favoriteCount: 67,
      shareCount: 12,
    ),
    collection: VideoCollection(
      id: 900,
      title: '山河合集',
      ownerMid: 7,
      totalCount: 8,
      entries: <VideoCollectionEntry>[
        VideoCollectionEntry(
          bvid: 'BV1GJ411x7h7',
          cid: 137649199,
          title: '合集第一支视频',
          thumbnailUrl: '',
          duration: const Duration(minutes: 2),
          publishedAt: DateTime(2024, 1, 2),
        ),
        VideoCollectionEntry(
          bvid: 'BV1Q541167Qg',
          cid: 137649300,
          title: '合集第二支视频',
          thumbnailUrl: '',
          duration: const Duration(minutes: 3),
          publishedAt: DateTime(2024, 1, 3),
        ),
        ...List<VideoCollectionEntry>.generate(
          6,
          (int index) => VideoCollectionEntry(
            bvid: 'BV1TestLong${index + 3}',
            cid: 137649301 + index,
            title: '合集第${index + 3}支视频',
            thumbnailUrl: '',
            duration: Duration(minutes: index + 4),
            publishedAt: DateTime(2024, 1, index + 4),
          ),
        ),
      ],
    ),
    parts: <VideoPart>[
      const VideoPart(
        pageNumber: 1,
        cid: 137649199,
        title: '第一P',
        duration: Duration(minutes: 1),
      ),
      const VideoPart(
        pageNumber: 2,
        cid: 137649200,
        title: '第二P',
        duration: Duration(minutes: 1),
      ),
    ],
  );
}

/// 创建合集第二支完整视频，使页面可在同一播放器内切换并返回第一支。
VideoPreview _createSecondCollectionVideo() {
  final VideoCollection collection = _createCollectionVideo().collection!;
  return VideoPreview(
    aid: 654321,
    bvid: 'BV1Q541167Qg',
    cid: 137649300,
    title: '合集第二支完整视频',
    ownerName: '合集UP主',
    ownerMid: 7,
    collection: collection,
    duration: const Duration(minutes: 3),
    parts: const <VideoPart>[
      VideoPart(
        pageNumber: 1,
        cid: 137649300,
        title: '第二支视频第一P',
        duration: Duration(minutes: 3),
      ),
    ],
  );
}

/// 验证应用能够显示首页、搜索入口和底部一级导航。
void main() {
  /// 验证公开详情服务能解析 BV 号、大编号、UP 主、时长和多P列表。
  test('公开视频详情服务能解析 BV 链接和大编号', () async {
    final _RecordingJsonRequest requester = _RecordingJsonRequest();
    final BilibiliVideoInfoService service = BilibiliVideoInfoService(
      requestJson: requester.call,
    );

    final VideoPreview video = await service.lookupVideo(
      'https://www.bilibili.com/video/BV1GJ411x7h7/',
    );

    expect(requester.requestedUri?.host, 'api.bilibili.com');
    expect(requester.requestedUri?.queryParameters['bvid'], 'BV1GJ411x7h7');
    expect(video.cid, 137649199);
    expect(video.title, '真实接口标题');
    expect(video.ownerName, '真实接口 UP 主');
    expect(video.duration, const Duration(seconds: 120));
    expect(video.parts.length, 2);
    expect(video.parts.last.title, '第二P');
    expect(video.aid, 116916878313252);
    expect(video.ownerMid, 3546574294616231);
    expect(video.description, '这是一段@真实简介\nhttps://example.com/course！');
    expect(video.descriptionSegments, hasLength(5));
    expect(video.descriptionSegments[1].text, '@真实简介');
    expect(video.descriptionSegments[1].mentionedMid, 778899);
    expect(video.descriptionSegments[3].text, 'https://example.com/course');
    expect(video.descriptionSegments[3].linkUri?.host, 'example.com');
    expect(video.descriptionSegments.last.text, '！');
    expect(
      video.thumbnailUrl,
      'https://i0.hdslb.com/main.jpg@320w_200h_1c.webp',
    );
    expect(video.stats.viewCount, 120000);
    expect(video.collection?.title, '独立视频合集');
    expect(video.collection?.entries, hasLength(2));
    expect(video.collection?.entries.last.bvid, 'BV1Q541167Qg');
    expect(video.tags, <String>['地理', '科普']);
    expect(
      video.collection?.entries.last.thumbnailUrl,
      'https://i0.hdslb.com/two.jpg@320w_200h_1c.webp',
    );
  });

  /// 验证详情直达仍要求输入 BV 号，避免把关键词误当成视频编号。
  test('详情直达要求有效 BV 号', () async {
    final BilibiliVideoInfoService service = BilibiliVideoInfoService();

    await expectLater(
      service.lookupVideo('焦点哔哩'),
      throwsA(isA<BilibiliLookupException>()),
    );
  });

  /// 验证关键词搜索会请求视频搜索端点，并解析标题、时长和封面地址。
  test('关键词可以返回真实视频搜索结果', () async {
    final _SearchJsonRequest requester = _SearchJsonRequest();
    final BilibiliVideoInfoService service = BilibiliVideoInfoService(
      requestJson: requester.call,
    );

    final VideoSearchPage resultPage = await service.searchVideos('编程');
    final List<VideoSearchResult> results = resultPage.results;

    expect(requester.requestedUri?.path, '/x/web-interface/wbi/search/type');
    expect(requester.requestedUri?.queryParameters['keyword'], '编程');
    expect(results, hasLength(1));
    expect(results.single.title, '学习编程');
    expect(
      results.single.duration,
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );
    expect(
      results.single.thumbnailUrl,
      'https://i0.hdslb.com/test.jpg@320w_200h_1c.webp',
    );
    expect(results.single.playCount, 120000);
    expect(results.single.danmakuCount, 321);
    expect(results.single.episodeCountText, '全12集');
    expect(resultPage.totalPages, 3);
  });

  /// 验证下一页、排序、日期、时长和分区都会转换成真实搜索参数。
  test('关键词搜索支持分页和筛选参数', () async {
    final _SearchJsonRequest requester = _SearchJsonRequest();
    final BilibiliVideoInfoService service = BilibiliVideoInfoService(
      requestJson: requester.call,
    );

    final VideoSearchPage resultPage = await service.searchVideos(
      '星球研究所',
      page: 2,
      filter: const VideoSearchFilter(
        order: VideoSearchOrder.newest,
        publishedRange: VideoPublishedRange.lastWeek,
        durationRange: VideoDurationRange.tenToThirtyMinutes,
        categoryId: 36,
        categoryLabel: '知识',
      ),
    );

    final Map<String, String> query = requester.requestedUri!.queryParameters;
    expect(query['page'], '2');
    expect(query['order'], 'pubdate');
    expect(query['duration'], '2');
    expect(query['tids'], '36');
    expect(query['pubtime_begin_s'], isNotNull);
    expect(query['pubtime_end_s'], isNotNull);
    expect(resultPage.page, 2);
  });

  /// 验证搜索候选会读取 B 站建议接口并按原顺序删除重复文字。
  test('搜索输入可以返回候选词', () async {
    final _SuggestionJsonRequest requester = _SuggestionJsonRequest();
    final BilibiliVideoInfoService service = BilibiliVideoInfoService(
      requestJson: requester.call,
    );

    final List<String> suggestions = await service.suggestKeywords('星球');

    expect(requester.requestedUri?.host, 's.search.bilibili.com');
    expect(requester.requestedUri?.queryParameters['term'], '星球');
    expect(suggestions, <String>['星球研究所', '星球研究所视频']);
  });

  testWidgets('新框架首页可以正常启动', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      FirstLaunchService.agreementAcceptedKey: true,
      FirstLaunchService.loginGuideShownKey: true,
    });
    await tester.pumpWidget(const FocuBiliApp());
    await tester.pumpAndSettle();

    expect(find.text('焦点哔哩'), findsWidgets);
    expect(find.text('打开视频'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  /// 验证登录页默认选择手机号，并允许切换到不会明文展示内容的 Cookie 表单。
  testWidgets('登录页提供手机号密码和Cookie入口', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pumpAndSettle();

    expect(find.text('进入官方手机号登录'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('Cookie'), findsOneWidget);

    await tester.tap(find.text('Cookie'));
    await tester.pumpAndSettle();
    expect(find.text('使用 Cookie 登录'), findsOneWidget);
    expect(find.text('需要包含 SESSDATA'), findsOneWidget);
  });

  /// 验证播放器只在真实就绪后写一次历史，并在切换分P后的下一次就绪更新同一视频。
  testWidgets('播放器就绪后记录观看历史且分P切换后更新', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService playbackService = _FakePlaybackService(
      emitReadyOnOpen: false,
    );
    final _RecordingWatchHistoryService historyService =
        _RecordingWatchHistoryService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createMultiPartVideo(),
          playbackService: playbackService,
          watchHistoryService: historyService,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(historyService.recordedEntries, isEmpty);
    playbackService.emitLoading();
    playbackService.emitPlaybackError('网络暂时不可用');
    await tester.pump();
    await tester.pump();
    expect(historyService.recordedEntries, isEmpty);

    playbackService.emitReady();
    await tester.pump();
    await tester.pump();
    expect(historyService.recordedEntries, hasLength(1));
    expect(historyService.recordedEntries.single.lastPartPageNumber, 1);
    playbackService.emitReady();
    await tester.pump();
    expect(historyService.recordedEntries, hasLength(1));

    playbackService.emitPlaybackError('线路再次出错');
    playbackService.emitReady();
    await tester.pump();
    await tester.pump();
    expect(historyService.recordedEntries, hasLength(1));

    await tester.tap(find.byKey(const Key('part-2')));
    await tester.pump();
    await tester.pump();
    expect(historyService.recordedEntries, hasLength(1));
    playbackService.emitReady();
    await tester.pump();
    await tester.pump();
    expect(historyService.recordedEntries, hasLength(2));
    expect(historyService.recordedEntries.last.bvid, 'BV1GJ411x7h7');
    expect(historyService.recordedEntries.last.lastPartPageNumber, 2);
    playbackService.emitReady();
    await tester.pump();
    expect(historyService.recordedEntries, hasLength(2));
  });

  /// 验证画面空白处单击只隐藏控制层，不会触发中央播放按钮。
  testWidgets('播放器单击只切换控制层，不直接切换播放状态', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder controls = find.byKey(const Key('player-controls'));
    final Finder playerSurface = find.byKey(const Key('player-surface'));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);

    final Rect playerBounds = tester.getRect(playerSurface);
    await tester.tapAt(Offset(playerBounds.left + 12, playerBounds.center.dy));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
    expect(find.byTooltip('播放'), findsOneWidget);
  });

  /// 验证竖屏播放器右上角提供常用控制，并会随着详情页上滑连续收起至接近零高度。
  testWidgets('竖屏播放器显示右上角控制并随页面滚动收起', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(450, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder playerSurface = find.byKey(const Key('player-surface'));
    final Finder pageScroll = find.byKey(const Key('collapsing-player-scroll'));
    final double initialHeight = tester.getSize(playerSurface).height;
    expect(find.byKey(const Key('picture-in-picture')), findsOneWidget);
    expect(find.byKey(const Key('danmaku-toggle')), findsOneWidget);
    expect(find.byKey(const Key('more-settings-menu')), findsOneWidget);

    await tester.drag(pageScroll, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getSize(playerSurface).height, lessThan(initialHeight));

    await tester.drag(pageScroll, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(playerSurface, findsNothing);
    expect(tester.takeException(), isNull);
  });

  /// 验证画面右侧双击会触发五秒快进手势。
  testWidgets('播放器右侧双击会快进五秒', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final Offset rightTap = Offset(
      playerBounds.right - 12,
      playerBounds.center.dy,
    );
    await tester.tapAt(rightTap);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(rightTap);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('0:05 / 3:32'), findsOneWidget);
  });

  /// 验证倍速菜单能把用户选择传给原生播放器服务接口。
  testWidgets('播放器可以选择倍速', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final PopupMenuButton<double> speedMenu = tester.widget(
      find.byKey(const Key('speed-menu')),
    );
    speedMenu.onSelected!(1.5);
    await tester.pumpAndSettle();

    expect(service._speed, 1.5);
    speedMenu.onSelected!(3);
    await tester.pumpAndSettle();
    expect(service._speed, 3);
  });

  /// 验证清晰度菜单能把选中的质量编号传给原生播放器。
  testWidgets('播放器可以选择清晰度', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final PopupMenuButton<int> qualityMenu = tester.widget(
      find.byKey(const Key('quality-menu')),
    );
    qualityMenu.onSelected!(32);
    await tester.pumpAndSettle();

    expect(service._quality, 32);
    expect(find.byKey(const Key('player-floating-notice')), findsNothing);
  });

  /// 验证服务端回退到原画质时，页面明确提示大会员或账号权限原因。
  testWidgets('高画质切换失败会提示大会员权限', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService(
      rejectQuality: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final PopupMenuButton<int> qualityMenu = tester.widget(
      find.byKey(const Key('quality-menu')),
    );
    qualityMenu.onSelected!(32);
    await tester.pump();

    expect(find.textContaining('可能未开通大会员'), findsOneWidget);
    expect(find.byKey(const Key('player-floating-notice')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  /// 验证播放错误显示重试入口，重复点击只会发起一次请求且保留当前分P与清晰度。
  testWidgets('播放错误重试只请求一次并保留分P和清晰度', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createMultiPartVideo(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('part-2')));
    await tester.pumpAndSettle();
    final PopupMenuButton<int> qualityMenu = tester.widget(
      find.byKey(const Key('quality-menu')),
    );
    qualityMenu.onSelected!(32);
    await tester.pumpAndSettle();

    final int requestsBeforeRetry = service.openVideoRequests;
    final Completer<void> pendingRetry = Completer<void>();
    service.retryOpenCompleter = pendingRetry;
    service.emitPlaybackError('网络暂时不可用');
    await tester.pump();
    // 广播流会在下一轮事件循环通知页面，再额外绘制一帧以接收错误状态。
    await tester.pump();

    final Finder retryButton = find.byKey(const Key('retry-playback'));
    expect(find.byKey(const Key('playback-error')), findsOneWidget);
    expect(retryButton, findsOneWidget);
    expect(find.text('网络暂时不可用'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(retryButton).onPressed, isNotNull);

    await tester.tap(retryButton);
    await tester.pump();
    await tester.tap(retryButton);
    await tester.pump();

    expect(service.openVideoRequests, requestsBeforeRetry + 1);
    expect(service.openedCids.last, 137649200);
    expect(service.openedQualities.last, 32);
    expect(find.text('网络暂时不可用'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(retryButton).onPressed, isNull);

    pendingRetry.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('retry-playback')), findsNothing);
  });

  /// 验证加载提示不提供重试按钮，避免未结束的加载请求被重复发起。
  testWidgets('播放加载时不显示可点击重试按钮', (WidgetTester tester) async {
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    service.emitLoading();
    await tester.pump();
    // 同上：等待异步状态流被播放器页面写入 State。
    await tester.pump();

    expect(find.text('正在准备播放…'), findsOneWidget);
    expect(find.byKey(const Key('retry-playback')), findsNothing);
  });

  /// 验证播放器下方的两行选集能切换到第二P的 cid。
  testWidgets('播放器可以切换多P', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createMultiPartVideo(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('part-selector-button')), findsNothing);
    expect(find.byKey(const Key('previous-part-button')), findsOneWidget);
    expect(find.byKey(const Key('next-part-button')), findsOneWidget);
    expect(
      find.byKey(const Key('detail-part-selector-expand')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('part-2')));
    await tester.pumpAndSettle();

    expect(service.openedCid, 137649200);
  });

  /// 验证首页创建的任务只在用户确认关联且当前分P实际播放后开始计时。
  testWidgets('播放器确认关联首页专注并跟随真实播放状态', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '关联当前课程',
      duration: const Duration(minutes: 25),
      startImmediately: false,
    );
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createMultiPartVideo(),
          playbackService: service,
          focusTimerController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('是否将“关联当前课程”关联'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-focus-video-association')));
    await tester.pumpAndSettle();
    expect(controller.activeSession?.sourceBvid, _createMultiPartVideo().bvid);
    expect(controller.activeSession?.status, FocusSessionStatus.paused);
    expect(find.textContaining('已关联视频：'), findsOneWidget);

    await service.play();
    await tester.pump();
    expect(controller.activeSession?.status, FocusSessionStatus.running);
  });

  /// 验证全屏底栏选集会打开右侧双列面板，并能从面板切换分P。
  testWidgets('全屏选集从右侧展开并切换分P', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createMultiPartVideo(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pumpAndSettle();
    final Rect partSelectorRect = tester.getRect(
      find.byKey(const Key('part-selector-button')),
    );
    final Rect qualityMenuRect = tester.getRect(
      find.byKey(const Key('quality-menu')),
    );
    expect(
      (partSelectorRect.center.dy - qualityMenuRect.center.dy).abs(),
      lessThan(1),
    );
    tester
        .widget<InkWell>(find.byKey(const Key('part-selector-button')))
        .onTap!();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fullscreen-part-selector')), findsOneWidget);
    await tester.tap(find.byKey(const Key('part-2')));
    await tester.pumpAndSettle();
    expect(service.openedCid, 137649200);
    expect(find.byKey(const Key('fullscreen-part-selector')), findsNothing);
  });

  /// 验证播放器日期包含时间、长简介收起时省略，并能长按复制 BV 号。
  testWidgets('视频信息显示时间省略长简介并复制BV', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final String description = List<String>.filled(40, '这是一段很长的简介').join();
    final VideoPreview video = VideoPreview(
      aid: 123,
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      title: '详情交互测试',
      ownerName: '测试UP',
      description: description,
      publishedAt: DateTime(2024, 1, 2, 3, 4),
      parts: const <VideoPart>[
        VideoPart(
          pageNumber: 1,
          cid: 137649199,
          title: '第一P',
          duration: Duration(minutes: 1),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(video: video, playbackService: _FakePlaybackService()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2024-01-02 03:04'), findsOneWidget);
    final Text descriptionText = tester.widget<Text>(
      find.byKey(const Key('video-description')),
    );
    expect(descriptionText.maxLines, 3);
    expect(descriptionText.overflow, TextOverflow.ellipsis);
    expect(find.text('展开'), findsOneWidget);
    await tester.longPress(find.byKey(const Key('copy-bvid')));
    await tester.pump();
    expect(copiedText, 'BV1GJ411x7h7');
    expect(find.text('已复制 BV1GJ411x7h7'), findsOneWidget);
  });

  /// 验证结构化简介把 @UP 和链接标蓝，且外链必须确认风险后才交给默认浏览器启动器。
  testWidgets('视频简介提及可点击且外链先确认风险', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final Uri externalUri = Uri.parse('https://example.com/course');
    Uri? launchedUri;
    final VideoPreview video = VideoPreview(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      title: '结构化简介测试',
      ownerName: '测试UP',
      description: '欢迎@课程老师，资料：https://example.com/course',
      descriptionSegments: <VideoDescriptionSegment>[
        const VideoDescriptionSegment(text: '欢迎'),
        const VideoDescriptionSegment(text: '@课程老师', mentionedMid: 778899),
        const VideoDescriptionSegment(text: '，资料：'),
        VideoDescriptionSegment(
          text: externalUri.toString(),
          linkUri: externalUri,
        ),
      ],
      parts: const <VideoPart>[
        VideoPart(
          pageNumber: 1,
          cid: 137649199,
          title: '第一P',
          duration: Duration(minutes: 1),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: _FakePlaybackService(),
          externalLinkLauncher: (Uri uri) async {
            launchedUri = uri;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder mention = find.byKey(const Key('description-mention-778899'));
    final Finder link = find.byKey(Key('description-link-$externalUri'));
    expect(mention, findsOneWidget);
    expect(link, findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.descendant(of: mention, matching: find.byType(Text)),
          )
          .style
          ?.color,
      isNotNull,
    );
    expect(
      tester
          .widget<Text>(find.descendant(of: link, matching: find.byType(Text)))
          .style
          ?.decoration,
      TextDecoration.underline,
    );

    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('即将打开外部链接'), findsOneWidget);
    expect(find.textContaining('内容和安全性'), findsOneWidget);
    expect(launchedUri, isNull);
    await tester.tap(find.byKey(const Key('cancel-external-link')));
    await tester.pumpAndSettle();
    expect(launchedUri, isNull);

    await tester.tap(link);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-external-link')));
    await tester.pumpAndSettle();
    expect(launchedUri, externalUri);
  });

  /// 验证播放页把单视频分P和多视频 UGC 合集放在不同区域，且不提供评论或发弹幕入口。
  testWidgets('播放页区分分P和UGC合集', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService playbackService = _FakePlaybackService();

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: playbackService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('简介'), findsOneWidget);
    expect(find.byKey(const Key('part-selector-button')), findsNothing);
    expect(
      find.byKey(const Key('detail-part-selector-expand')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('video-collection-card')), findsOneWidget);
    final ListView collectionPreviewList = tester.widget<ListView>(
      find.byKey(const Key('collection-preview-list')),
    );
    expect(collectionPreviewList.scrollDirection, Axis.horizontal);
    expect(find.text('2024-01-02'), findsOneWidget);
    expect(
      find.byKey(const Key('collection-title-BV1GJ411x7h7')),
      findsOneWidget,
    );
    expect(find.textContaining('合集 · 山河合集'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('collection-preview-list')),
      const Offset(-2400, 0),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('collection-preview-BV1TestLong8')),
      findsOneWidget,
    );
    expect(find.text('评论'), findsNothing);
    expect(find.text('发弹幕'), findsNothing);
  });

  /// 验证合集展开面板可以搜索、排序，并一键回到当前播放视频。
  testWidgets('合集展开面板支持搜索排序和定位', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('video-collection-card')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('collection-search-field')), findsOneWidget);
    expect(find.byKey(const Key('collection-sort-button')), findsOneWidget);
    expect(find.byKey(const Key('collection-locate-current')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('collection-search-field')),
      '第8支',
    );
    await tester.pumpAndSettle();
    final Finder sheetList = find.byKey(const Key('collection-sheet-list'));
    expect(
      find.descendant(of: sheetList, matching: find.text('合集第8支视频')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheetList, matching: find.text('合集第二支视频')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('collection-locate-current')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: sheetList, matching: find.text('合集第一支视频')),
      findsOneWidget,
    );
  });

  /// 验证竖屏笔记面板固定播放器，并保存标题、正文、时间点和可选当前画面。
  testWidgets('竖屏时间点笔记固定播放器并保存到本机', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final VideoNoteService noteService = VideoNoteService(
      preferencesLoader: () async => preferences,
    );
    final _FakePlaybackService playbackService = _FakePlaybackService();
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: playbackService,
          videoNoteService: noteService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('portrait-note-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('portrait-video-notes-panel')), findsOneWidget);
    expect(find.byKey(const Key('collapsing-player-scroll')), findsNothing);
    final TextField portraitTitleField = tester.widget<TextField>(
      find.byKey(const Key('note-title-field')),
    );
    expect(portraitTitleField.decoration?.border, InputBorder.none);
    final GestureDetector activePlayerSurface = tester.widget<GestureDetector>(
      find.byKey(const Key('player-surface')),
    );
    expect(activePlayerSurface.onTap, isNotNull);
    final IconButton activePlayButton = tester.widget<IconButton>(
      find.byKey(const Key('play-pause-button')),
    );
    expect(activePlayButton.onPressed, isNotNull);
    activePlayButton.onPressed!();
    await tester.pump();
    expect(playbackService._isPlaying, isTrue);
    final Rect playerBeforeDrag = tester.getRect(
      find.byKey(const Key('player-surface')),
    );

    await tester.drag(
      find.byKey(const Key('portrait-video-notes-panel')),
      const Offset(0, -500),
    );
    await tester.pump();
    final Rect playerAfterDrag = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    expect(playerAfterDrag, playerBeforeDrag);

    await tester.enterText(find.byKey(const Key('note-title-field')), '关键观点');
    await tester.enterText(find.byKey(const Key('note-body-field')), '这是正文内容。');
    // 模拟写笔记期间视频继续播放，截图仍应回到新建笔记时锁定的 00:00。
    await playbackService.seekTo(const Duration(seconds: 75));
    await tester.pump();
    await tester.tap(find.byKey(const Key('include-current-frame')));
    await tester.tap(find.byKey(const Key('save-video-note')));
    await tester.pumpAndSettle();

    final List<VideoNote> notes = await noteService.loadNotes();
    expect(notes, hasLength(1));
    expect(notes.single.title, '关键观点');
    expect(notes.single.body, '这是正文内容。');
    expect(notes.single.framePath, 'C:\\fake-video-note-frame.jpg');
    expect(playbackService.frameCaptureRequests, 1);
    expect(playbackService.frameCapturePositions, <Duration>[Duration.zero]);
    expect(playbackService.frameCaptureCids, <int?>[137649199]);
    expect(playbackService._position, const Duration(seconds: 75));
    expect(playbackService._isPlaying, isTrue);

    await tester.tap(find.byKey(const Key('delete-video-note')));
    await tester.pumpAndSettle();
    expect(find.text('确定删除“关键观点”吗？此操作无法撤销。'), findsOneWidget);
    expect(await noteService.loadNotes(), hasLength(1));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await noteService.loadNotes(), hasLength(1));
  });

  /// 验证全屏右侧笔记按钮打开半透明笔记本，并能从左侧列表跳转时间点。
  testWidgets('全屏时间点笔记显示半透明列表并跳转进度', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final VideoNoteService noteService = VideoNoteService(
      preferencesLoader: () async => preferences,
    );
    final DateTime now = DateTime(2026, 7, 15, 19, 1);
    await noteService.saveNote(
      VideoNote(
        id: 'fullscreen-note',
        bvid: 'BV1GJ411x7h7',
        videoTitle: '合集中的当前视频',
        ownerName: '合集UP主',
        partCid: 137649199,
        partPageNumber: 1,
        partTitle: '第一P',
        title: '这是一条很长很长需要自动滚动显示的笔记标题',
        body: '全屏笔记正文',
        createdAt: now,
        updatedAt: now,
        position: const Duration(seconds: 42),
      ),
    );
    final _FakePlaybackService playbackService = _FakePlaybackService();
    await tester.binding.setSurfaceSize(const Size(920, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: playbackService,
          videoNoteService: noteService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.binding.setSurfaceSize(const Size(2000, 920));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('fullscreen-note-button')), findsOneWidget);
    final GestureDetector fullscreenSurface = tester.widget<GestureDetector>(
      find.byKey(const Key('player-surface')),
    );
    fullscreenSurface.onTap!();
    await tester.pump();
    expect(find.byKey(const Key('fullscreen-note-button')), findsNothing);
    tester
        .widget<GestureDetector>(find.byKey(const Key('player-surface')))
        .onTap!();
    await tester.pump();
    expect(find.byKey(const Key('fullscreen-note-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('fullscreen-note-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('fullscreen-video-notes-panel')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fullscreen-video-note-list')), findsOneWidget);
    final Material panelMaterial = tester.widget<Material>(
      find.byKey(const Key('fullscreen-video-notes-material')),
    );
    expect(panelMaterial.color!.a, lessThan(1.0));
    final AnimatedSlide openedPanelSlide = tester.widget<AnimatedSlide>(
      find.byKey(const Key('fullscreen-video-notes-slide')),
    );
    expect(openedPanelSlide.offset, Offset.zero);
    expect(openedPanelSlide.duration, const Duration(milliseconds: 280));
    final double compactHeaderTop = tester
        .getTopLeft(find.byKey(const Key('compact-note-header')))
        .dy;
    final double panelTop = tester
        .getTopLeft(find.byKey(const Key('fullscreen-video-notes-material')))
        .dy;
    expect(compactHeaderTop - panelTop, lessThan(14));
    final TextField fullscreenTitleField = tester.widget<TextField>(
      find.byKey(const Key('note-title-field')),
    );
    expect(fullscreenTitleField.decoration?.border, InputBorder.none);
    expect(fullscreenTitleField.decoration?.filled, isFalse);
    expect(fullscreenTitleField.style?.fontWeight, FontWeight.w900);
    final TextField fullscreenBodyField = tester.widget<TextField>(
      find.byKey(const Key('note-body-field')),
    );
    expect(fullscreenBodyField.decoration?.border, InputBorder.none);
    expect(fullscreenBodyField.decoration?.filled, isFalse);

    tester
        .widget<IconButton>(
          find.byKey(const Key('collapse-fullscreen-note-list')),
        )
        .onPressed!();
    await tester.pump();
    expect(find.byKey(const Key('fullscreen-video-note-list')), findsNothing);
    expect(
      find.byKey(const Key('expand-fullscreen-note-list')),
      findsOneWidget,
    );
    tester
        .widget<IconButton>(
          find.byKey(const Key('expand-fullscreen-note-list')),
        )
        .onPressed!();
    await tester.pump();
    expect(find.byKey(const Key('fullscreen-video-note-list')), findsOneWidget);

    final InkWell noteEntry = tester.widget<InkWell>(
      find.byKey(const Key('fullscreen-video-note-fullscreen-note')),
    );
    noteEntry.onTap!();
    await tester.pump();
    expect(playbackService.seekToRequests, 1);
    expect(find.text('视频位置：00:42'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const Key('fullscreen-video-notes-panel')),
      findsOneWidget,
    );
    final AnimatedSlide closingPanelSlide = tester.widget<AnimatedSlide>(
      find.byKey(const Key('fullscreen-video-notes-slide')),
    );
    expect(closingPanelSlide.offset.dx, greaterThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('fullscreen-video-notes-panel')), findsNothing);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
  });

  /// 验证从笔记详情进入播放器时，外部指定分P和时间点优先于本机观看记录。
  testWidgets('播放器优先打开笔记指定分P和时间点', (WidgetTester tester) async {
    final _FakePlaybackService playbackService = _FakePlaybackService(
      savedState: const SavedPlaybackState(
        cid: 137649199,
        pageNumber: 1,
        position: Duration(seconds: 8),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: playbackService,
          initialPartCid: 137649200,
          initialPosition: const Duration(seconds: 42),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(playbackService.openedCid, 137649200);
    expect(playbackService.seekToRequests, 1);
    expect(playbackService._position, const Duration(seconds: 42));
  });

  /// 验证专注记录跳转使用专注文案，不再错误显示为笔记位置。
  testWidgets('播放器显示专注记录跳转位置', (WidgetTester tester) async {
    final _FakePlaybackService playbackService = _FakePlaybackService(
      duration: const Duration(minutes: 25),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: playbackService,
          initialPartCid: 137649200,
          initialPosition: const Duration(minutes: 15),
          initialPositionSource: PlayerInitialPositionSource.focus,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(playbackService._position, const Duration(minutes: 15));
    expect(find.text('已跳转到专注位置：15:00'), findsOneWidget);
    expect(find.textContaining('笔记位置'), findsNothing);
  });

  /// 验证合集视频复用当前播放器加载，并在返回时恢复切换前的视频而不退出页面。
  testWidgets('合集切换不会卡住且返回上一支视频', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService playbackService = _FakePlaybackService();
    final _CollectionSwitchVideoService videoService =
        _CollectionSwitchVideoService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: playbackService,
          bilibiliService: videoService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('collection-preview-BV1Q541167Qg')));
    await tester.pumpAndSettle();

    expect(videoService.lookupRequests, 1);
    expect(playbackService.openedCid, 137649300);
    expect(find.text('合集第二支完整视频'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(playbackService.openedCid, 137649199);
    expect(find.text('合集中的当前视频'), findsOneWidget);
    expect(find.byType(PlayerPage), findsOneWidget);
  });

  /// 验证进入视频页时会优先打开本机保存的第二P。
  testWidgets('播放器会恢复最后观看的分P', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService(
      savedState: const SavedPlaybackState(
        cid: 137649200,
        pageNumber: 2,
        position: Duration(seconds: 12),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createMultiPartVideo(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(service.openedCid, 137649200);
    expect(find.text('已跳转到上次分P：P2'), findsOneWidget);
  });

  /// 验证只有一个分P的视频不会显示无意义的选集区域。
  testWidgets('单P视频不显示选集区域', (WidgetTester tester) async {
    final _FakePlaybackService service = _FakePlaybackService(
      savedState: const SavedPlaybackState(
        cid: 137649199,
        pageNumber: 1,
        position: Duration(seconds: 12),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('选集 · 共'), findsNothing);
    expect(find.byKey(const Key('part-selector-button')), findsNothing);
    expect(find.textContaining('已跳转到上次分P'), findsNothing);
  });

  /// 验证播放中长按画面会临时使用三倍速，松手后恢复原速度。
  testWidgets('长按播放画面临时切换三倍速', (WidgetTester tester) async {
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('play-pause-button')));
    await tester.pump();
    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final TestGesture gesture = await tester.startGesture(playerBounds.center);
    await tester.pump(const Duration(milliseconds: 650));

    expect(service._speed, 3);
    expect(find.text('三倍速中>>'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    expect(service._speed, 1);
    expect(find.text('三倍速中>>'), findsNothing);
  });

  /// 验证横向拖动无需等待长按即可预览，并只在松手时提交一次进度跳转。
  testWidgets('横向拖动立即预览并一次性跳转进度', (WidgetTester tester) async {
    final _FakePlaybackService service = _FakePlaybackService();
    final _FakeVideoShotService videoShotService = _FakeVideoShotService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
          videoShotService: videoShotService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final TestGesture gesture = await tester.startGesture(playerBounds.center);
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();

    expect(service.seekToRequests, 0);
    expect(service._speed, 1);
    expect(find.textContaining('跳转至'), findsOneWidget);
    expect(videoShotService.requests, 1);
    expect(find.byKey(const Key('video-shot-frame')), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(service.seekToRequests, 1);
    expect(service._position, greaterThan(Duration.zero));
    expect(service._speed, 1);
  });

  /// 验证长视频横向拖动会按时长提高速度，但单次跳转仍限制在十分钟内。
  testWidgets('长视频横向拖动使用自适应速度并限制最大范围', (WidgetTester tester) async {
    final _FakePlaybackService service = _FakePlaybackService(
      duration: const Duration(hours: 4),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final TestGesture gesture = await tester.startGesture(playerBounds.center);
    await gesture.moveBy(const Offset(2000, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(service._position, const Duration(minutes: 10));
    expect(service.seekToRequests, 1);
  });

  /// 验证系统取消横向拖动时不会把预览位置写入原生播放器。
  testWidgets('取消横向拖动不会写入预览进度', (WidgetTester tester) async {
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final TestGesture gesture = await tester.startGesture(playerBounds.center);
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(service.seekToRequests, 0);
    expect(service._position, Duration.zero);
    expect(find.textContaining('跳转至'), findsNothing);
  });

  /// 验证暂停时控制栏不会因旧计时器自动隐藏，继续播放后才恢复五秒自动收起。
  testWidgets('暂停时控制栏保持显示，播放时才自动隐藏', (WidgetTester tester) async {
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder controls = find.byKey(const Key('player-controls'));

    await tester.pump(const Duration(seconds: 6));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);

    await tester.tap(find.byKey(const Key('play-pause-button')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);
  });

  /// 验证全屏上下安全区内的竖滑不会调节亮度，而中间区域仍可正常调节。
  testWidgets('全屏竖滑会避开顶部和底部系统手势区', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 36, bottom: 28),
              viewPadding: const EdgeInsets.only(top: 36, bottom: 28),
            ),
            child: child!,
          );
        },
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pumpAndSettle();
    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );

    await tester.dragFrom(
      Offset(playerBounds.left + 40, playerBounds.top + 20),
      const Offset(0, -180),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.brightness, 0.5);

    await tester.dragFrom(
      Offset(playerBounds.left + 40, playerBounds.center.dy),
      const Offset(0, -180),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.brightness, greaterThan(0.5));
    final double brightnessAfterMiddle = service.brightness;

    await tester.dragFrom(
      Offset(playerBounds.left + 40, playerBounds.bottom - 12),
      const Offset(0, -180),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.brightness, brightnessAfterMiddle);
  });

  /// 验证超长分P标题在选集面板中使用独立两行竖向组件且不会布局溢出。
  testWidgets('分P超长标题在选集面板中保持可用', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createLongPartTitleVideo(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('part-title-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail-part-selector-expand')));
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const Key('part-title-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 验证全屏时系统返回键只退出全屏，不会直接关闭播放器页面。
  testWidgets('全屏返回键先退出全屏', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pumpAndSettle();

    expect(find.byTooltip('退出全屏'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byTooltip('进入全屏'), findsOneWidget);
    expect(find.byKey(const Key('player-surface')), findsOneWidget);
  });

  /// 验证横屏顶栏被明确固定在顶部，不会像截图中那样落到画面中央。
  testWidgets('全屏播放栏固定在画面顶部', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(920, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 350),
              viewPadding: const EdgeInsets.only(top: 350),
            ),
            child: child!,
          );
        },
        home: PlayerPage(
          video: _createLongTitleVideo(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.binding.setSurfaceSize(const Size(2000, 920));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.getTopLeft(find.byKey(const Key('top-player-bar'))).dy, 0);
    expect(tester.getCenter(find.byTooltip('返回')).dy, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  /// 验证全屏顶部同排显示长目标、剩余时间、本地时间和电量，长目标会进入循环滚动。
  testWidgets('全屏顶部显示专注目标时间和电量', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    const String longGoal = '完成今天最重要的Flutter专注计时功能';
    await focusController.startFocus(
      goal: longGoal,
      duration: const Duration(minutes: 25),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
          deviceStatusService: const _FakeDeviceStatusService(73),
          focusTimerController: focusController,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.byKey(const Key('fullscreen-device-status')), findsOneWidget);
    expect(find.text('73%'), findsOneWidget);
    expect(find.byKey(const Key('fullscreen-focus-status')), findsOneWidget);
    expect(find.byKey(const Key('fullscreen-focus-remaining')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('fullscreen-focus-goal'))).width,
      lessThanOrEqualTo(120),
    );
    final Text focusRemaining = tester.widget<Text>(
      find.byKey(const Key('fullscreen-focus-remaining')),
    );
    expect(focusRemaining.data, matches(RegExp(r'^\d{2}:\d{2}$')));
    expect(find.text(longGoal), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.byKey(const Key('fullscreen-device-status'))).dy,
      lessThan(24),
    );
    final double focusY = tester
        .getCenter(find.byKey(const Key('fullscreen-focus-status')))
        .dy;
    expect(
      tester.getCenter(find.byKey(const Key('fullscreen-local-clock'))).dy,
      closeTo(focusY, 2),
    );
    expect(
      tester.getCenter(find.byKey(const Key('fullscreen-battery'))).dy,
      closeTo(focusY, 2),
    );
    await focusController.endFocusEarly();
    await tester.pump();
  });

  /// 验证播放器可以打开专注控制面板，并在专注结束时暂停真实播放服务。
  testWidgets('播放器管理专注并在结束时自动暂停', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    await focusController.startFocus(
      goal: '完成播放器专注联动',
      duration: const Duration(minutes: 25),
    );
    final _FakePlaybackService playbackService = _FakePlaybackService();

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: playbackService,
          focusTimerController: focusController,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('player-focus-button')), findsOneWidget);
    final IconButton focusButton = tester.widget<IconButton>(
      find.byKey(const Key('player-focus-button')),
    );
    focusButton.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-focus-active')), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await playbackService.play();
    await tester.pump();
    await focusController.endFocusEarly();
    await tester.pump();

    expect(playbackService.pauseRequests, 1);
    expect(find.text('专注已结束，视频已暂停'), findsOneWidget);
  });

  /// 验证全屏更多菜单可选择真实字幕轨道，并在播放画面中显示当前时间段的文字。
  testWidgets('播放器可以选择并显示字幕', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const SubtitleTrack track = SubtitleTrack(
      id: 'zh-Hans',
      language: 'zh-Hans',
      label: '中文（简体）',
      isLocked: false,
    );
    final _FakePlayerOverlayService overlayService = _FakePlayerOverlayService(
      tracksResult: const SubtitleTrackLoadResult(
        status: SubtitleLoadStatus.available,
        message: '',
        tracks: <SubtitleTrack>[track],
      ),
      cuesResult: const SubtitleCueLoadResult(
        status: SubtitleLoadStatus.available,
        message: '',
        cues: <SubtitleCue>[
          SubtitleCue(
            from: Duration.zero,
            to: Duration(minutes: 1),
            content: '真实字幕内容',
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
          playerOverlayService: overlayService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pumpAndSettle();
    final dynamic moreMenuState = tester.state(
      find.byKey(const Key('more-settings-menu')),
    );
    moreMenuState.showButtonMenu();
    await tester.pumpAndSettle();
    await tester.tap(find.text('字幕'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('中文（简体）'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('active-subtitle')), findsOneWidget);
    expect(find.text('真实字幕内容'), findsOneWidget);
  });

  /// 验证弹幕开关会按当前时间轴请求真实六分钟片段，并创建不拦截手势的绘制画布。
  testWidgets('播放器可以加载并绘制当前片段的真实弹幕', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlayerOverlayService overlayService = _FakePlayerOverlayService(
      tracksResult: const SubtitleTrackLoadResult.empty(),
      cuesResult: const SubtitleCueLoadResult.empty(),
      danmakuResult: const DanmakuSegmentLoadResult(
        status: DanmakuLoadStatus.available,
        message: '',
        segmentIndex: 1,
        entries: <DanmakuEntry>[
          DanmakuEntry(
            position: Duration.zero,
            content: '真实弹幕内容',
            color: 0xFFFFFF,
            mode: 1,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
          playerOverlayService: overlayService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pumpAndSettle();
    final IconButton danmakuButton = tester.widget<IconButton>(
      find.byKey(const Key('danmaku-toggle')),
    );
    danmakuButton.onPressed!();
    await tester.pumpAndSettle();

    expect(overlayService.danmakuSegmentRequests, <int>[1]);
    expect(find.byKey(const Key('danmaku-canvas')), findsOneWidget);
  });

  /// 验证输入法压缩搜索页面时，固定控件和空状态都不会产生黄黑溢出标记。
  testWidgets('搜索输入法出现时页面不会布局溢出', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: 280)),
            child: child!,
          );
        },
        home: const SearchPage(),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '星');
    await tester.pump(const Duration(milliseconds: 100));

    final Rect modeSelectorRect = tester.getRect(
      find.byKey(const Key('search-mode-selector')),
    );
    final Rect resultRect = tester.getRect(
      find.byKey(const Key('search-result-overlay')),
    );
    expect(resultRect.top - modeSelectorRect.bottom, lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  /// 验证全屏右上角画中画按钮会调用播放器服务的 Android 能力。
  testWidgets('全屏画中画按钮调用原生能力', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pumpAndSettle();

    final IconButton pictureInPictureButton = tester.widget<IconButton>(
      find.byKey(const Key('picture-in-picture')),
    );
    pictureInPictureButton.onPressed!();
    await tester.pump();

    expect(service.pictureInPictureRequests, 1);
  });

  /// 验证播放器“更多设置”可打开弹幕面板，开关变化会立即持久化到当前用户配置。
  testWidgets('弹幕设置入口立即应用并持久化开关', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final DanmakuPreferencesService preferencesService =
        DanmakuPreferencesService();
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
          danmakuPreferencesService: preferencesService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dynamic moreMenuState = tester.state(
      find.byKey(const Key('more-settings-menu')),
    );
    // 测试环境直接调用 Flutter 菜单状态，避免外层播放手势抢占模拟点击。
    moreMenuState.showButtonMenu();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('danmaku-settings-menu-item')));
    await tester.pumpAndSettle();
    expect(find.text('屏蔽关键词'), findsOneWidget);

    await tester.tap(find.byKey(const Key('danmaku-settings-enabled')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭弹幕'), findsOneWidget);
    expect((await preferencesService.load()).enabled, isTrue);
  });

  /// 验证全屏锁定后只有解锁按钮可操作，其他控制层完全隐藏且不接收触摸。
  testWidgets('全屏锁定隐藏其他播放器按钮', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
          ),
        )
        .onPressed!();
    await tester.pumpAndSettle();

    final Finder lockButton = find.byKey(const Key('fullscreen-controls-lock'));
    tester
        .widget<IconButton>(
          find.descendant(of: lockButton, matching: find.byType(IconButton)),
        )
        .onPressed!();
    await tester.pump();

    final AnimatedOpacity controls = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('player-controls')),
    );
    expect(controls.opacity, 0);
    expect((controls.child! as IgnorePointer).ignoring, isTrue);
    expect(find.byTooltip('解锁播放器'), findsOneWidget);
  });

  /// 验证全屏边缘的横向拖动属于系统导航安全区，不会提交视频回退。
  testWidgets('全屏横滑避开左右系统导航安全区', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
          ),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    final Rect surface = tester.getRect(
      find.byKey(const Key('player-surface')),
    );

    await tester.dragFrom(
      Offset(surface.left + 8, surface.center.dy),
      const Offset(180, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(service.seekToRequests, 0);
    expect(service._position, Duration.zero);
  });

  /// 验证关闭双击快进后，右侧双击也只会切换播放而不快进。
  testWidgets('关闭双击快进后双击任意位置切换播放', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PlaybackPreferencesService preferencesService =
        PlaybackPreferencesService();
    await preferencesService.saveDoubleTapSeekEnabled(false);
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
          playbackPreferencesService: preferencesService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect surface = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final Offset rightSide = Offset(surface.right - 24, surface.center.dy);

    await tester.tapAt(rightSide);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(rightSide);
    await tester.pump(const Duration(milliseconds: 400));

    expect(service._isPlaying, isTrue);
    expect(service.seekByRequests, 0);
    expect(service._position, Duration.zero);
  });

  /// 验证搜索记录保存在本地，并将重复内容移动到最前面。
  test('搜索记录可以保存并去重', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SearchHistoryService service = SearchHistoryService();

    await service.addHistory('BV1GJ411x7h7');
    await service.addHistory('BV1GJ411x7h8');
    final List<String> history = await service.addHistory('BV1GJ411x7h7');

    expect(history, <String>['BV1GJ411x7h7', 'BV1GJ411x7h8']);
  });
}
