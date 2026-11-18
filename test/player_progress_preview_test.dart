import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/video_shot_service.dart';

import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;

const _duration = Duration(hours: 2, minutes: 50, seconds: 3);
const _first = VideoPart(
  pageNumber: 1,
  cid: 1,
  title: '第 1 P',
  duration: _duration,
);
const _second = VideoPart(
  pageNumber: 2,
  cid: 2,
  title: '第 2 P',
  duration: Duration(minutes: 3),
);
const _video = VideoPreview(
  bvid: 'BV1YkR1BXEPd',
  cid: 1,
  title: '长视频预览合成夹具',
  ownerName: '示例',
  duration: _duration,
  parts: [_first, _second],
);
const _early = 'https://i0.hdslb.com/preview-early.png';
const _tail = 'https://i0.hdslb.com/preview-tail.png';
const _newPart = 'https://i0.hdslb.com/preview-new.png';

class _Playback extends FeedbackPlayback {
  final seeks = <Duration>[];
  final opened = <int>[];
  bool shouldUpdate = true;
  VideoPart part = _first;

  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
  }) async {
    this.part = part ?? video.initialPart;
    opened.add(this.part.cid);
    controller.add(
      PlaybackSnapshot(
        phase: PlaybackPhase.ready,
        duration: this.part.duration,
        position: initialPosition ?? Duration.zero,
      ),
    );
  }

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    if (shouldUpdate) {
      controller.add(
        PlaybackSnapshot(
          phase: PlaybackPhase.ready,
          duration: part.duration,
          position: position,
        ),
      );
    }
  }
}

class _Shots implements VideoShotService {
  _Shots(this.loader);
  final Future<VideoShotPreview?> Function(int cid) loader;
  final requests = <(String, int)>[];

  @override
  Future<VideoShotPreview?> loadPreview({
    required String bvid,
    required int cid,
  }) {
    requests.add((bvid, cid));
    return loader(cid);
  }
}

class _Pictures extends ImageResourceCache {
  _Pictures(this.images);
  final Map<String, Uint8List> images;
  final requested = <String>[];
  @override
  Future<CachedImageBytes> load(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    requested.add(url);
    final bytes = images[url];
    if (bytes == null) throw const ImageCacheFailure();
    return CachedImageBytes(bytes, '${identityHashCode(this)}:$url');
  }
}

const _multiPage = VideoShotPreview(
  imageUrls: [_early, _tail],
  sampleSeconds: [0, 0, 2000, 3200, 5200, 6700, 8300, 9600],
  columns: 2,
  rows: 2,
  frameWidth: 16,
  frameHeight: 9,
);
const _single = VideoShotPreview(
  imageUrls: [_newPart],
  sampleSeconds: [0, 30, 60, 90],
  columns: 2,
  rows: 2,
  frameWidth: 16,
  frameHeight: 9,
);

