import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/enhancements/interactive_video_overlay.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/player_enhancement.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_interaction_service.dart';
import 'package:focubili/services/bilibili_player_enhancement_service.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/video_tag_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_ab_repeat_test.dart' show AbOverlay, AbPlayback, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const _duration = Duration(minutes: 2);
const _partA2 = VideoPart(
  pageNumber: 2,
  cid: 137649199,
  title: '分 P A2',
  duration: _duration,
);
const _branch = InteractiveVideoChoice(edgeId: 77, cid: 203, label: '分支 A');
const _otherBranch = InteractiveVideoChoice(
  edgeId: 78,
  cid: 204,
  label: '分支 B',
);
const _nextChoice = InteractiveVideoChoice(edgeId: 79, cid: 205, label: '继续剧情');
const _videoA = VideoPreview(
  bvid: 'BV1GJ411x7h7',
  aid: 101,
  cid: 201,
  title: '视频 A',
  ownerMid: 301,
  ownerName: '作者 A',
  parts: [
    VideoPart(pageNumber: 1, cid: 201, title: '分 P A', duration: _duration),
    _partA2,
  ],
  collection: VideoCollection(
    id: 1,
    title: '测试合集',
    entries: [
      VideoCollectionEntry(
        bvid: 'BV1GJ411x7h7',
        cid: 201,
        title: '视频 A',
        thumbnailUrl: '',
        duration: _duration,
      ),
      VideoCollectionEntry(
        bvid: 'BV1Q541167Qg',
        cid: 202,
        title: '视频 B',
        thumbnailUrl: '',
        duration: _duration,
      ),
    ],
  ),
);
const _videoB = VideoPreview(
  bvid: 'BV1Q541167Qg',
  aid: 102,
  cid: 202,
  title: '视频 B',
  ownerMid: 302,
  ownerName: '作者 B',
  parts: [
    VideoPart(pageNumber: 1, cid: 202, title: '分 P B', duration: _duration),
  ],
);
const _selected = BilibiliInteractionState(
  isFollowing: true,
  isLiked: true,
  coinCount: 2,
  isFavorited: true,
);

class _Playback extends AbPlayback {
  final openingB = Completer<void>();
  final openB = Completer<void>();
  bool failFirstBranch = false;
  Completer<void>? branchRetry;
  final branchAttempts = <int>[];

  /// 让 B 的打开独立于 A 的网络回填，测试可精确控制成功或失败的时点。
  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
    PlaybackCodecPreference? codecPreference,
    bool preferDataSaving = false,
  }) async {
    if (part?.cid == _branch.cid) {
      branchAttempts.add(part!.cid);
      if (failFirstBranch && branchAttempts.length == 1) {
        throw StateError('首次打开分支失败');
      }
      await branchRetry?.future;
      // 被后来导航取代的后端请求不再发送快照。
      if (branchRetry != null && currentCid != _videoA.cid) return;
    }
    if (video.bvid == _videoB.bvid) {
      openingB.complete();
      try {
        await openB.future;
      } on StateError {
        emit(
          current.copyWith(
            phase: PlaybackPhase.error,
            isPlaying: false,
            message: '目标播放源打开失败',
          ),
        );
        rethrow;
      }
    }
    await super.openVideo(
      video,
      part: part,
      quality: quality,
      initialPosition: initialPosition,
      codecPreference: codecPreference,
      preferDataSaving: preferDataSaving,
    );
  }
}

class _VideoDetails extends BilibiliVideoInfoService {
  /// 模拟用户从合集点击 B 后返回的完整详情。
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    expect(input, _videoB.bvid);
    return _videoB;
  }
}

class _Interactions extends BilibiliInteractionService {
  final requests = <(String, int, int)>[];
  final stateA = Completer<BilibiliInteractionState>();
  final stateB = Completer<BilibiliInteractionState>();

  /// 记录每次请求对应的稿件和作者，独立控制两支视频的账号状态。
  @override
  Future<BilibiliInteractionState> loadVideoState({
    required String bvid,
    required int aid,
    required int ownerMid,
  }) {
    requests.add((bvid, aid, ownerMid));
    return bvid == _videoA.bvid ? stateA.future : stateB.future;
  }
}

class _Enhancements extends EmptyPlayerEnhancementService {
  final chaptersA = Completer<PlayerEnhancementMetadata>();
  final chaptersB = Completer<PlayerEnhancementMetadata>();

  /// 让旧章节与旧互动同时晚到，也允许正常加载 B 自己的章节。
  @override
  Future<PlayerEnhancementMetadata> loadMetadata({
    required String bvid,
    required int cid,
  }) => bvid == _videoA.bvid ? chaptersA.future : chaptersB.future;
}

class _Story extends EmptyPlayerEnhancementService {
  final nodes = <(String, int, int?)>[];

