import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/live_video_frame_playback_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'player_ab_repeat_test.dart' show AbPlayback, AbOverlay, abVideo;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const _body = Key('note-body-field');
const _title = Key('note-title-field');
const _append = Key('append-video-note-frame');
const _delete = Key('delete-video-note');
const _originalFrame = VideoNoteFrame(
  path: '/fixture/original.png',
  position: Duration(seconds: 7),
);
const _liveFrame = VideoNoteFrame(
  path: '/fixture/live.png',
  position: Duration(seconds: 32),
);

const _nextVideo = VideoPreview(
  bvid: 'BV1Q541167Qg',
  cid: 301,
  title: 'Other video',
  ownerName: 'Other uploader',
  parts: [
    VideoPart(
      pageNumber: 1,
      cid: 301,
      title: 'Other part',
      duration: Duration(minutes: 2),
    ),
  ],
);

VideoNote _existing({bool image = true}) => VideoNote(
  id: 'already-on-disk',
  bvid: abVideo.bvid,
  videoTitle: abVideo.title,
  ownerName: abVideo.ownerName,
  partCid: 101,
  partPageNumber: 1,
  partTitle: abVideo.parts.first.title,
  title: 'Existing title',
  body: 'Original body',
  createdAt: DateTime(2020),
  updatedAt: DateTime(2020),
  position: const Duration(seconds: 7),
  frames: image ? const [_originalFrame] : const [],
);

class _GatedStore extends VideoNoteService {
  _GatedStore({this.commitBeforeGate = false, this.failFirst = false});
  final bool commitBeforeGate;
  final bool failFirst;
  final firstWrite = Completer<VideoNote>();
  final release = Completer<void>();
  final removed = <String>[];

  Future<void> seed(VideoNote note) => super.saveNote(note);

  @override
  Future<void> saveNote(VideoNote note) async {
    if (firstWrite.isCompleted) return super.saveNote(note);
    if (commitBeforeGate) await super.saveNote(note);
    firstWrite.complete(note);
    await release.future;
    if (failFirst) throw StateError('preference write rejected');
    if (!commitBeforeGate) await super.saveNote(note);
  }

  @override
  Future<void> discardUnreferencedFrame(String path) async {
    removed.add(path);
  }
}

class _LivePlayback extends AbPlayback {
  @override
  Future<LiveVideoFrame?> captureLiveVideoFrame() async => LiveVideoFrame(
    path: _liveFrame.path,
    position: _liveFrame.position,
    bvid: abVideo.bvid,
    cid: 101,
  );
}

