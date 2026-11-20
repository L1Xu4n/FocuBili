import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/learning_list_entry.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/watch_history_entry.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/learning_list_service.dart';
import 'package:focubili/services/watch_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_ab_repeat_test.dart' show AbOverlay, AbPlayback, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

final _videos = List.generate(7, _video);
const _storeKey = 'focubili_learning_list_v2';

VideoPreview _video(int index) => VideoPreview(
  bvid: 'BV1GJ411x7h$index',
  cid: 101 + index * 10,
  title: '合集视频 $index',
  ownerName: '课程作者',
  parts: [
    for (var p = 1; p <= 2; p++)
      VideoPart(
        pageNumber: p,
        cid: 100 + index * 10 + p,
        title: '练习 $p',
        duration: const Duration(minutes: 2),
      ),
  ],
);

class _VideoDetails extends BilibiliVideoInfoService {
  final lookedUp = <String>[];
  String? unavailableBvid;
  @override
  Future<VideoPreview> lookupVideo(String input) async {
    lookedUp.add(input);
    if (input == unavailableBvid) throw StateError('detail unavailable');
    return _videos.firstWhere((video) => video.bvid == input);
  }
}

Finder _row(int index) =>
    find.byKey(ValueKey('collection-sheet-${_videos[index].bvid}'));
Finder _checkbox(int index) =>
    find.descendant(of: _row(index), matching: find.byType(Checkbox));
Finder get _save => find.byKey(const Key('save-collection-learning-selection'));
Finder get _confirm =>
    find.byKey(const Key('confirm-collection-learning-changes'));
Finder get _cancel =>
    find.byKey(const Key('cancel-collection-learning-selection'));

bool? _checked(WidgetTester tester, int index) =>
    tester.widget<Checkbox>(_checkbox(index)).value;

