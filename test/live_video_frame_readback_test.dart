import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/services/flutter_video_frame_capture.dart';
import 'package:focubili/services/live_video_frame_playback_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/playback_video_surface.dart';
import 'package:focubili/services/video_note_service.dart';
import 'player_ab_repeat_test.dart'
    show AbOverlay, AbPlayback, abVideo, unmountAb;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const _media = String.fromEnvironment('NOTE_CAPTURE_MEDIA_DIR');

class _DecodedFixturePlayback extends AbPlayback
    implements PlaybackVideoSurface {
  _DecodedFixturePlayback(this.image);
  final ValueNotifier<ui.Image> image;
  final capture = FlutterVideoFrameCapture();
  final response = Completer<LiveVideoFrame?>();
  int requests = 0;

  @override
  Widget buildVideoSurface() => capture.wrap(
    ValueListenableBuilder<ui.Image>(
      valueListenable: image,
      builder: (context, value, _) => RawImage(image: value, fit: BoxFit.fill),
    ),
  );

  @override
  Future<LiveVideoFrame?> captureLiveVideoFrame() {
    requests++;
    return response.future;
  }

  Future<LiveVideoFrame?> copyPendingFrame() async {
    final sampled = await capture.captureLivePng(
      readPosition: () => current.position,
      isCurrent: () => currentCid == 101 && current.isPlaying,
    );
    if (sampled == null) return null;
    final file = File('$_media/captured-from-player.png');
    await file.writeAsBytes(sampled.bytes);
    return LiveVideoFrame(
      bvid: abVideo.bvid,
      cid: 101,
      position: sampled.position,
      path: file.path,
    );
  }
}

Future<ui.Image> _loadImage(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android live channel returns backend time and does not send playback commands',
    () async {
      const channel = MethodChannel('com.focubili.app/playback');
      final methods = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return call.method == 'captureLiveVideoFrame'
            ? {
                'path': '/fixture/frame.jpg',
                'bvid': abVideo.bvid,
                'cid': 101,
                'positionMs': 30239,
              }
            : null;
      });
      final service = NativePlaybackService();
      final captured = await service.captureLiveVideoFrame();
      expect(captured?.position, const Duration(milliseconds: 30239));
      expect(captured?.cid, 101);
      expect(captured?.bvid, abVideo.bvid);
      expect(methods, ['captureLiveVideoFrame']);
      await service.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    },
  );

  for (final (color, before, after) in [
    (Colors.black, 3000, 3000),
    (Colors.transparent, 3000, 3000),
    (Colors.green, 3000, 3510),
    (Colors.green, 3000, 2999),
  ]) {
    testWidgets(
      'invalid live read discarded: ${color.toARGB32()} $before→$after',
      (tester) async {
        final capture = FlutterVideoFrameCapture();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: capture.wrap(ColoredBox(color: color)),
          ),
        );
        final positions = [before, after].iterator;
        final pending = tester.runAsync(
          () => capture.captureLivePng(
            readPosition: () {
              positions.moveNext();
              return Duration(milliseconds: positions.current);
            },
            isCurrent: () => true,
          ),
        );
        await tester.pump();
        expect(await pending, isNull);
      },
    );
  }

  testWidgets(
    'decoded MP4 frames through PlayerPage produce the green 3s frame with no transport mutation',
    skip: _media.isEmpty,
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final images = (await tester.runAsync(
        () => Future.wait([
          for (final second in [1, 3, 5])
            _loadImage('$_media/frame-$second.png'),
        ]),
      ))!;
      final image = ValueNotifier(images.first);
      final playback = _DecodedFixturePlayback(image);
      final notes = VideoNoteService();
      tester.view.physicalSize = const Size(480, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            video: abVideo,
            initialPosition: const Duration(seconds: 1),
            playbackService: playback,
            offlineVideoService: ReviewOfflineLibrary(),
            playerOverlayService: AbOverlay(),
            videoNoteService: notes,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('portrait-note-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('note-title-field')),
        'MP4 live frame',
      );
      playback.at(3);
      image.value = images[1];
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('append-video-note-frame'));
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      expect(playback.requests, 1);
      // Run engine/file work in real async, then deliver the captured payload
      // to the fake-clock PlayerPage in its own zone.
      final pending = tester.runAsync(
        () => playback.copyPendingFrame().timeout(const Duration(seconds: 8)),
      );
      await tester.pump();
      final sampled = await pending;
      expect(sampled, isNotNull);
      playback.response.complete(sampled);
      await tester.pumpAndSettle();
      playback.at(5);
      image.value = images[2];
      await tester.pumpAndSettle();

      final frame = (await notes.loadNotes()).single.allFrames.single;
      expect(frame.position, const Duration(seconds: 3));
      final captured = (await tester.runAsync(() => _loadImage(frame.path)))!;
      final rgba = (await tester.runAsync(
        () => captured.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final center =
          ((captured.height ~/ 2) * captured.width + captured.width ~/ 2) * 4;
      expect(rgba.getUint8(center), lessThan(24));
      expect(rgba.getUint8(center + 1), greaterThan(225));
      expect(rgba.getUint8(center + 2), lessThan(24));
      expect(playback.current.isPlaying, isTrue);
      expect(playback.current.position, const Duration(seconds: 5));
      expect(playback.pauses, 0);
      expect(playback.plays, 0);
      expect(playback.seeks, isEmpty);
      expect(playback.onlineOpens, 1);
      debugPrint(
        'captured green MP4 frame at ${frame.position} (${captured.width}×${captured.height}); player later at ${playback.current.position}',
      );
      captured.dispose();
      await unmountAb(tester);
      image.dispose();
      for (final frame in images) {
        frame.dispose();
      }
    },
  );
}