  /// 仅稿件 A 的起始分 P 带剧情入口。
  @override
  Future<PlayerEnhancementMetadata> loadMetadata({
    required String bvid,
    required int cid,
  }) async => bvid == _videoA.bvid && cid == _videoA.cid
      ? const PlayerEnhancementMetadata(
          interaction: InteractiveVideoInfo(graphVersion: 42),
        )
      : const PlayerEnhancementMetadata();

  /// 记录版本和边编号，并返回可在完播画面辨认的后续选择。
  @override
  Future<InteractiveVideoNode> loadInteractiveNode({
    required String bvid,
    required int graphVersion,
    int? edgeId,
  }) async {
    nodes.add((bvid, graphVersion, edgeId));
    return InteractiveVideoNode(
      title: '节点',
      isLeaf: false,
      edgeId: edgeId ?? 1,
      choices: edgeId == null ? [_branch, _otherBranch] : [_nextChoice],
    );
  }
}

class _Writes extends BilibiliInteractionService {
  final writes = <(String, int)>[];
  final write = Completer<void>();
  final refresh = Completer<BilibiliInteractionState>();
  final earlierRead = Completer<BilibiliInteractionState>();
  int reads = 0;

  /// 留住 P2 的第一次读取，检验写完成触发的刷新优先回填。
  @override
  Future<BilibiliInteractionState> loadVideoState({
    required String bvid,
    required int aid,
    required int ownerMid,
  }) async => switch (++reads) {
    2 => earlierRead.future,
    3 => refresh.future,
    _ => const BilibiliInteractionState(),
  };

  /// 暂停服务端写入，允许测试在完成前切分 P。
  Future<void> _record(String action, int id) {
    writes.add((action, id));
    return write.future;
  }

  /// 记录需要防止重复提交的稿件投币。
  @override
  Future<void> addCoin({required int aid, int multiply = 1}) =>
      _record('coin', aid);

  /// 记录稿件点赞。
  @override
  Future<void> setLiked({required int aid, required bool liked}) =>
      _record('like', aid);

  /// 记录指定作者的关注。
  @override
  Future<void> setFollowing({required int mid, required bool following}) =>
      _record('follow', mid);

  /// 提供可通过实际收藏弹窗勾选的目录。
  @override
  Future<List<BilibiliFavoriteFolder>> loadFavoriteFolders({
    required int aid,
  }) async => const [BilibiliFavoriteFolder(mediaId: 81, title: '测试收藏夹')];

  /// 记录多选收藏夹提交对应的稿件。
  @override
  Future<void> setFavoriteFolders({
    required int aid,
    Iterable<int> addMediaIds = const <int>[],
    Iterable<int> deleteMediaIds = const <int>[],
  }) => _record('favorite', aid);
}

class _Tags extends _VideoDetails {
  final request = Completer<List<String>>();
  final requests = <String>[];

  /// 第一条响应由测试延迟，后续响应提供可辨认的新标签。
  @override
  Future<List<String>> loadVideoTags(String bvid) {
    requests.add(bvid);
    if (requests.length == 1) return request.future;
    return Future.value(['在线标签']);
  }
}