Future<void> _open(
  WidgetTester tester,
  _GatedStore store, {
  required bool existing,
  bool image = true,
  VideoPreview video = abVideo,
}) async {
  if (existing) await store.seed(_existing(image: image));
  tester.view.physicalSize = const Size(480, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: video,
        playbackService: _LivePlayback(),
        videoNoteService: store,
        initialPosition: const Duration(seconds: 20),
        offlineVideoService: ReviewOfflineLibrary(),
        playerOverlayService: AbOverlay(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('portrait-note-button')));
  await tester.pumpAndSettle();
  if (existing) {
    final row = find.byKey(const Key('portrait-video-note-already-on-disk'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
  } else {
    await tester.enterText(find.byKey(_title), 'First draft title');
  }
}

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  expect(find.byType(PlayerPage), findsNothing);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final existing in [true, false]) {
    testWidgets(
      'last edit survives disposal during first write (existing=$existing)',
      (tester) async {
        final notes = _GatedStore();
        await _open(tester, notes, existing: existing);
        await tester.enterText(find.byKey(_body), 'Older in-flight body A');
        await tester.pump(const Duration(milliseconds: 900));
        final older = await notes.firstWrite.future;
        expect(older.body, 'Older in-flight body A');

        await tester.enterText(find.byKey(_title), 'Final title B');
        await tester.enterText(find.byKey(_body), '  Final draft body B');
        await _leave(tester);
        notes.release.complete();
        await tester.pumpAndSettle();

        final saved = (await notes.loadNotes()).single;
        debugPrint('existing=$existing id=${saved.id} body=${saved.body}');
        expect(saved.body, '  Final draft body B');
        expect(saved.title, 'Final title B');
        expect(saved.id, older.id);
        expect(saved.createdAt.isAtSameMomentAs(older.createdAt), isTrue);
        expect(saved.bvid, abVideo.bvid);
        expect(saved.partCid, 101);
        expect(saved.position, Duration(seconds: existing ? 7 : 20));
        expect(saved.allFrames, existing ? [_originalFrame] : isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'detached draft remains bound to its old video when a new player saves',
    (tester) async {
      final notes = _GatedStore();
      await _open(tester, notes, existing: false);
      await tester.enterText(find.byKey(_body), 'Old video started');
      await tester.pump(const Duration(milliseconds: 900));
      final older = await notes.firstWrite.future;
      await tester.enterText(find.byKey(_body), 'Old video latest');
      await _leave(tester);

      await _open(tester, notes, existing: false, video: _nextVideo);
      await tester.enterText(find.byKey(_body), 'New video independent');
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect((await notes.loadNotes()).single.bvid, _nextVideo.bvid);
      notes.release.complete();
      await tester.pumpAndSettle();

      final saved = {
        for (final note in await notes.loadNotes()) note.bvid: note,
      };
      expect(saved.length, 2);
      expect(saved[older.bvid]?.id, older.id);
      expect(saved[older.bvid]?.body, 'Old video latest');
      expect(saved[_nextVideo.bvid]?.body, 'New video independent');
      await _leave(tester);
    },
  );

  testWidgets('final draft keeps local text when first new-note write fails', (
    tester,
  ) async {
    final notes = _GatedStore(failFirst: true);
    await _open(tester, notes, existing: false);
    await tester.enterText(find.byKey(_body), 'Rejected first write');
    await tester.pump(const Duration(milliseconds: 900));
    final older = await notes.firstWrite.future;
    await tester.enterText(find.byKey(_body), 'Retry this final version');
    await _leave(tester);
    notes.release.complete();
    await tester.pumpAndSettle();
    final saved = (await notes.loadNotes()).single;
    expect(saved.body, 'Retry this final version');
    expect(saved.id, older.id);
  });

  for (final action in [
    'delete',
    'external edit',
    'equal-clock edit',
    'account change',
  ]) {
    testWidgets('terminal draft does not write across $action', (tester) async {
      final notes = _GatedStore(commitBeforeGate: true);
      await _open(tester, notes, existing: true, image: false);
      await tester.enterText(find.byKey(_body), 'First commit');
      await tester.pump(const Duration(milliseconds: 900));
      final older = await notes.firstWrite.future;
      await tester.enterText(
        find.byKey(_body),
        'Must not publish across boundary',
      );
      await _leave(tester);
      if (action == 'delete') {
        await notes.deleteNote(older.id);
      } else if (action == 'external edit' || action == 'equal-clock edit') {
        await notes.seed(
          older.copyWith(
            body: 'Newer external editor',
            updatedAt: action == 'equal-clock edit'
                ? older.updatedAt
                : older.updatedAt.add(const Duration(seconds: 1)),
          ),
        );
      } else {
        CacheLifecycle.accountChanged();
      }
      notes.release.complete();
      await tester.pumpAndSettle();
      final saved = await notes.loadNotes();
      if (action == 'delete') {
        expect(saved, isEmpty);
      } else {
        expect(
          saved.single.body,
          action.endsWith('edit') ? 'Newer external editor' : 'First commit',
        );
      }
    });
  }

  for (final fail in [false, true]) {
    testWidgets(
      'publish latest text while live image save settles (fails=$fail)',
      (tester) async {
        final notes = _GatedStore(failFirst: fail);
        await _open(tester, notes, existing: true);
        final append = find.byKey(_append);
        await tester.ensureVisible(append);
        await tester.tap(append);
        await tester.pump();
        final older = await notes.firstWrite.future;
        expect(older.allFrames, [_originalFrame, _liveFrame]);
        await tester.enterText(find.byKey(_body), 'Edit during image write');
        await _leave(tester);
        notes.release.complete();
        await tester.pumpAndSettle();
        final updated = (await notes.loadNotes()).single;
        expect(updated.body, 'Edit during image write');
        expect(
          updated.allFrames,
          fail ? [_originalFrame] : [_originalFrame, _liveFrame],
        );
        expect(notes.removed, fail ? [_liveFrame.path] : isEmpty);
      },
    );
  }

  testWidgets(
    'confirmed delete finishes after the page is closed during an old save',
    (tester) async {
      final notes = _GatedStore();
      await _open(tester, notes, existing: true, image: false);
      await tester.enterText(
        find.byKey(_body),
        'Changed seconds before deletion',
      );
      final delete = find.byKey(_delete);
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.text('删除笔记'), findsWidgets);
      await tester.pump(const Duration(milliseconds: 900));
      expect(notes.firstWrite.isCompleted, isTrue);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump(const Duration(milliseconds: 250));
      await _leave(tester);
      notes.release.complete();
      await tester.pumpAndSettle();
      expect(await notes.loadNotes(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