Future<Uint8List> _atlas() async {
  final recording = ui.PictureRecorder();
  final canvas = Canvas(recording);
  final colors = [Colors.red, Colors.green, Colors.yellow, Colors.blue];
  for (var index = 0; index < colors.length; index++) {
    canvas.drawRect(
      Rect.fromLTWH((index % 2) * 16, (index ~/ 2) * 9, 16, 9),
      Paint()..color = colors[index],
    );
  }
  final picture = recording.endRecording();
  final image = await picture.toImage(32, 18);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

final _slider = find.byKey(const Key('player-progress-slider'));
final _picture = find.byKey(const Key('video-shot-frame'));
final _time = find.textContaining('跳转至');

Future<GlobalKey> _open(
  WidgetTester tester, {
  required _Playback playback,
  required _Shots shots,
  required _Pictures pictures,
  required PointerDeviceKind kind,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = kind == PointerDeviceKind.mouse
      ? const Size(1280, 840)
      : const Size(390, 850);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        home: PlayerPage(
          video: _video,
          playbackService: playback,
          videoShotService: shots,
          videoShotImageCache: pictures,
          appPlatform: kind == PointerDeviceKind.mouse
              ? AppPlatform.windows
              : AppPlatform.android,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

Future<TestGesture> _drag(
  WidgetTester tester,
  PointerDeviceKind kind, {
  double end = .996,
}) async {
  final bar = tester.getRect(_slider);
  final y = bar.center.dy;
  final gesture = await tester.startGesture(
    Offset(bar.left + 18, y),
    kind: kind,
  );
  await gesture.moveTo(Offset(bar.left + bar.width * .5, y));
  await gesture.moveTo(Offset(bar.left + bar.width * end, y));
  await tester.pump();
  return gesture;
}

Future<void> _untilPicture(WidgetTester tester) async {
  for (var i = 0; i < 40 && _picture.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(_picture, findsOneWidget);
}

Future<List<int>> _centerPixel(WidgetTester tester, GlobalKey boundary) async {
  final rect = tester.getRect(_picture);
  return (await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final pixels = (await image.toByteData())!;
    final offset =
        4 * (rect.center.dy.round() * image.width + rect.center.dx.round());
    final color = pixels.buffer.asUint8List(offset, 4).toList();
    image.dispose();
    return color;
  }))!;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets(
      'real ${kind.name} slider paints late-page cell and seeks once at release',
      (tester) async {
        final playback = _Playback();
        final shots = _Shots((_) async => _multiPage);
        final pictures = _Pictures({_tail: (await tester.runAsync(_atlas))!});
        final boundary = await _open(
          tester,
          playback: playback,
          shots: shots,
          pictures: pictures,
          kind: kind,
        );
        expect(shots.requests, isEmpty);
        final gesture = await _drag(tester, kind);
        expect(_time, findsOneWidget);
        expect(tester.widget<Text>(_time).data, contains('02:'));
        expect(playback.seeks, isEmpty);
        await _untilPicture(tester);
        expect(shots.requests, [(_video.bvid, _first.cid)]);
        expect(pictures.requested.last, _tail);
        // The chosen ordinal is last sheet, fourth cell (bottom-right blue).
        expect(await _centerPixel(tester, boundary), [33, 150, 243, 255]);
        await gesture.moveBy(Offset(-tester.getSize(_slider).width * .01, 0));
        await tester.pump();
        expect(pictures.requested, [_tail]);
        final selected = tester.widget<Slider>(_slider).value;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(playback.seeks, [
          Duration(milliseconds: (_duration.inMilliseconds * selected).round()),
        ]);
        expect(_time, findsNothing);
        expect(_picture, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'no metadata or failed atlas uses time only and system cancel does not seek',
    (tester) async {
      var attempt = 0;
      final playback = _Playback();
      final shots = _Shots((_) async {
        switch (++attempt) {
          case 1:
            return null;
          case 2:
            throw StateError('temporary metadata failure');
          default:
            return _multiPage;
        }
      });
      final pictures = _Pictures({});
      await _open(
        tester,
        playback: playback,
        shots: shots,
        pictures: pictures,
        kind: PointerDeviceKind.touch,
      );
      for (var n = 0; n < 3; n++) {
        final gesture = await _drag(tester, PointerDeviceKind.touch);
        await tester.pump();
        expect(_time, findsOneWidget);
        expect(_picture, findsNothing);
        expect(playback.seeks, isEmpty);
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(playback.seeks, isEmpty);
        expect(_time, findsNothing);
      }
      expect(pictures.requested, [_tail]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('corrupt encoded atlas never shows a blank image card', (
    tester,
  ) async {
    final playback = _Playback();
    final shots = _Shots((_) async => _multiPage);
    final pictures = _Pictures({
      _tail: Uint8List.fromList([0, 1, 2]),
    });
    await _open(
      tester,
      playback: playback,
      shots: shots,
      pictures: pictures,
      kind: PointerDeviceKind.touch,
    );
    final gesture = await _drag(tester, PointerDeviceKind.touch);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(pictures.requested, [_tail]);
    expect(_time, findsOneWidget);
    expect(_picture, findsNothing);
    expect(tester.takeException(), isNull);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(playback.seeks, hasLength(1));
  });

  testWidgets('old metadata cannot replace or seek the new part', (
    tester,
  ) async {
    final old = Completer<VideoShotPreview?>();
    final playback = _Playback();
    final shots = _Shots(
      (cid) => cid == 1 ? old.future : Future.value(_single),
    );
    final pictures = _Pictures({_newPart: (await tester.runAsync(_atlas))!});
    await _open(
      tester,
      playback: playback,
      shots: shots,
      pictures: pictures,
      kind: PointerDeviceKind.mouse,
    );
    final firstDrag = await _drag(tester, PointerDeviceKind.mouse);
    expect(shots.requests, [(_video.bvid, 1)]);
    final next = find.byKey(const Key('next-part-button'));
    expect(next, findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(playback.opened, [1, 2]);
    await firstDrag.up();
    await tester.pumpAndSettle();
    expect(playback.seeks, isEmpty);

    final secondDrag = await _drag(tester, PointerDeviceKind.mouse);
    await _untilPicture(tester);
    old.complete(_multiPage);
    await tester.pumpAndSettle();
    expect(shots.requests, [(_video.bvid, 1), (_video.bvid, 2)]);
    expect(pictures.requested.toSet(), {_newPart});
    expect(tester.widget<Text>(_time).data, isNot(contains('02:')));
    await secondDrag.up();
    await tester.pumpAndSettle();
    expect(playback.seeks, hasLength(1));
    expect(playback.seeks.single, lessThanOrEqualTo(_second.duration));
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal video gesture still paints a frame and seeks once', (
    tester,
  ) async {
    final playback = _Playback();
    final shots = _Shots((_) async => _single);
    final pictures = _Pictures({_newPart: (await tester.runAsync(_atlas))!});
    await _open(
      tester,
      playback: playback,
      shots: shots,
      pictures: pictures,
      kind: PointerDeviceKind.touch,
    );
    final surface = tester.getRect(find.byKey(const Key('player-surface')));
    final gesture = await tester.startGesture(
      surface.centerLeft + const Offset(35, 0),
    );
    await gesture.moveBy(const Offset(230, 0));
    await tester.pump();
    expect(_time, findsOneWidget);
    await _untilPicture(tester);
    expect(playback.seeks, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(playback.seeks, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