/// 从播放器页面打开真实控件，服务只替换网络、媒体和离线库。
Future<void> _mountPlayer(
  WidgetTester tester,
  _Playback playback, {
  BilibiliInteractionService? interactions,
  BilibiliPlayerEnhancementService? enhancements,
  BilibiliService? details,
  int? partCid,
  bool forceOffline = false,
}) async {
  final service =
      interactions ??
      (_Interactions()
        ..stateA.complete(const BilibiliInteractionState())
        ..stateB.complete(const BilibiliInteractionState()));
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: _videoA,
        initialPartCid: partCid,
        playbackService: playback,
        bilibiliService: details ?? _VideoDetails(),
        interactionService: service,
        playerEnhancementService:
            enhancements ?? EmptyPlayerEnhancementService(),
        playerOverlayService: AbOverlay(),
        offlineVideoService: ReviewOfflineLibrary(),
        forceOffline: forceOffline,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 使用竖屏播放画面展示初始剧情选项。
Future<void> _startStory(
  WidgetTester tester,
  _Playback playback,
  _Story story,
) async {
  await tester.binding.setSurfaceSize(const Size(1080, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await _mountPlayer(tester, playback, enhancements: story);
  playback.at(120, playing: false, phase: PlaybackPhase.ended);
  await tester.pumpAndSettle();
}

/// 点按页面入口，必要时滚动到详情里的按钮。
Future<void> _tap(WidgetTester tester, String key, {bool settle = true}) async {
  final target = find.byKey(Key(key)).first;
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(target);
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

/// 给指定视频产生可在播放器上辨认的章节。
PlayerEnhancementMetadata _chapter(String title) => PlayerEnhancementMetadata(
  chapters: [VideoChapter(title: title, start: Duration.zero, end: _duration)],
);

/// 通过四个实际按钮验证选中状态，并核对忙碌状态已结束。
void _expectInteractions(WidgetTester tester, {required bool selected}) {
  final labels = {
    'video-like-button': selected ? '已点赞' : '点赞',
    'video-coin-button': selected ? '已投币' : '投币',
    'video-favorite-button': selected ? '已收藏' : '收藏',
    'video-owner-follow-button': selected ? '已关注' : '关注',
  };
  for (final entry in labels.entries) {
    final button = find.byKey(Key(entry.key));
    expect(
      find.descendant(of: button, matching: find.text(entry.value)),
      findsOneWidget,
    );
    // 测试数据投满两枚后，只有投币按钮应禁用。
    expect(
      tester.widget<TextButton>(button).onPressed,
      selected && entry.key == 'video-coin-button' ? isNull : isNotNull,
    );
  }
}

/// 从实际合集入口复现旧请求在新播放源尚未打开或已经失败时回填。
void main() {
  for (final fails in [false, true]) {
    // 两条路径共用相同的 A 响应，区别只在于 B 是否已打开失败。
    testWidgets('late A metadata stays out of B (open fails: $fails)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final playback = _Playback();
      final interactions = _Interactions();
      final enhancements = _Enhancements();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            video: _videoA,
            playbackService: playback,
            bilibiliService: _VideoDetails(),
            interactionService: interactions,
            playerEnhancementService: enhancements,
            playerOverlayService: AbOverlay(),
            offlineVideoService: ReviewOfflineLibrary(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final requestA = (_videoA.bvid, _videoA.aid, _videoA.ownerMid);
      expect(interactions.requests, [requestA]);

      final collectionEntry = find.byKey(
        Key('collection-preview-${_videoB.bvid}'),
      );
      await tester.ensureVisible(collectionEntry);
      await tester.pumpAndSettle();
      await tester.tap(collectionEntry);
      await tester.pump();
      expect(playback.openingB.isCompleted, isTrue);
      expect(find.text(_videoB.ownerName), findsOneWidget);

      if (fails) {
        playback.openB.completeError(StateError('目标播放源打开失败'));
        await tester.pumpAndSettle();
        expect(playback.current.phase, PlaybackPhase.error);
      }
      interactions.stateA.complete(_selected);
      enhancements.chaptersA.complete(_chapter('旧章节 A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(interactions.requests, [requestA]);
      expect(playback.openB.isCompleted, fails);
      _expectInteractions(tester, selected: false);
      expect(find.byKey(const Key('video-chapter-strip')), findsNothing);

      if (!fails) {
        playback.openB.complete();
        await tester.pumpAndSettle();
        expect(playback.currentCid, _videoB.cid);
        expect(interactions.requests, [
          requestA,
          (_videoB.bvid, _videoB.aid, _videoB.ownerMid),
        ]);
        interactions.stateB.complete(_selected);
        enhancements.chaptersB.complete(_chapter('新章节 B'));
        await tester.pumpAndSettle();
        _expectInteractions(tester, selected: true);
        expect(find.text('新章节 B'), findsOneWidget);
      }
      await unmountAb(tester);
    });
  }

  group('player transition regressions', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('playback retry opens the selected story edge', (tester) async {
      final playback = _Playback()..failFirstBranch = true;
      final story = _Story();
      await _startStory(tester, playback, story);
      await _tap(tester, 'interactive-video-choice-0');
      expect(story.nodes, [(_videoA.bvid, 42, null)]);
      await _tap(tester, 'retry-playback');
      expect(playback.branchAttempts, [_branch.cid, _branch.cid]);
      expect(playback.currentCid, _branch.cid);
      expect(story.nodes, [(_videoA.bvid, 42, null), (_videoA.bvid, 42, 77)]);
      playback.at(120, playing: false, phase: PlaybackPhase.ended);
      await tester.pumpAndSettle();
      expect(find.text(_nextChoice.label), findsOneWidget);
      await _tap(tester, 'part-2');
      await _tap(tester, 'part-1');
      expect(story.nodes.last, (_videoA.bvid, 42, null));
      await unmountAb(tester);
    });

    for (final destination in ['part', 'video', 'branch']) {
      testWidgets('a pending story retry yields to a different $destination', (
        tester,
      ) async {
        final playback = _Playback()
          ..failFirstBranch = true
          ..branchRetry = Completer<void>();
        final story = _Story();
        await _startStory(tester, playback, story);
        final choose = tester
            .widget<InteractiveVideoChoiceOverlay>(
              find.byType(InteractiveVideoChoiceOverlay),
            )
            .onChoiceSelected;
        await _tap(tester, 'interactive-video-choice-0');
        await _tap(tester, 'retry-playback', settle: false);
        expect(playback.branchAttempts, [_branch.cid, _branch.cid]);
        switch (destination) {
          case 'part':
            await _tap(tester, 'part-2');
          case 'video':
            playback.openB.complete();
            await _tap(tester, 'collection-preview-${_videoB.bvid}');
          case 'branch':
            // 旧节点仍然有效时，模拟此前已进入事件队列的另一个选择。
            choose(_otherBranch);
            await tester.pumpAndSettle();
        }
        playback.branchRetry!.complete();
        await tester.pumpAndSettle();
        expect(playback.currentCid, switch (destination) {
          'part' => _partA2.cid,
          'video' => _videoB.cid,
          _ => _otherBranch.cid,
        });
        expect(story.nodes, [
          (_videoA.bvid, 42, null),
          if (destination == 'branch') (_videoA.bvid, 42, _otherBranch.edgeId),
        ]);
        await unmountAb(tester);
      });
    }

    for (final (action, buttonKey, label) in [
      ('coin', 'video-coin-button', '投币'),
      ('like', 'video-like-button', '点赞'),
      ('favorite', 'video-favorite-button', '收藏'),
      ('follow', 'video-owner-follow-button', '关注'),
    ]) {
      testWidgets('$action write stays locked across parts and refreshes P2', (
        tester,
      ) async {
        final playback = _Playback();
        final interactions = _Writes();
        await _mountPlayer(tester, playback, interactions: interactions);
        final button = find.byKey(Key(buttonKey));
        final originalAction = tester.widget<TextButton>(button).onPressed!;
        await _tap(
          tester,
          buttonKey,
          settle: action == 'coin' || action == 'favorite',
        );
        if (action == 'coin') {
          await _tap(tester, 'coin-option-2', settle: false);
        }
        if (action == 'favorite') {
          await _tap(tester, 'favorite-folder-81');
          await _tap(tester, 'confirm-favorite-folders', settle: false);
        }
        final target = action == 'follow' ? _videoA.ownerMid : _videoA.aid;
        expect(interactions.writes, [(action, target)]);
        await _tap(tester, 'part-2', settle: false);
        await tester.pump(const Duration(milliseconds: 350));
        expect(playback.currentCid, _partA2.cid);
        expect(interactions.reads, 2);
        expect(tester.widget<TextButton>(button).onPressed, isNull);
        expect(
          find.descendant(
            of: button,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        originalAction();
        await tester.pump();
        expect(interactions.writes, [(action, target)]);
        expect(find.byKey(const Key('coin-option-1')), findsNothing);

        interactions.write.complete();
        await tester.pumpAndSettle();
        expect(interactions.reads, 3);
        expect(
          find.descendant(of: button, matching: find.text(label)),
          findsOneWidget,
        );
        interactions.refresh.complete(_selected);
        await tester.pumpAndSettle();
        _expectInteractions(tester, selected: true);
        interactions.earlierRead.complete(const BilibiliInteractionState());
        await tester.pumpAndSettle();
        _expectInteractions(tester, selected: true);
        expect(interactions.reads, 3);
        await unmountAb(tester);
      });
    }

    testWidgets('quality menu cancels pending tags and resumes them online', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        VideoTagPreferences.key: 'expanded',
      });
      final playback = _Playback();
      final tags = _Tags();
      await _mountPlayer(tester, playback, details: tags, partCid: _partA2.cid);
      expect(tags.requests, [_videoA.bvid]);
      await _tap(tester, 'quality-menu');
      await _tap(tester, 'quality-local-cache');
      expect(playback.localOpens, 1);
      tags.request.complete(['迟到的标签']);
      await tester.pumpAndSettle();
      expect(find.text('迟到的标签'), findsNothing);
      expect(find.byKey(const Key('reveal-video-tags')), findsNothing);
      expect(tags.requests, [_videoA.bvid]);
      await _tap(tester, 'quality-menu');
      await _tap(tester, 'quality-64');
      expect(tags.requests, [_videoA.bvid, _videoA.bvid]);
      expect(find.text('在线标签'), findsOneWidget);
      await _tap(tester, 'quality-menu');
      await _tap(tester, 'quality-local-cache');
      expect(playback.localOpens, 2);
      expect(find.text('在线标签'), findsOneWidget);
      expect(tags.requests, [_videoA.bvid, _videoA.bvid]);
      await unmountAb(tester);
    });

    testWidgets('opening directly from cache does not request tags online', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        VideoTagPreferences.key: 'expanded',
      });
      final playback = _Playback();
      final tags = _Tags();
      await _mountPlayer(
        tester,
        playback,
        details: tags,
        partCid: _partA2.cid,
        forceOffline: true,
      );
      expect(playback.localOpens, 1);
      expect(tags.requests, isEmpty);
      expect(find.byKey(const Key('reveal-video-tags')), findsNothing);
      await unmountAb(tester);
    });
  });
}
