import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/video_note.dart';
import 'package:focubili/services/live_video_frame_playback_service.dart';
import 'package:focubili/services/video_note_service.dart';
import 'player_ab_repeat_test.dart'
    show AbPlayback, AbOverlay, abVideo, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const _append = Key('append-video-note-frame');
const _title = Key('note-title-field');
const _body = Key('note-body-field');

class _CapturePlayback extends AbPlayback
    implements LiveVideoFramePlaybackService {
  final result = Completer<LiveVideoFrame?>();
  int legacyCaptures = 0;
  int liveCaptures = 0;

  @override
  Future<String?> captureCurrentFrame() async {
    legacyCaptures++;
    return (await result.future)?.path;
  }

  @override
  Future<LiveVideoFrame?> captureLiveVideoFrame() {
    liveCaptures++;
    return result.future;
  }
}

class _Notes extends VideoNoteService {
  final discarded = <String>[];
  bool failAttachments = false;

  @override
  Future<void> saveNote(VideoNote note) async {
    if (failAttachments && note.allFrames.isNotEmpty) {
      throw StateError('fixture refuses attachment writes');
    }
    return super.saveNote(note);
  }

  @override
  Future<void> discardUnreferencedFrame(String path) async {
    discarded.add(path);
  }
}

LiveVideoFrame _sample({int cid = 101}) => LiveVideoFrame(
  path: '/synthetic/live-note.png',
  position: const Duration(milliseconds: 30240),
  bvid: abVideo.bvid,
  cid: cid,
);

Future<void> _mount(
  WidgetTester tester,
  _CapturePlayback p,
  _Notes notes, {
  Size viewport = const Size(480, 900),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: abVideo,
        playbackService: p,
        videoNoteService: notes,
        initialPosition: const Duration(seconds: 20),
        offlineVideoService: ReviewOfflineLibrary(),
        playerOverlayService: AbOverlay(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('portrait-note-button')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(_title), 'Capture note');
  await tester.enterText(find.byKey(_body), 'Original draft');
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pumpAndSettle();
  p.at(30);
  await tester.pump();
}

Future<void> _appendFrame(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_append));
  await tester.pump();
  await tester.tap(find.byKey(_append));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('appending reads the playing frame without native control calls', (
    tester,
  ) async {
    final p = _CapturePlayback();
    final notes = _Notes();
    await _mount(tester, p, notes);
    await _appendFrame(tester);
    debugPrint(
      'Append request: live=${p.liveCaptures}, legacy=${p.legacyCaptures}, pause=${p.pauses}, plays=${p.plays}, seeks=${p.seeks}, opens=${p.onlineOpens}',
    );
    expect(p.liveCaptures, 1);
    expect(p.legacyCaptures, 0);
    expect(p.pauses, 0);
    expect(p.plays, 0);
    expect(p.seeks, isEmpty);
    expect(p.onlineOpens, 1);
    expect(p.current.isPlaying, isTrue);
    p.at(33);
    await tester.enterText(find.byKey(_body), 'Edited during capture');
    await tester.pump(const Duration(milliseconds: 950));
    await tester.pumpAndSettle();
    expect((await notes.loadNotes()).single.body, 'Edited during capture');

    p.result.complete(_sample());
    await tester.pumpAndSettle();
    final note = (await notes.loadNotes()).single;
    expect(note.position, const Duration(seconds: 20));
    expect(note.allFrames.single.position, _sample().position);
    expect(p.current.position, const Duration(seconds: 33));
    expect(p.current.isPlaying, isTrue);
    expect(p.seeks, isEmpty);
    expect(p.pauses, 0);
    expect(p.plays, 0);
    expect(p.onlineOpens, 1);
    await unmountAb(tester);
  });

  testWidgets(
    'wide inline notes attach the playing frame to the draft anchor',
    (tester) async {
      final p = _CapturePlayback();
      final notes = _Notes();
      await _mount(tester, p, notes, viewport: const Size(1024, 560));
      expect(
        find.descendant(
          of: find.byKey(const Key('player-workspace-side-pane')),
          matching: find.byKey(_body),
        ),
        findsOneWidget,
      );
      await _appendFrame(tester);
      expect(p.liveCaptures, 1);
      p.result.complete(_sample());
      await tester.pumpAndSettle();
      final note = (await notes.loadNotes()).single;
      expect(note.position, const Duration(seconds: 20));
      expect(note.allFrames.single.position, _sample().position);
      expect(p.current.isPlaying, isTrue);
      expect(p.seeks, isEmpty);
      expect(p.pauses, 0);
      await unmountAb(tester);
    },
  );

  for (final invalidMedia in [false, true]) {
    testWidgets(
      'unavailable or wrong-CID capture preserves text: wrong CID=$invalidMedia',
      (tester) async {
        final p = _CapturePlayback();
        final notes = _Notes();
        await _mount(tester, p, notes);
        await _appendFrame(tester);
        p.result.complete(invalidMedia ? _sample(cid: 102) : null);
        await tester.pumpAndSettle();
        final note = (await notes.loadNotes()).single;
        expect(note.body, 'Original draft');
        expect(note.allFrames, isEmpty);
        expect(notes.discarded, invalidMedia ? [_sample().path] : isEmpty);
        expect(find.text('当前画面无法截取，笔记文字已保存。'), findsOneWidget);
        expect(p.seeks, isEmpty);
        expect(p.current.isPlaying, isTrue);
        await unmountAb(tester);
      },
    );
  }

  testWidgets('changing P does not await capture or keep a late frame', (
    tester,
  ) async {
    final p = _CapturePlayback();
    final notes = _Notes();
    await _mount(tester, p, notes);
    await _appendFrame(tester);
    await tester.tap(find.byKey(const Key('next-part-button')));
    await tester.pumpAndSettle();
    expect(p.currentCid, 102);
    expect(p.onlineOpens, 2);
    expect(p.seeks, isEmpty);
    p.result.complete(_sample());
    await tester.pumpAndSettle();
    expect((await notes.loadNotes()).single.allFrames, isEmpty);
    expect(notes.discarded, [_sample().path]);
    expect(p.seeks, isEmpty);
    await unmountAb(tester);
  });

  testWidgets(
    'failed frame storage is not shown or committed as a note attachment',
    (tester) async {
      final p = _CapturePlayback();
      final notes = _Notes()..failAttachments = true;
      await _mount(tester, p, notes);
      await _appendFrame(tester);
      p.result.complete(_sample());
      await tester.pumpAndSettle();
      expect((await notes.loadNotes()).single.allFrames, isEmpty);
      expect(notes.discarded, [_sample().path]);
      expect(find.text('保存笔记失败，请稍后再试。'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_append)).onPressed,
        isNotNull,
      );
      expect(p.seeks, isEmpty);
      await unmountAb(tester);
    },
  );

  testWidgets(
    'deleting a note cancels the live request and never resurrects it',
    (tester) async {
      final p = _CapturePlayback();
      final notes = _Notes();
      await _mount(tester, p, notes);
      await _appendFrame(tester);
      final delete = find.byKey(const Key('delete-video-note'));
      await tester.ensureVisible(delete);
      await tester.pump();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(await notes.loadNotes(), isEmpty);
      p.result.complete(_sample());
      await tester.pumpAndSettle();
      expect(await notes.loadNotes(), isEmpty);
      expect(notes.discarded, [_sample().path]);
      expect(p.seeks, isEmpty);
      await unmountAb(tester);
    },
  );
}
