import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/app.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/profile/login_page.dart';
import 'package:focubili/features/search/search_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/search_history_service.dart';

/// 记录视频详情请求地址并返回固定 JSON，验证服务解析时不依赖真实网络。
class _RecordingJsonRequest {
  Uri? requestedUri;

  /// 保存服务请求的地址，并返回一份最小的公开视频详情响应。
  Future<String> call(Uri uri) async {
    requestedUri = uri;
    return '''
      {
        "code": 0,
        "message": "0",
        "data": {
          "bvid": "BV1GJ411x7h7",
          "cid": 137649199,
          "title": "真实接口标题",
          "duration": 213,
          "owner": {"name": "真实接口 UP 主"},
          "pages": [
            {"page": 1, "cid": 137649199, "part": "第一P", "duration": 120},
            {"page": 2, "cid": 137649200, "part": "第二P", "duration": 93}
          ]
        }
      }
    ''';
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
  _FakePlaybackService({this.savedState, this.rejectQuality = false});

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  static const Duration _duration = Duration(minutes: 3, seconds: 32);
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
  int pictureInPictureRequests = 0;
  int seekByRequests = 0;
  int seekToRequests = 0;
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
    _emit();
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
    _isPlaying = false;
    _emit();
  }

  /// 模拟按相对时长快进或快退，并把位置限制在视频有效范围内。
  @override
  Future<void> seekBy(Duration offset) async {
    seekByRequests += 1;
    final int nextMilliseconds =
        (_position.inMilliseconds + offset.inMilliseconds)
            .clamp(0, _duration.inMilliseconds)
            .toInt();
    _position = Duration(milliseconds: nextMilliseconds);
    _emit();
  }

  /// 模拟跳转到给定位置，并把位置限制在视频有效范围内。
  @override
  Future<void> seekTo(Duration position) async {
    seekToRequests += 1;
    _position = Duration(
      milliseconds:
          position.inMilliseconds.clamp(0, _duration.inMilliseconds).toInt(),
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
  void _emit({PlaybackPhase phase = PlaybackPhase.ready, String? message}) {
    _states.add(
      PlaybackSnapshot(
        phase: phase,
        isPlaying: _isPlaying,
        position: _position,
        duration: _duration,
        speed: _speed,
        currentQuality: _quality,
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

  /// 关闭测试使用的状态流，模拟页面离开时释放播放器。
  @override
  Future<void> dispose() => _states.close();
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

/// 验证应用能够显示首页、搜索入口和底部一级导航。
void main() {
  /// 验证公开详情服务能解析 BV 号、标题、UP 主、时长和多P列表。
  test('公开视频详情服务能解析 BV 链接', () async {
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
    expect(results.single.duration,
        const Duration(hours: 1, minutes: 2, seconds: 3));
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

    final Rect playerBounds =
        tester.getRect(find.byKey(const Key('player-surface')));
    final Offset rightTap =
        Offset(playerBounds.right - 12, playerBounds.center.dy);
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
  });

  /// 验证播放错误显示重试入口，重复点击只会发起一次请求且保留当前分P与清晰度。
  testWidgets('播放错误重试只请求一次并保留分P和清晰度', (
    WidgetTester tester,
  ) async {
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

    await tester.tap(find.byKey(const Key('part-2')));
    await tester.pumpAndSettle();

    expect(service.openedCid, 137649200);
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
    expect(find.textContaining('已跳转到上次分P'), findsNothing);
  });

  /// 验证播放中长按画面会临时使用二倍速，松手后恢复原速度。
  testWidgets('长按播放画面临时切换二倍速', (WidgetTester tester) async {
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

    expect(service._speed, 2);
    expect(find.text('二倍速中>>'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    expect(service._speed, 1);
    expect(find.text('二倍速中>>'), findsNothing);
  });

  /// 验证长按横向移动只在松手时提交一次进度跳转，并恢复原本播放倍速。
  testWidgets('长按横向拖动可以预览并一次性跳转进度', (
    WidgetTester tester,
  ) async {
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
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();

    expect(service.seekToRequests, 0);
    expect(service._speed, 1);
    expect(find.text('跳转至 0:30'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(service.seekToRequests, 1);
    expect(service._position, const Duration(seconds: 30));
    expect(service._speed, 1);
  });

  /// 验证长按跳转超过单次上限时会被限制为两分钟，避免长视频一次跳到不可控位置。
  testWidgets('长按横向拖动会限制单次快捷跳转范围', (
    WidgetTester tester,
  ) async {
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
    await gesture.moveBy(const Offset(2000, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(service._position, const Duration(minutes: 2));
    expect(service.seekToRequests, 1);
  });

  /// 验证系统取消长按时会恢复播放速度，且不会把预览位置写入原生播放器。
  testWidgets('取消长按跳转不会写入预览进度', (WidgetTester tester) async {
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
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(service.seekToRequests, 0);
    expect(service._position, Duration.zero);
    expect(service._speed, 1);
  });

  /// 验证暂停时控制栏不会因旧计时器自动隐藏，继续播放后才恢复五秒自动收起。
  testWidgets('暂停时控制栏保持显示，播放时才自动隐藏', (
    WidgetTester tester,
  ) async {
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
  testWidgets('全屏竖滑会避开顶部和底部系统手势区', (
    WidgetTester tester,
  ) async {
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

  /// 验证超长分P标题使用独立两行竖向组件，展开选集后也不会触发布局异常。
  testWidgets('分P超长标题在折叠和展开列表中保持可用', (
    WidgetTester tester,
  ) async {
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
    await tester.tap(find.text('展开'));
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

  /// 验证输入法压缩搜索页面时，固定控件和空状态都不会产生黄黑溢出标记。
  testWidgets('搜索输入法出现时页面不会布局溢出', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: const EdgeInsets.only(bottom: 280),
            ),
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

    final Rect fieldRect = tester.getRect(find.byType(TextField));
    final Rect resultRect = tester.getRect(
      find.byKey(const Key('search-result-overlay')),
    );
    expect(resultRect.top - fieldRect.bottom, lessThanOrEqualTo(1));
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
