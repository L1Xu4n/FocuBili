import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/app.dart';
import 'package:focubili/features/focus/focus_timer_controller.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/profile/login_page.dart';
import 'package:focubili/features/profile/user_profile_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/focus_session.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/player_enhancement.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/app_theme_mode_service.dart';
import 'package:focubili/services/device_status_service.dart';
import 'package:focubili/services/danmaku_preferences_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/player_overlay_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/search_history_service.dart';
import 'package:focubili/services/first_launch_service.dart';
import 'package:focubili/services/focus_notification_service.dart';
import 'package:focubili/services/focus_preferences_service.dart';
import 'package:focubili/services/watch_history_service.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/video_shot_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'package:focubili/services/bilibili_player_enhancement_service.dart';
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
    this.emitLoadingDuringSeek = false,
    this.duration = _defaultDuration,
    this.textureId,
  });

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  static const Duration _defaultDuration = Duration(minutes: 3, seconds: 32);
  final Duration duration;
  final int? textureId;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  double _speed = 1;
  int _quality = 64;
  String? openedBvid;
  int? openedCid;
  int openVideoRequests = 0;
  final List<String> openedBvids = <String>[];
  final List<int> openedCids = <int>[];
  final List<int> openedQualities = <int>[];
  final List<int> selectedQualities = <int>[];
  Completer<void>? retryOpenCompleter;
  final SavedPlaybackState? savedState;
  final bool rejectQuality;
  final bool emitReadyOnOpen;
  final bool emitLoadingDuringSeek;
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

  /// 默认返回空纹理；画幅测试可以注入假编号，只验证 Flutter 缩放布局而不播放视频。
  @override
  Future<int?> initialize() async => textureId;

  /// 模拟打开视频完成，记录分P和清晰度，并在需要时等待测试控制的重试请求。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
  }) async {
    final VideoPart targetPart = part ?? video.initialPart;
    openVideoRequests += 1;
    openedBvid = video.bvid;
    openedCid = targetPart.cid;
    openedBvids.add(video.bvid);
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
    if (emitLoadingDuringSeek) {
      _emit(phase: PlaybackPhase.loading);
      await Future<void>.delayed(Duration.zero);
    }
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
    if (emitLoadingDuringSeek) {
      _emit(phase: PlaybackPhase.loading);
      await Future<void>.delayed(Duration.zero);
    }
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
    selectedQualities.add(quality);
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

  /// 把播放位置推进到互动节点的指定秒数，并保留当前是否正在播放的状态。
  void emitPosition(Duration position) {
    _position = Duration(
      milliseconds: position.inMilliseconds
          .clamp(0, duration.inMilliseconds)
          .toInt(),
    );
    _emit();
  }

  /// 向播放器页面推送一条完播状态，验证 Flutter 不会自行自动连播下一分P。
  void emitEnded() {
    _isPlaying = false;
    _position = duration;
    _emit(phase: PlaybackPhase.ended, message: '播放结束');
  }

  /// 关闭测试使用的状态流，模拟页面离开时释放播放器。
  @override
  Future<void> dispose() => _states.close();
}

/// 为播放器组件测试提供固定章节和互动剧情，不访问真实 B 站接口。
class _FakePlayerEnhancementService
    implements BilibiliPlayerEnhancementService {
  /// 创建可配置元数据、起始节点和分支节点的播放器增强替身。
  _FakePlayerEnhancementService({
    required this.metadata,
    this.initialNode,
    this.branchNode,
  });

  final PlayerEnhancementMetadata metadata;
  final InteractiveVideoNode? initialNode;
  final InteractiveVideoNode? branchNode;
  final List<int?> requestedEdgeIds = <int?>[];

  /// 返回测试预先设置的章节和互动入口信息。
  @override
  Future<PlayerEnhancementMetadata> loadMetadata({
    required String bvid,
    required int cid,
  }) async {
    return metadata;
  }

  /// 根据 edge_id 返回起始或后续剧情节点，并记录播放器请求。
  @override
  Future<InteractiveVideoNode> loadInteractiveNode({
    required String bvid,
    required int graphVersion,
    int? edgeId,
  }) async {
    requestedEdgeIds.add(edgeId);
    final InteractiveVideoNode? node = edgeId == null
        ? initialNode
        : branchNode;
    if (node == null) {
      throw const PlayerEnhancementException('测试没有准备互动节点。');
    }
    return node;
  }
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
  /// 创建返回固定电量和网络类型的设备状态服务替身。
  const _FakeDeviceStatusService(
    this.batteryPercent, {
    this.networkType = DeviceNetworkType.wifi,
  });

  final int? batteryPercent;
  final DeviceNetworkType networkType;

  /// 返回构造时传入的电量百分比，不访问任何原生方法通道。
  @override
  Future<int?> loadBatteryPercent() async => batteryPercent;

  /// 返回构造时传入的网络类型，不读取 Android 连接信息。
  @override
  Future<DeviceNetworkType> loadNetworkType() async => networkType;
}