Future<void> _sweep(WidgetTester tester, int start, int end) async {
  final gesture = await tester.startGesture(tester.getCenter(_checkbox(start)));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await gesture.moveTo(tester.getCenter(_checkbox(end)));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

class _Fixture {
  final learning = LearningListService();
  final details = _VideoDetails();
  final playback = AbPlayback();

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = _videos.first;
    final videos = _videos.take(6);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          video: VideoPreview(
            bvid: first.bvid,
            cid: first.cid,
            title: first.title,
            ownerName: first.ownerName,
            parts: first.parts,
            collection: VideoCollection(
              id: 1,
              title: '六支练习视频',
              entries: [
                for (final video in videos)
                  VideoCollectionEntry(
                    bvid: video.bvid,
                    cid: video.cid,
                    title: video.title,
                    thumbnailUrl: '',
                    duration: video.duration,
                  ),
              ],
              totalCount: videos.length,
            ),
          ),
          playbackService: playback,
          learningListService: learning,
          bilibiliService: details,
          offlineVideoService: ReviewOfflineLibrary(),
          playerOverlayService: AbOverlay(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('video-collection-card'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
  }

  Future<String?> rawList() async =>
      (await SharedPreferences.getInstance()).getString(_storeKey);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('经行内按钮进入时清空搜索并预勾选已有分 P；取消和返回都不写入', (tester) async {
    final f = _Fixture();
    await f.learning.addVideo(
      _videos[0],
      part: _videos[0].parts[1],
      position: const Duration(seconds: 18),
    );
    final before = await f.rawList();
    await f.open(tester);
    final search = find.byKey(const Key('collection-search-field'));
    await tester.enterText(search, _videos[3].bvid);
    await tester.pumpAndSettle();
    expect(_row(0), findsNothing);
    expect(_row(3), findsOneWidget);
    await tester.tap(
      find.byKey(Key('add-learning-collection-sheet-${_videos[3].bvid}')),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(find.text('已选 2/6'), findsOneWidget);
    expect(_checked(tester, 0), isTrue, reason: '该视频只保存了非当前分 P');
    expect(_checked(tester, 3), isTrue, reason: '行内操作选中发起条目');
    expect(_checked(tester, 5), isFalse);
    await tester.tap(_row(0));
    await tester.tap(_checkbox(5));
    expect(await f.rawList(), before);
    expect(f.details.lookedUp, isEmpty);
    await tester.tap(_cancel);
    await tester.pumpAndSettle();
    expect(find.text('管理学习清单'), findsNothing);
    expect(_row(0), findsOneWidget);
    expect(await f.rawList(), before);

    await tester.longPress(_row(0));
    await tester.pumpAndSettle();
    expect(_checked(tester, 0), isTrue);
    expect(_checked(tester, 3), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('管理学习清单'), findsNothing);
    expect(_row(0), findsOneWidget);
    expect(await f.rawList(), before);
    expect(f.playback.currentCid, _videos[0].cid);
    await unmountAb(tester);
  });

  testWidgets('长按复选框成片增删，仅保存改动并保留原分 P、进度和分组', (tester) async {
    final f = _Fixture();
    final folder = (await f.learning.createFolder('原分组')).folders.single;
    await f.learning.addBatch([
      LearningPartSelection(_videos[0], _videos[0].parts[1]),
      LearningPartSelection(
        _videos[1],
        _videos[1].parts[1],
        position: const Duration(seconds: 47),
        status: LearningListStatus.completed,
      ),
      for (final part in _videos[2].parts)
        LearningPartSelection(_videos[2], part),
      LearningPartSelection(_videos[3], _videos[3].parts[1]),
      LearningPartSelection(
        _videos[6],
        _videos[6].parts[1],
        position: const Duration(seconds: 53),
      ),
    ], folderId: folder.id);
    await WatchHistoryService().record(
      WatchHistoryEntry(
        bvid: _videos[4].bvid,
        title: _videos[4].title,
        ownerName: _videos[4].ownerName,
        lastPartTitle: _videos[4].parts[1].title,
        lastPartPageNumber: 2,
        lastPosition: const Duration(seconds: 17),
        watchedAt: DateTime(2026, 11, 18),
      ),
    );
    final before = await f.rawList();
    final old = {
      for (final entry in await f.learning.loadEntries())
        entry.bvid: entry.toJson(),
    };
    await f.open(tester);
    await tester.longPress(_row(0));
    await tester.pumpAndSettle();
    expect(find.text('已选 4/6'), findsOneWidget);
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);

    await _sweep(tester, 2, 3);
    expect(_checked(tester, 2), isFalse);
    expect(_checked(tester, 3), isFalse);
    await _sweep(tester, 4, 5);
    expect(_checked(tester, 4), isTrue);
    expect(_checked(tester, 5), isTrue);
    expect(find.text('待加入 2 支 · 待移出 2 支'), findsOneWidget);
    expect(await f.rawList(), before);
    expect(f.details.lookedUp, isEmpty);
    // Selection is by BV, not by the currently visible search result.
    await tester.enterText(
      find.byKey(const Key('collection-search-field')),
      _videos[5].bvid,
    );
    await tester.pumpAndSettle();
    expect(_row(1), findsNothing);
    expect(find.text('待加入 2 支 · 待移出 2 支'), findsOneWidget);

    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(find.text('移出 2 支视频？'), findsOneWidget);
    expect(await f.rawList(), before);
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    expect(await f.rawList(), before);

    await tester.tap(_save);
    await tester.pumpAndSettle();
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(find.text('学习清单已保存'), findsOneWidget);
    expect(f.details.lookedUp, [_videos[4].bvid, _videos[5].bvid]);
    final entries = {
      for (final entry in await f.learning.loadEntries()) entry.bvid: entry,
    };
    expect(entries.keys.toSet(), {
      for (final i in [0, 1, 4, 5, 6]) _videos[i].bvid,
    });
    final persisted = await f.learning.loadEntries();
    expect(persisted.any((e) => e.bvid == _videos[2].bvid), isFalse);
    for (final i in [0, 1, 6]) {
      expect(entries[_videos[i].bvid]!.toJson(), old[_videos[i].bvid]);
    }
    expect(entries[_videos[4].bvid]!.partCid, _videos[4].parts[1].cid);
    expect(entries[_videos[4].bvid]!.position.inSeconds, 17);
    expect(entries[_videos[5].bvid]!.partCid, _videos[5].initialPart.cid);
    expect(f.playback.currentCid, _videos[0].cid);
    await unmountAb(tester);
  });

  testWidgets('详情读取失败不移除原任务；取消后普通点击照常播放', (tester) async {
    final f = _Fixture();
    await f.learning.addVideo(_videos[0], part: _videos[0].parts[1]);
    final before = await f.rawList();
    f.details.unavailableBvid = _videos[1].bvid;
    await f.open(tester);
    await tester.longPress(_row(1));
    await tester.pumpAndSettle();
    await tester.tap(_checkbox(0));
    await tester.pumpAndSettle();
    await tester.tap(_save);
    await tester.pumpAndSettle();
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(find.textContaining('未保存：无法读取'), findsOneWidget);
    expect(find.text('学习清单已保存'), findsNothing);
    expect(await f.rawList(), before);
    expect(f.playback.currentCid, _videos[0].cid);

    await tester.tap(_cancel);
    await tester.pumpAndSettle();
    f.details.unavailableBvid = null;
    await tester.tap(_row(1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('collection-sheet-list')), findsNothing);
    expect(f.playback.currentCid, _videos[1].cid);
    await unmountAb(tester);
  });
}