/// 为播放器组件测试提供固定字幕轨道和条目，不访问 Android 通道或真实字幕地址。
class _FakePlayerOverlayService implements PlayerOverlayService {
  /// 创建可配置字幕、弹幕结果或延迟弹幕加载函数的本地服务替身。
  _FakePlayerOverlayService({
    required this.tracksResult,
    required this.cuesResult,
    this.danmakuResult = const DanmakuSegmentLoadResult.empty(),
    this.danmakuLoader,
  });

  final SubtitleTrackLoadResult tracksResult;
  final SubtitleCueLoadResult cuesResult;
  final DanmakuSegmentLoadResult danmakuResult;
  final Future<DanmakuSegmentLoadResult> Function(int segmentIndex)?
  danmakuLoader;
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

  /// 记录段号并返回即时或延迟结果，用于覆盖正常加载与网络晚到两种弹幕场景。
  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    danmakuSegmentRequests.add(segmentIndex);
    if (danmakuLoader != null) {
      return danmakuLoader!(segmentIndex);
    }
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
  /// 每项组件测试从空白本机偏好开始，避免网络清晰度选择跨用例泄漏。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

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

  /// 验证没有保存外观偏好时，根组件默认跟随系统并正常显示首页。
  testWidgets('新框架首页可以正常启动', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      FirstLaunchService.agreementAcceptedKey: true,
      FirstLaunchService.loginGuideShownKey: true,
    });
    await tester.pumpWidget(const FocuBiliApp());
    await tester.pumpAndSettle();

    final MaterialApp app = tester.widget<MaterialApp>(
      find.byType(MaterialApp),
    );
    expect(app.locale, const Locale('zh', 'CN'));
    expect(app.themeMode, ThemeMode.system);
    expect(find.text('焦点哔哩'), findsWidgets);
    expect(find.text('打开视频'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  /// 验证根组件启动时恢复本机深色选择，而不是每次强制跟随系统。
  testWidgets('应用根组件恢复已保存的深色模式', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      FirstLaunchService.agreementAcceptedKey: true,
      FirstLaunchService.loginGuideShownKey: true,
    });
    await const AppThemeModeService().save(ThemeMode.dark);

    await tester.pumpWidget(const FocuBiliApp());
    await tester.pumpAndSettle();

    final MaterialApp app = tester.widget<MaterialApp>(
      find.byType(MaterialApp),
    );
    expect(app.themeMode, ThemeMode.dark);
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

  /// 验证快进产生的加载快照不会切换勿扰，但用户按下暂停和播放仍会正常关闭与开启。
  testWidgets('专注播放快进不抖动勿扰且暂停播放正常切换', (WidgetTester tester) async {
    const MethodChannel channel = MethodChannel(
      'com.focubili.app/test_player_seek_do_not_disturb',
    );
    final List<bool> doNotDisturbStates = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'hasDoNotDisturbAccess') {
            return true;
          }
          if (call.method == 'setFocusDoNotDisturb') {
            doNotDisturbStates.add(
              Map<Object?, Object?>.from(call.arguments as Map)['enabled'] ==
                  true,
            );
            return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final FocusPreferencesService preferencesService = FocusPreferencesService(
      preferencesLoader: () async => preferences,
    );
    await preferencesService.saveDoNotDisturbEnabled(true);
    await preferencesService.markPlayerDoNotDisturbGuideSeen();
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
      notificationService: const FocusNotificationService(channel: channel),
      focusPreferencesService: preferencesService,
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    final VideoPreview video = VideoPreview.placeholder();
    await focusController.startFocus(
      goal: '验证勿扰切换',
      duration: const Duration(minutes: 25),
      sourceBvid: video.bvid,
      sourcePartCid: video.initialPart.cid,
    );
    final _FakePlaybackService playbackService = _FakePlaybackService(
      emitLoadingDuringSeek: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: playbackService,
          focusTimerController: focusController,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await playbackService.play();
    await tester.pump();
    doNotDisturbStates.clear();

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
    expect(playbackService.seekByRequests, 1);
    expect(doNotDisturbStates, isEmpty, reason: '快进加载只是播放器内部过渡，不应把系统勿扰关闭后再开启。');

    await tester.tap(find.byKey(const Key('play-pause-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('play-pause-button')));
    await tester.pump();
    expect(doNotDisturbStates, <bool>[false, true]);
  });

  /// 验证控制栏菜单不再参与画面双击竞争，并在第一帧建立短动画菜单路由。
  testWidgets('播放器清晰度菜单点击立即打开', (WidgetTester tester) async {
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

    final PopupMenuButton<int> qualityMenu = tester.widget(
      find.byKey(const Key('quality-menu')),
    );
    expect(
      qualityMenu.popUpAnimationStyle,
      const AnimationStyle(
        duration: Duration(milliseconds: 100),
        reverseDuration: Duration(milliseconds: 80),
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
    );

    await tester.tap(find.byKey(const Key('quality-menu')));
    await tester.pump();

    expect(find.byKey(const Key('quality-64')), findsOneWidget);
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

  /// 验证学习清单按钮位于“记笔记”左侧，第二次点击会确认并取消本机任务。
  testWidgets('播放器顶部学习清单按钮可确认取消加入', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: _FakePlaybackService(),
          learningListService: learningListService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder learningButton = find.byKey(
      const Key('current-video-learning-list-button'),
    );
    final Finder noteButton = find.byKey(const Key('portrait-note-button'));
    final Rect learningBounds = tester.getRect(learningButton);
    final Rect noteBounds = tester.getRect(noteButton);
    expect(learningBounds.center.dy, closeTo(noteBounds.center.dy, 1));
    expect(learningBounds.center.dx, lessThan(noteBounds.center.dx));

    await tester.tap(learningButton);
    await tester.pumpAndSettle();
    expect(await learningListService.loadEntries(), hasLength(1));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('已将 P1 加入学习清单'), findsOneWidget);
    expect(find.byKey(const Key('player-floating-notice')), findsNothing);
    expect(
      find.descendant(of: learningButton, matching: find.text('P1 已加入')),
      findsOneWidget,
    );

    await tester.tap(learningButton);
    await tester.pumpAndSettle();
    expect(find.text('取消加入学习清单'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '取消加入'));
    await tester.pumpAndSettle();

    expect(await learningListService.loadEntries(), isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('已将当前分 P 移出学习清单'), findsOneWidget);
    expect(find.byKey(const Key('player-floating-notice')), findsNothing);
    expect(
      find.descendant(of: learningButton, matching: find.text('加入 P1')),
      findsOneWidget,
    );
  });

  /// 验证同一视频只有真正加入的分 P 显示已加入，切换分 P 不会复用旧按钮状态。
  testWidgets('播放器学习清单按钮按分P独立显示状态', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createMultiPartVideo(),
          playbackService: _FakePlaybackService(),
          learningListService: learningListService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder learningButton = find.byKey(
      const Key('current-video-learning-list-button'),
    );
    await tester.tap(learningButton);
    await tester.pumpAndSettle();
    expect(find.text('P1 已加入'), findsOneWidget);

    await tester.tap(find.byKey(const Key('part-2')).first);
    await tester.pumpAndSettle();
    expect(find.text('加入 P2'), findsOneWidget);
    expect(find.text('P2 已加入'), findsNothing);
    final List<LearningListEntry> onlyFirstPart = await learningListService
        .loadEntries();
    expect(onlyFirstPart, hasLength(1));
    expect(onlyFirstPart.single.partCid, 137649199);

    await tester.tap(learningButton);
    await tester.pumpAndSettle();
    expect(find.text('P2 已加入'), findsOneWidget);
    expect(await learningListService.loadEntries(), hasLength(2));

    await tester.tap(find.byKey(const Key('part-1')).first);
    await tester.pumpAndSettle();
    expect(find.text('P1 已加入'), findsOneWidget);
  });

  /// 验证已完成任务再次播放时仍保持完成，自动进度保存不能把它降级成学习中。
  testWidgets('播放器不会把已完成学习任务改回学习中', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    final VideoPreview video = VideoPreview.placeholder();
    await learningListService.addVideo(video, part: video.initialPart);
    await learningListService.updateStatus(
      video.bvid,
      LearningListStatus.completed,
      partCid: video.initialPart.cid,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: _FakePlaybackService(),
          learningListService: learningListService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('P1 已完成'), findsOneWidget);
    await tester.tap(find.byKey(const Key('play-pause-button')));
    await tester.pumpAndSettle();

    expect(
      (await learningListService.loadEntries()).single.status,
      LearningListStatus.completed,
    );
    expect(find.text('P1 已完成'), findsOneWidget);
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

  /// 验证 Wi-Fi 默认请求 1080P，而视频只提供较低档时自动降到 720P。
  testWidgets('Wi-Fi 默认清晰度不可用时只向下回退', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PlaybackPreferencesService preferencesService =
        PlaybackPreferencesService();
    await preferencesService.saveWifiDefaultQuality(
      PreferredPlaybackQuality.p1080,
    );
    final _FakePlaybackService service = _FakePlaybackService();

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
          playbackPreferencesService: preferencesService,
          deviceStatusService: const _FakeDeviceStatusService(
            70,
            networkType: DeviceNetworkType.wifi,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(service.openedQualities, <int>[80]);
    expect(service.selectedQualities, <int>[64]);
    expect(service._quality, 64);
  });

  /// 验证移动网络使用独立的低流量默认清晰度，不沿用 Wi-Fi 选择。
  testWidgets('移动网络使用独立默认清晰度', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const PlaybackPreferencesService preferencesService =
        PlaybackPreferencesService();
    await preferencesService.saveWifiDefaultQuality(
      PreferredPlaybackQuality.p1080,
    );
    await preferencesService.saveMobileDefaultQuality(
      PreferredPlaybackQuality.p480,
    );
    final _FakePlaybackService service = _FakePlaybackService();

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
          playbackPreferencesService: preferencesService,
          deviceStatusService: const _FakeDeviceStatusService(
            70,
            networkType: DeviceNetworkType.mobile,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(service.openedQualities, <int>[32]);
    expect(service.selectedQualities, isEmpty);
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

  /// 验证播放器把原生 ended 快照交给专注控制器，使当前分P模式按真实完播结束。
  testWidgets('播放器当前分P专注收到真实完播后完成', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final VideoPreview video = _createMultiPartVideo();
    final FocusTimerController controller = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.startFocus(
      goal: '看完第一P',
      duration: const Duration(minutes: 2),
      startImmediately: false,
      sourceBvid: video.bvid,
      sourceVideoTitle: video.title,
      sourcePartCid: video.initialPart.cid,
      sourcePartPageNumber: video.initialPart.pageNumber,
      sourcePartTitle: video.initialPart.title,
      completeOnPartEnd: true,
    );
    final _FakePlaybackService playbackService = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: playbackService,
          focusTimerController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await playbackService.play();
    await tester.pump();
    expect(controller.activeSession?.status, FocusSessionStatus.running);
    playbackService.emitEnded();
    await tester.pump();
    await tester.pump();

    expect(controller.activeSession, isNull);
    expect(controller.history.single.status, FocusSessionStatus.completed);
    expect(find.text('专注完成，视频已暂停'), findsOneWidget);
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

    final Finder description = find.byKey(const Key('video-description'));
    final Text descriptionText = tester.widget<Text>(description);
    final TextSpan rootSpan = descriptionText.textSpan! as TextSpan;
    final List<InlineSpan> spans = rootSpan.children!;
    final TextSpan mention = spans[1] as TextSpan;
    final TextSpan link = spans[3] as TextSpan;
    expect(mention.style?.color, isNotNull);
    expect(mention.recognizer, isNotNull);
    expect(link.style?.decoration, TextDecoration.underline);
    expect(link.recognizer, isNotNull);

    final TapGestureRecognizer mentionRecognizer =
        mention.recognizer! as TapGestureRecognizer;
    mentionRecognizer.onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(UserProfilePage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(seconds: 1));

    final TapGestureRecognizer linkRecognizer =
        link.recognizer! as TapGestureRecognizer;
    linkRecognizer.onTap!();
    await tester.pumpAndSettle();
    expect(find.text('即将打开外部链接'), findsOneWidget);
    expect(find.textContaining('内容和安全性'), findsOneWidget);
    expect(launchedUri, isNull);
    await tester.tap(find.byKey(const Key('cancel-external-link')));
    await tester.pumpAndSettle();
    expect(launchedUri, isNull);

    linkRecognizer.onTap!();
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
    // 停止输入后，草稿会在去抖时间内自动写入本机，不依赖手动保存按钮。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await noteService.loadNotes(), hasLength(1));
    expect((await noteService.loadNotes()).single.body, '这是正文内容。');
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
    expect(find.byKey(const Key('regular-note-part-label')), findsOneWidget);
    expect(find.text('P1'), findsNWidgets(2));
    expect(
      find.byKey(Key('portrait-video-note-part-${notes.single.id}')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('delete-video-note')));
    await tester.pumpAndSettle();
    expect(find.text('确定删除“关键观点”吗？此操作无法撤销。'), findsOneWidget);
    expect(await noteService.loadNotes(), hasLength(1));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await noteService.loadNotes(), hasLength(1));
  });

  /// 验证全屏笔记列表只选中内容，且必须点击独立按钮才会跳转时间点。
  testWidgets('全屏时间点笔记显示半透明列表并显式跳转进度', (WidgetTester tester) async {
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
    final Size panelSize = tester.getSize(
      find.byKey(const Key('fullscreen-video-notes-panel')),
    );
    expect(panelSize.width, closeTo(2000 * 0.64, 1));
    expect(panelSize.width, lessThan(2000 * 2 / 3));
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
    expect(playbackService.seekToRequests, 0);
    expect(find.text('视频位置：00:42'), findsOneWidget);
    await tester.tap(find.byKey(const Key('jump-to-video-note-position')));
    await tester.pump();
    expect(playbackService.seekToRequests, 1);

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

  /// 验证清单最后一项完播后由用户确认完成，不会再按视频分 P 自动连播。
  testWidgets('学习清单最后一项完播后显示已完成学习', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    final VideoPreview video = _createMultiPartVideo();
    await learningListService.addVideo(video, part: video.parts.first);
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: service,
          learningListService: learningListService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final int opensBeforeEnded = service.openVideoRequests;
    service.emitEnded();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('playback-completion-prompt')), findsOneWidget);
    expect(find.byKey(const Key('mark-learning-complete')), findsOneWidget);
    expect(
      find.byKey(const Key('continue-learning-after-completion')),
      findsOneWidget,
    );
    expect(service.openVideoRequests, opensBeforeEnded);

    await tester.tap(find.byKey(const Key('mark-learning-complete')));
    await tester.pumpAndSettle();
    expect(find.text('已标记完成'), findsWidgets);
    await tester.tap(
      find.byKey(const Key('continue-learning-after-completion')),
    );
    await tester.pumpAndSettle();
    expect(find.text('已完成学习'), findsOneWidget);
    expect(find.byKey(const Key('playback-completion-prompt')), findsOneWidget);
    expect(service.openVideoRequests, opensBeforeEnded);
    expect(
      (await learningListService.loadEntries()).single.status,
      LearningListStatus.completed,
    );
  });

  /// 验证继续学习复用当前播放服务打开下一项，旧页面不会销毁后误释放新播放器。
  testWidgets('继续学习会在当前播放器内打开下一条任务', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    final VideoPreview firstVideo = _createCollectionVideo();
    final VideoPreview secondVideo = _createSecondCollectionVideo();
    await learningListService.addVideo(
      firstVideo,
      part: firstVideo.initialPart,
    );
    await learningListService.addVideo(
      secondVideo,
      part: secondVideo.initialPart,
    );
    final _FakePlaybackService playbackService = _FakePlaybackService();
    final _CollectionSwitchVideoService videoService =
        _CollectionSwitchVideoService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: firstVideo,
          playbackService: playbackService,
          learningListService: learningListService,
          bilibiliService: videoService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final int opensBeforeEnded = playbackService.openVideoRequests;
    playbackService.emitEnded();
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('continue-learning-after-completion')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PlayerPage), findsOneWidget);
    expect(videoService.lookupRequests, 1);
    expect(playbackService.openVideoRequests, opensBeforeEnded + 1);
    expect(playbackService.openedBvid, secondVideo.bvid);
    expect(playbackService.openedCid, secondVideo.initialPart.cid);
    expect(find.text(secondVideo.title), findsOneWidget);
    final List<LearningListEntry> entries = await learningListService
        .loadEntries();
    expect(
      entries
          .firstWhere(
            (LearningListEntry entry) => entry.bvid == firstVideo.bvid,
          )
          .status,
      LearningListStatus.completed,
    );
  });

  /// 验证 720×360 横屏中的紧凑完播卡片不会再向下挤入播放控制栏。
  testWidgets('横屏完播卡片保持紧凑并避开播放栏', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(720, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    final VideoPreview video = VideoPreview.placeholder();
    await learningListService.addVideo(video, part: video.initialPart);
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: service,
          learningListService: learningListService,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    service.emitEnded();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(tester.takeException(), isNull);
    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final Rect promptBounds = tester.getRect(
      find.byKey(const Key('playback-completion-prompt')),
    );
    expect(promptBounds.height, lessThanOrEqualTo(125));
    expect(playerBounds.bottom - promptBounds.bottom, greaterThanOrEqualTo(70));
  });

  /// 验证普通视频完播时不显示学习清单专属的完成或继续学习提示。
  testWidgets('非学习清单视频完播后不显示完成提示', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: service,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    service.emitEnded();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('playback-completion-prompt')), findsNothing);
  });

  /// 验证完播提示中的完成按钮仅更新已有学习任务，并让已完成状态留在卡片中。
  testWidgets('播放器完播后可以标记学习任务完成', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final LearningListService learningListService = LearningListService(
      preferencesLoader: () async => preferences,
    );
    final VideoPreview video = VideoPreview.placeholder();
    await learningListService.addVideo(video, part: video.initialPart);
    final _FakePlaybackService service = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: service,
          learningListService: learningListService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    service.emitEnded();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('mark-learning-complete')));
    await tester.pumpAndSettle();

    final List<LearningListEntry> entries = await learningListService
        .loadEntries();
    expect(entries, hasLength(1));
    expect(entries.single.status, LearningListStatus.completed);
    expect(find.byKey(const Key('playback-completion-prompt')), findsOneWidget);
    expect(find.text('已标记完成'), findsWidgets);
  });

  /// 验证章节条固定在播放器内、可滚动显示标题、可跳转，并能从专用按钮打开面板。
  testWidgets('播放器显示四段视频进度并支持分段面板跳转', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService playbackService = _FakePlaybackService(
      duration: const Duration(seconds: 690),
    );
    final _FakePlayerEnhancementService enhancementService =
        _FakePlayerEnhancementService(
          metadata: const PlayerEnhancementMetadata(
            chapters: <VideoChapter>[
              VideoChapter(
                title: '什么是北京中轴线',
                start: Duration.zero,
                end: Duration(seconds: 68),
                imageUrl: 'https://i0.hdslb.com/bfs/vchapter/1629781561_0.jpg',
              ),
              VideoChapter(
                title: '王朝的接力',
                start: Duration(seconds: 68),
                end: Duration(seconds: 292),
              ),
              VideoChapter(
                title: '巨匠的思索',
                start: Duration(seconds: 292),
                end: Duration(seconds: 508),
              ),
              VideoChapter(
                title: '人间的烟火',
                start: Duration(seconds: 508),
                end: Duration(seconds: 690),
              ),
            ],
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: playbackService,
          playerEnhancementService: enhancementService,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('video-chapter-strip')), findsOneWidget);
    expect(find.byKey(const Key('video-chapter-marquee-0')), findsOneWidget);
    final Rect playerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final Rect chapterStripBounds = tester.getRect(
      find.byKey(const Key('video-chapter-strip')),
    );
    expect(chapterStripBounds.top, greaterThanOrEqualTo(playerBounds.top));
    expect(chapterStripBounds.bottom, lessThanOrEqualTo(playerBounds.bottom));
    expect(chapterStripBounds.height, 24);
    expect(find.byKey(const Key('video-chapter-button')), findsOneWidget);
    expect(find.text('王朝的接力'), findsOneWidget);

    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-chapter-strip')), findsOneWidget);
    await tester.tapAt(
      tester.getRect(find.byKey(const Key('player-surface'))).center,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('video-chapter-strip')), findsOneWidget);
    final Rect fullscreenPlayerBounds = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    final Rect hiddenControlsChapterBounds = tester.getRect(
      find.byKey(const Key('video-chapter-strip')),
    );
    expect(
      hiddenControlsChapterBounds.left,
      closeTo(fullscreenPlayerBounds.left, 0.1),
    );
    expect(
      hiddenControlsChapterBounds.right,
      closeTo(fullscreenPlayerBounds.right, 0.1),
    );
    await tester.tapAt(
      tester.getRect(find.byKey(const Key('player-surface'))).center,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(
      find.byKey(const ValueKey<String>('video-chapter-strip-1')),
    );
    await tester.pump();
    expect(playbackService._position, const Duration(seconds: 68));

    await tester.tap(find.byKey(const Key('video-chapter-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('video-chapter-panel')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-chapter-preview-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-chapter-item-3')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('video-chapter-progress-toggle')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('video-chapter-panel')),
        matching: find.byTooltip('关闭'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('video-chapter-strip')), findsNothing);
  });

  /// 验证互动视频完播不会自动开分支，点击选项后才打开目标 CID 并加载下一节点。
  testWidgets('互动视频由用户选择剧情分支且不会自动连播', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService playbackService = _FakePlaybackService();
    final _FakePlayerEnhancementService enhancementService =
        _FakePlayerEnhancementService(
          metadata: const PlayerEnhancementMetadata(
            interaction: InteractiveVideoInfo(graphVersion: 1619916),
          ),
          initialNode: const InteractiveVideoNode(
            title: '初始界面',
            edgeId: 1,
            isLeaf: false,
            choices: <InteractiveVideoChoice>[
              InteractiveVideoChoice(
                edgeId: 46910898,
                cid: 40178418329,
                label: 'A 开始游戏',
              ),
              InteractiveVideoChoice(
                edgeId: 46910899,
                cid: 40178877072,
                label: 'B 离开游戏',
              ),
            ],
          ),
          branchNode: const InteractiveVideoNode(
            title: '起床',
            edgeId: 46910898,
            isLeaf: false,
            choices: <InteractiveVideoChoice>[
              InteractiveVideoChoice(
                edgeId: 46910900,
                cid: 40178419999,
                label: '继续寻找真相',
              ),
            ],
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: playbackService,
          playerEnhancementService: enhancementService,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final int opensBeforeEnded = playbackService.openVideoRequests;
    playbackService.emitEnded();
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const Key('interactive-video-choice-overlay')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('playback-completion-prompt')), findsNothing);
    expect(playbackService.openVideoRequests, opensBeforeEnded);
    final Material firstChoiceCard = tester.widget<Material>(
      find.byKey(const ValueKey<String>('interactive-video-choice-0')),
    );
    expect(firstChoiceCard.color, const Color(0x70000000));

    final Rect controlsVisibleChoiceBounds = tester.getRect(
      find.byKey(const Key('interactive-video-choice-overlay')),
    );
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
          .opacity,
      1,
    );
    final GestureDetector visibleSurface = tester.widget<GestureDetector>(
      find.byKey(const Key('player-surface')),
    );
    visibleSurface.onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('player-controls')))
          .opacity,
      0,
    );
    final Rect controlsHiddenChoiceBounds = tester.getRect(
      find.byKey(const Key('interactive-video-choice-overlay')),
    );
    expect(
      controlsHiddenChoiceBounds.top,
      greaterThan(controlsVisibleChoiceBounds.top + 50),
    );

    final GestureDetector hiddenSurface = tester.widget<GestureDetector>(
      find.byKey(const Key('player-surface')),
    );
    hiddenSurface.onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    final Rect liftedChoiceBounds = tester.getRect(
      find.byKey(const Key('interactive-video-choice-overlay')),
    );
    expect(liftedChoiceBounds.top, lessThan(controlsHiddenChoiceBounds.top));

    await tester.tap(
      find.byKey(const ValueKey<String>('interactive-video-choice-0')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(playbackService.openedCid, 40178418329);
    expect(enhancementService.requestedEdgeIds, <int?>[null, 46910898]);
    expect(
      find.byKey(const Key('interactive-video-choice-overlay')),
      findsNothing,
    );

    playbackService.emitEnded();
    await tester.pump();
    await tester.pump();
    expect(find.text('继续寻找真相'), findsOneWidget);
  });

  /// 验证 BV18ug66REzE 会在约八秒节点结束前 300 毫秒暂停并展示选项。
  testWidgets('互动视频在结尾前的毫秒提前量到达时显示选择', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakePlaybackService playbackService = _FakePlaybackService(
      duration: const Duration(seconds: 8),
    );
    final _FakePlayerEnhancementService enhancementService =
        _FakePlayerEnhancementService(
          metadata: const PlayerEnhancementMetadata(
            interaction: InteractiveVideoInfo(graphVersion: 1619916),
          ),
          initialNode: const InteractiveVideoNode(
            title: '初始界面',
            edgeId: 1,
            isLeaf: false,
            choicePromptLeadTime: Duration(milliseconds: 300),
            pauseVideoForChoice: true,
            choices: <InteractiveVideoChoice>[
              InteractiveVideoChoice(
                edgeId: 46910898,
                cid: 40178418329,
                label: 'A 开始游戏',
              ),
              InteractiveVideoChoice(
                edgeId: 46910899,
                cid: 40178877072,
                label: 'B 离开游戏',
              ),
            ],
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: playbackService,
          playerEnhancementService: enhancementService,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await playbackService.play();
    playbackService.emitPosition(const Duration(seconds: 7));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 699));
    expect(
      find.byKey(const Key('interactive-video-choice-overlay')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(playbackService.pauseRequests, 1);
    expect(
      find.byKey(const Key('interactive-video-choice-overlay')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('playback-completion-prompt')), findsNothing);
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
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
    expect(find.text('Wi-Fi'), findsOneWidget);
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
    expect(
      tester.getCenter(find.byKey(const Key('player-network-type'))).dx,
      lessThan(
        tester.getCenter(find.byKey(const Key('fullscreen-battery'))).dx,
      ),
    );
    await focusController.endFocusEarly();
    await tester.pump();
  });

  /// 验证“当前分P”专注的左上角时间跟随播放器快进后的真实剩余进度，而不是旧计划倒计时。
  testWidgets('当前分P专注左上角同步真实播放剩余时间', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final VideoPreview video = VideoPreview.placeholder();
    final _FakePlaybackService playbackService = _FakePlaybackService();
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    await focusController.startFocus(
      goal: '看完当前分P',
      duration: const Duration(minutes: 3, seconds: 32),
      sourceBvid: video.bvid,
      sourcePartCid: video.initialPart.cid,
      sourcePartPageNumber: video.initialPart.pageNumber,
      sourcePartTitle: video.initialPart.title,
      completeOnPartEnd: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: video,
          playbackService: playbackService,
          deviceStatusService: const _FakeDeviceStatusService(80),
          focusTimerController: focusController,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await playbackService.seekTo(const Duration(minutes: 1));
    await tester.pump();
    final IconButton fullscreenButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (Widget widget) => widget is IconButton && widget.tooltip == '进入全屏',
      ),
    );
    fullscreenButton.onPressed!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('fullscreen-focus-remaining')))
          .data,
      '02:32',
    );

    await playbackService.seekTo(const Duration(minutes: 2));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('fullscreen-focus-remaining')))
          .data,
      '01:32',
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
    expect(find.text('专注时可以自动开启勿扰'), findsOneWidget);
    await tester.tap(find.text('稍后设置'));
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
    SharedPreferences.setMockInitialValues(<String, Object>{});
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

  /// 验证网络返回弹幕时播放已前进，不会把错过的条目直接补画到屏幕中间。
  testWidgets('弹幕片段晚到后只保留当前位置及未来条目', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final Completer<DanmakuSegmentLoadResult> danmakuCompleter =
        Completer<DanmakuSegmentLoadResult>();
    final _FakePlayerOverlayService overlayService = _FakePlayerOverlayService(
      tracksResult: const SubtitleTrackLoadResult.empty(),
      cuesResult: const SubtitleCueLoadResult.empty(),
      // 延迟函数模拟片段请求期间视频从三十秒继续播放到三十五秒。
      danmakuLoader: (int segmentIndex) => danmakuCompleter.future,
    );
    final _FakePlaybackService playbackService = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview.placeholder(),
          playbackService: playbackService,
          playerOverlayService: overlayService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    playbackService.emitPosition(const Duration(seconds: 30));
    await tester.pump();
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
    await tester.pump();
    expect(overlayService.danmakuSegmentRequests, <int>[1]);

    playbackService.emitPosition(const Duration(seconds: 35));
    await tester.pump();
    danmakuCompleter.complete(
      const DanmakuSegmentLoadResult(
        status: DanmakuLoadStatus.available,
        message: '',
        segmentIndex: 1,
        entries: <DanmakuEntry>[
          DanmakuEntry(
            position: Duration(seconds: 25),
            content: '已经离屏的历史弹幕',
            color: 0xFFFFFF,
            mode: 1,
          ),
          DanmakuEntry(
            position: Duration(seconds: 32),
            content: '会从中间补画的旧弹幕',
            color: 0xFFFFFF,
            mode: 1,
          ),
          DanmakuEntry(
            position: Duration(seconds: 35),
            content: '当前位置弹幕',
            color: 0xFFFFFF,
            mode: 1,
          ),
          DanmakuEntry(
            position: Duration(seconds: 36),
            content: '未来弹幕',
            color: 0xFFFFFF,
            mode: 1,
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    final CustomPaint canvas = tester.widget<CustomPaint>(
      find.byKey(const Key('danmaku-canvas')),
    );
    final dynamic painter = canvas.painter;
    final List<DanmakuEntry> renderEntries = List<DanmakuEntry>.from(
      painter.entries as List<dynamic>,
    );
    expect(renderEntries.map((DanmakuEntry entry) => entry.content), <String>[
      '当前位置弹幕',
      '未来弹幕',
    ]);
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

  /// 验证平板横屏保留详情侧栏、顶部状态，并允许画面竖滑调节亮度和音量。
  testWidgets('平板横屏播放器使用双栏状态栏和竖滑调节', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FocusTimerController focusController = FocusTimerController(
      tickInterval: const Duration(days: 1),
    );
    addTearDown(focusController.dispose);
    await focusController.initialize();
    await focusController.startFocus(
      goal: '平板专注',
      duration: const Duration(minutes: 25),
    );
    final _FakePlaybackService playbackService = _FakePlaybackService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: playbackService,
          deviceStatusService: const _FakeDeviceStatusService(66),
          focusTimerController: focusController,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('player-workspace-layout')), findsOneWidget);
    final Scaffold playerScaffold = tester.widget<Scaffold>(
      find.byType(Scaffold).first,
    );
    expect((playerScaffold.body! as SafeArea).top, isFalse);
    expect(find.byKey(const Key('player-workspace-video')), findsOneWidget);
    expect(find.byKey(const Key('player-workspace-side-pane')), findsOneWidget);
    final Rect videoPane = tester.getRect(
      find.byKey(const Key('player-workspace-video')),
    );
    final Rect playerSurface = tester.getRect(
      find.byKey(const Key('player-surface')),
    );
    expect(playerSurface, videoPane);
    expect(videoPane.width, greaterThan(1280 * 0.7));
    expect(find.byKey(const Key('fullscreen-device-status')), findsOneWidget);
    expect(find.byKey(const Key('fullscreen-focus-status')), findsOneWidget);
    expect(find.text('66%'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    await tester.tapAt(playerSurface.center);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.dragFrom(
      Offset(playerSurface.left + 120, playerSurface.center.dy),
      const Offset(0, -160),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(playbackService.brightness, greaterThan(0.5));
    await tester.dragFrom(
      Offset(playerSurface.right - 120, playerSurface.center.dy),
      const Offset(0, -160),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(playbackService.volume, greaterThan(0.5));
    expect(find.byKey(const Key('collapsing-player-scroll')), findsNothing);
    expect(find.text('简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// 验证平板播放器的填充和拉伸选项确实改变 Texture 的 BoxFit，而不是被外层画幅抵消。
  testWidgets('平板播放器画幅选项实际切换缩放模式', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: _createCollectionVideo(),
          playbackService: _FakePlaybackService(textureId: 42),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('video-fit-contain')), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-settings-menu')));
    await tester.pump(const Duration(milliseconds: 300));
    final Finder coverItem = find.byKey(const Key('video-fit-mode-cover'));
    await tester.ensureVisible(coverItem);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(coverItem);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<FittedBox>(find.byKey(const Key('video-fit-cover'))).fit,
      BoxFit.cover,
    );

    await tester.tap(find.byKey(const Key('more-settings-menu')));
    await tester.pump(const Duration(milliseconds: 300));
    final Finder stretchItem = find.byKey(const Key('video-fit-mode-stretch'));
    await tester.ensureVisible(stretchItem);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(stretchItem);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<FittedBox>(find.byKey(const Key('video-fit-stretch'))).fit,
      BoxFit.fill,
    );
    expect(tester.takeException(), isNull);
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
