import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/player/player_page.dart';
import 'package:focubili/features/player/widgets/player_timeline.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/video_shot_service.dart';

import 'player_ab_repeat_test.dart' show AbOverlay;
import 'refactor_r3_feedback_test.dart' show FeedbackPlayback;
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

const _duration = Duration(seconds: 10203);
const _video = VideoPreview(
  bvid: 'BV1000000000',
  cid: 5001,
  title: '合成长视频',
  ownerName: '',
  duration: _duration,
  parts: [
    VideoPart(pageNumber: 1, cid: 5001, title: 'P1', duration: _duration),
    VideoPart(pageNumber: 2, cid: 5002, title: 'P2', duration: _duration),
  ],
);

class _Playback extends FeedbackPlayback {
  _Playback({this.position = const Duration(seconds: 9510)});

  final Duration position;
  final seeks = <Duration>[];
  final seekOffsets = <Duration>[];
  final parts = <int>[];

  void emit({Duration? at}) => controller.add(
    PlaybackSnapshot(
      phase: PlaybackPhase.ready,
      duration: _duration,
      position: at ?? position,
    ),
  );

  @override
  Future<void> openVideo(
    VideoPreview video, {
    VideoPart? part,
    int quality = 64,
    Duration? initialPosition,
    PlaybackCodecPreference? codecPreference,
    bool preferDataSaving = false,
  }) async {
    parts.add((part ?? video.initialPart).cid);
    emit();
  }

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

  @override
  Future<void> seekBy(Duration offset) async => seekOffsets.add(offset);
}

class _Metadata implements VideoShotService {
  _Metadata(this.handler);
  final FutureOr<VideoShotPreview?> Function(int cid) handler;
  final calls = <int>[];
  @override
  Future<VideoShotPreview?> loadPreview({
    required String bvid,
    required int cid,
  }) async {
    expect(bvid, _video.bvid);
    calls.add(cid);
    return handler(cid);
  }
}

class _Atlases extends ImageResourceCache {
  _Atlases(this.handler);
  final FutureOr<Uint8List> Function(String url) handler;
  final urls = <String>[];

  @override
  Future<CachedImageBytes> load(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    expect(headers, {'Referer': 'https://www.bilibili.com/'});
    urls.add(url);
    final bytes = await handler(url);
    return CachedImageBytes(bytes, '$hashCode:${urls.length}:$url');
  }

  @override
  Future<void> remove(
    String url, {
    Map<String, String> headers = const {},
  }) async {}
}

const _first = 'https://i0.hdslb.com/synthetic-1.jpg';
const _second = 'https://i0.hdslb.com/synthetic-2.jpg';
const _late = 'https://i0.hdslb.com/synthetic-old.jpg';
const _new = 'https://i0.hdslb.com/synthetic-new.jpg';
const _publicJpg =
    'https://bimp.hdslb.com/videoshotpvhdboss/42_sample-0013.jpg';

const _twoAtlases = VideoShotPreview(
  imageUrls: [_first, _second],
  sampleSeconds: [0, 1, 2, 3, 9592, 9593, 9600, 9720],
  columns: 2,
  rows: 2,
  frameWidth: 16,
  frameHeight: 9,
);

VideoShotPreview _oneAtlas(
  String url, {
  double width = 16,
  double height = 9,
}) => VideoShotPreview(
  imageUrls: [url],
  sampleSeconds: const [0, 30, 60, 90],
  columns: 2,
  rows: 2,
  frameWidth: width,
  frameHeight: height,
);

final _surface = find.byKey(const Key('player-surface')).first;
final _shot = find.byKey(const Key('video-shot-frame'));
final _loading = find.byKey(const Key('video-shot-loading'));
final _unavailable = find.byKey(const Key('video-shot-unavailable'));
final _targetTime = find.textContaining('跳转至 ');
final _slider = find.byKey(const Key('player-progress-slider'));
final _dragCard = find.byKey(const Key('timeline-drag-preview'));

Offset _trackAt(WidgetTester t, double fraction) {
  final slider = t.getRect(_slider);
  final track = PlayerTimelineGeometry.trackRect(
    slider.size,
    offset: slider.topLeft,
  );
  return Offset(track.left + track.width * fraction, track.center.dy);
}

Future<void> _mount(
  WidgetTester t,
  _Playback playback,
  VideoShotService metadata,
  _Atlases cache, {
  bool desktop = false,
  double dpr = 1,
  Size? size,
}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.devicePixelRatio = dpr;
  t.view.physicalSize =
      (size ?? (desktop ? const Size(1280, 800) : const Size(390, 850))) * dpr;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: _video,
        playbackService: playback,
        videoShotService: metadata,
        videoShotImageCache: cache,
        appPlatform: desktop ? AppPlatform.windows : AppPlatform.android,
        playerOverlayService: AbOverlay(),
        offlineVideoService: ReviewOfflineLibrary(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<Uint8List> _atlas(
  WidgetTester t,
  Color color, {
  int w = 32,
  int h = 18,
  void Function(Canvas)? paintCells,
}) async {
  return (await t.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = color,
    );
    paintCells?.call(canvas);
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }))!;
}

Future<void> _pumpImages(WidgetTester t, [int cycles = 8]) async {
  for (var i = 0; i < cycles; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 16));
  }
}

Future<TestGesture> _begin(WidgetTester t, {bool desktop = false}) async {
  final rect = t.getRect(_surface);
  final gesture = await t.startGesture(
    rect.center,
    kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
  );
  await gesture.moveBy(Offset(rect.width * .08, 0));
  await t.pump();
  return gesture;
}

Future<void> _remove(WidgetTester t, _Atlases cache) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump();
  cache.dispose();
}

void main() {
  for (final method in [
    'picture swipe',
    'embedded slider',
    'fullscreen slider',
  ]) {
    testWidgets('a 110s $method shows the 109s cell and seeks to 110s', (
      t,
    ) async {
      const green = Color(0xFF00FF00);
      const red = Color(0xFFFF0000);
      final atlas = await _atlas(
        t,
        Colors.black,
        w: 160,
        h: 90,
        paintCells: (canvas) {
          canvas.drawRect(
            const Rect.fromLTWH(80, 9, 16, 9),
            Paint()..color = green,
          );
          canvas.drawRect(
            const Rect.fromLTWH(96, 9, 16, 9),
            Paint()..color = red,
          );
        },
      );
      final metadata = BilibiliVideoShotService(
        requestJson: (_) async => jsonEncode({
          'code': 0,
          'data': {
            'image': [_first],
            'img_x_len': 10,
            'img_y_len': 10,
            'img_x_size': 16,
            'img_y_size': 9,
            // Captured videoshot index prefix. Green is 109s; red is 117s.
            'index': [
              0,
              0,
              8,
              14,
              19,
              25,
              34,
              40,
              46,
              56,
              63,
              70,
              80,
              87,
              93,
              100,
              109,
              117,
              124,
            ],
          },
        }),
      );
      // This fixture's long video uses 600s / 75% of the surface width.
      // _begin's 8% swipe moves from 46s to 110s exactly.
      final p = _Playback(position: const Duration(seconds: 46));
      final cache = _Atlases((_) => atlas);
      await _mount(t, p, metadata, cache);
      final TestGesture drag;
      final sliderDrag = method != 'picture swipe';
      if (sliderDrag) {
        if (method == 'fullscreen slider') {
          await t.tap(find.byTooltip('进入全屏'));
          t.view.physicalSize = const Size(850, 390);
          await t.pumpAndSettle();
          expect(find.byTooltip('退出全屏'), findsOneWidget);
        }
        drag = await t.startGesture(_trackAt(t, .4));
        await drag.moveTo(_trackAt(t, 110 / _duration.inSeconds));
        await t.pump();
      } else {
        drag = await _begin(t);
      }
      await _pumpImages(t);
      if (sliderDrag) {
        expect(
          find.descendant(of: _dragCard, matching: find.text('1:50')),
          findsOneWidget,
        );
        expect(
          t.getRect(_dragCard).bottom,
          lessThanOrEqualTo(t.getRect(_slider).top),
        );
      } else {
        expect(find.text('跳转至 1:50'), findsOneWidget);
      }
      final cell = find.descendant(
        of: _shot,
        matching: find.byType(CustomPaint),
      );
      final painter = t.widget<CustomPaint>(cell).painter!;
      final size = t.getSize(cell);
      final rgba = await t.runAsync(() async {
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.ceil(),
          size.height.ceil(),
        );
        picture.dispose();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final center = (image.height ~/ 2 * image.width + image.width ~/ 2) * 4;
        image.dispose();
        return bytes.getUint32(center);
      });
      expect(rgba, 0x00FF00FF, reason: '109s is green; 117s is red');
      expect(p.seeks, isEmpty);
      await drag.up();
      await t.pump();
      expect(p.seeks, [const Duration(seconds: 110)]);
      expect(_dragCard, findsNothing);
      await _remove(t, cache);
    });
  }

  for (final desktop in [false, true]) {
    testWidgets(
      'target sheet owns loading and raster throughout a real horizontal gesture ($desktop)',
      (t) async {
        final blue = await _atlas(t, Colors.blue);
        final red = await _atlas(t, Colors.red);
        final metadataGate = Completer<VideoShotPreview>();
        final firstGate = Completer<Uint8List>();
        final secondGate = Completer<Uint8List>();
        final metadata = _Metadata((_) => metadataGate.future);
        final cache = _Atlases(
          (url) => url == _first ? firstGate.future : secondGate.future,
        );
        final p = _Playback();
        await _mount(
          t,
          p,
          metadata,
          cache,
          desktop: desktop,
          dpr: desktop ? 1 : 3,
        );
        final swipe = await _begin(t, desktop: desktop);
        expect(_loading, findsOneWidget);
        expect(_shot, findsNothing);
        metadataGate.complete(_twoAtlases);
        await t.pump();
        await t.pump();
        expect(cache.urls, [_first]);
        expect(_loading, findsOneWidget);
        expect(_targetTime, findsOneWidget);
        firstGate.complete(blue);
        await _pumpImages(t);
        expect(_shot, findsOneWidget);
        expect(_loading, findsNothing);
        final width = t.getRect(_surface).width;
        await swipe.moveBy(Offset(width * .06, 0));
        await t.pump();
        expect(cache.urls, [_first]);
        expect(_loading, findsOneWidget);
        expect(
          _shot,
          findsNothing,
          reason: 'do not reuse a frame for another atlas or time',
        );
        await t.pump(const Duration(milliseconds: 89));
        expect(cache.urls, [_first]);
        await t.pump(const Duration(milliseconds: 1));
        expect(cache.urls, [_first, _second]);
        p.emit(at: const Duration(seconds: 50));
        await t.pump(const Duration(seconds: 4));
        expect(
          _loading,
          findsOneWidget,
          reason: 'holding a gesture is not a three-second notice',
        );
        expect(find.text('跳转至 02:40:22'), findsOneWidget);
        expect(p.seeks, isEmpty);
        secondGate.complete(red);
        await _pumpImages(t);
        expect(_shot, findsOneWidget);
        expect(_loading, findsNothing);
        expect(cache.urls, [_first, _second]);
        await swipe.up();
        await t.pump();
        expect(p.seeks, [const Duration(seconds: 9622)]);
        expect(_shot, findsNothing);
        await _remove(t, cache);
      },
    );
  }

  testWidgets('authorized public resize falls back once on a corrupt atlas', (
    t,
  ) async {
    final raw = await _atlas(t, Colors.green);
    final p = _Playback();
    final cache = _Atlases(
      (url) => url == _publicJpg ? raw : Uint8List.fromList([1, 2, 3]),
    );
    final metadata = _Metadata(
      (_) => _oneAtlas(_publicJpg, width: 1000, height: 562.5),
    );
    await _mount(t, p, metadata, cache, dpr: 3);
    final swipe = await _begin(t);
    await _pumpImages(t, 12);
    expect(_shot, findsOneWidget);
    final displayedWidth = t.getSize(_shot).width;
    final expectedDecodeWidth = (displayedWidth * 2 * t.view.devicePixelRatio)
        .ceil();
    expect(expectedDecodeWidth, lessThan(1056));
    expect(cache.urls, [
      '$_publicJpg@${expectedDecodeWidth}w.webp',
      _publicJpg,
    ]);
    expect(_unavailable, findsNothing);
    await swipe.cancel();
    await t.pump();
    expect(p.seeks, isEmpty);
    expect(_shot, findsNothing);
    await _remove(t, cache);
  });

  testWidgets('an already small public atlas requests equal-width WebP', (
    t,
  ) async {
    final bytes = await _atlas(t, Colors.green);
    final cache = _Atlases((_) => bytes);
    await _mount(
      t,
      _Playback(),
      _Metadata((_) => _oneAtlas(_publicJpg)),
      cache,
    );
    final swipe = await _begin(t);
    await _pumpImages(t);
    expect(cache.urls, ['$_publicJpg@32w.webp']);
    expect(_shot, findsOneWidget);
    await swipe.cancel();
    await _remove(t, cache);
  });

  testWidgets('a failed fetch is explicit and a later gesture can recover', (
    t,
  ) async {
    final bytes = await _atlas(t, Colors.green);
    var shouldFail = true;
    final cache = _Atlases((url) {
      if (shouldFail) throw const ImageCacheFailure();
      return bytes;
    });
    final p = _Playback(position: const Duration(hours: 1, minutes: 42));
    final metadata = _Metadata((_) => _oneAtlas(_first));
    await _mount(t, p, metadata, cache);
    var swipe = await _begin(t);
    await _pumpImages(t);
    expect(_unavailable, findsOneWidget);
    expect(_targetTime, findsOneWidget);
    expect(_shot, findsNothing);
    expect(_loading, findsNothing);
    await swipe.cancel();
    await t.pump();
    expect(_unavailable, findsNothing);
    expect(p.seeks, isEmpty);
    shouldFail = false;
    swipe = await _begin(t);
    await _pumpImages(t);
    expect(_shot, findsOneWidget);
    expect(metadata.calls, [5001]);
    expect(cache.urls, [_first, _first]);
    await swipe.up();
    await t.pump();
    expect(p.seeks, hasLength(1));
    await _remove(t, cache);
  });

  testWidgets(
    'switching P while a pointer and old metadata are pending never seeks the new P',
    (t) async {
      final bytes = await _atlas(t, Colors.green);
      final oldMeta = Completer<VideoShotPreview>();
      final metadata = _Metadata(
        (cid) => cid == 5001 ? oldMeta.future : _oneAtlas(_new),
      );
      final cache = _Atlases((_) => bytes);
      final p = _Playback();
      await _mount(t, p, metadata, cache);
      final swipe = await _begin(t);
      expect(_loading, findsOneWidget);
      await t.tap(find.byKey(const Key('part-2')), pointer: 92);
      await _pumpImages(t);
      expect(p.parts, [5001, 5002]);
      expect(_targetTime, findsNothing);
      oldMeta.complete(_oneAtlas(_late));
      await swipe.up();
      await _pumpImages(t);
      expect(p.seeks, isEmpty);
      expect(cache.urls, isEmpty);
      final newer = await _begin(t);
      await _pumpImages(t);
      expect(_shot, findsOneWidget);
      expect(metadata.calls, [5001, 5002]);
      expect(cache.urls, [_new]);
      await newer.cancel();
      await t.pump();
      await _remove(t, cache);
    },
  );

  for (final badAtlas in [false, true]) {
    testWidgets(
      'slider falls back to time only and never seeks on cancel (badAtlas=$badAtlas)',
      (t) async {
        final p = _Playback();
        final metadata = _Metadata((_) => badAtlas ? _oneAtlas(_first) : null);
        final cache = _Atlases((_) => throw const ImageCacheFailure());
        await _mount(t, p, metadata, cache);
        final initial = t.widget<Slider>(_slider).value;
        final drag = await t.startGesture(_trackAt(t, .2));
        await drag.moveTo(_trackAt(t, .4));
        await t.pumpAndSettle();
        for (final fraction in [.45, .5]) {
          await drag.moveTo(_trackAt(t, fraction));
          await _pumpImages(t, 2);
        }
        expect(
          find.descendant(of: _dragCard, matching: find.text('01:25:01')),
          findsOneWidget,
        );
        expect(_shot, findsNothing);
        expect(_loading, findsNothing);
        expect(_unavailable, findsNothing);
        expect(cache.urls, badAtlas ? [_first] : isEmpty);
        expect(metadata.calls, [5001]);
        expect(p.seeks, isEmpty);
        await drag.cancel();
        await t.pumpAndSettle();
        expect(_dragCard, findsNothing);
        expect(p.seeks, isEmpty);
        expect(t.widget<Slider>(_slider).value, closeTo(initial, .00001));
        await _remove(t, cache);
      },
    );
  }

  testWidgets(
    'changing part closes a dragging slider and ignores its pending metadata',
    (t) async {
      final p = _Playback();
      final pending = Completer<VideoShotPreview>();
      final metadata = _Metadata((_) => pending.future);
      final cache = _Atlases(
        (_) => throw StateError('unexpected image request'),
      );
      await _mount(t, p, metadata, cache);
      final drag = await t.startGesture(_trackAt(t, .2));
      await drag.moveTo(_trackAt(t, .4));
      await t.pump();
      expect(_dragCard, findsOneWidget);
      await t.tap(find.byKey(const Key('part-2')), pointer: 92);
      await _pumpImages(t);
      expect(p.parts, [5001, 5002]);
      expect(_dragCard, findsNothing);
      pending.complete(_oneAtlas(_late));
      await drag.up();
      await _pumpImages(t);
      expect(p.seeks, isEmpty);
      expect(cache.urls, isEmpty);
      expect(_dragCard, findsNothing);
      await _remove(t, cache);
    },
  );

  testWidgets(
    'timeline accessibility actions keep slider steps; hardware Right seeks 5 seconds',
    (t) async {
      final p = _Playback(position: const Duration(seconds: 100));
      final metadata = _Metadata((_) => null);
      final cache = _Atlases(
        (_) => throw StateError('unexpected image request'),
      );
      final semantics = t.ensureSemantics();
      await _mount(t, p, metadata, cache, desktop: true);
      final owner = t.binding.renderViews.single.owner!.semanticsOwner!;
      int sliderNodeId() {
        final matches = <int>[];
        void collect(SemanticsNode node) {
          if (node.getSemanticsData().hasAction(ui.SemanticsAction.increase)) {
            matches.add(node.id);
          }
          node.visitChildren((child) {
            collect(child);
            return true;
          });
        }

        collect(t.getSemantics(_slider));
        return matches.single;
      }

      owner.performAction(sliderNodeId(), ui.SemanticsAction.increase);
      await t.pumpAndSettle();
      expect(p.seeks, [const Duration(milliseconds: 610150)]);
      owner.performAction(sliderNodeId(), ui.SemanticsAction.decrease);
      await t.pumpAndSettle();
      expect(p.seeks.last, const Duration(seconds: 100));
      owner.performAction(sliderNodeId(), ui.SemanticsAction.focus);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(p.seeks, [
        const Duration(milliseconds: 610150),
        const Duration(seconds: 100),
      ]);
      expect(p.seekOffsets, [const Duration(seconds: 5)]);
      expect(metadata.calls, isEmpty);
      expect(_dragCard, findsNothing);
      await _remove(t, cache);
      semantics.dispose();
    },
  );

  test('preview resize only changes the proven unsigned public atlas path', () {
    VideoShotFrame frame(String url) => VideoShotFrame(
      imageUrl: url,
      column: 0,
      row: 0,
      frameWidth: 480,
      frameHeight: 270,
      sheetColumns: 10,
      sheetRows: 10,
    );
    expect(
      frame(_publicJpg).resizedPublicAtlasUrl(2048),
      '$_publicJpg@2048w.webp',
    );
    for (final untrusted in [
      '$_publicJpg?signature=test',
      '$_publicJpg#position',
      _publicJpg.replaceFirst('https:', 'http:'),
      _publicJpg.replaceFirst('bimp.hdslb.com', 'other.hdslb.com'),
      _publicJpg.replaceFirst('bimp.hdslb.com', 'bimp.hdslb.com:8043'),
      _publicJpg.replaceFirst('bimp.hdslb.com', 'user@bimp.hdslb.com'),
      _publicJpg.replaceFirst('videoshotpvhdboss', 'other'),
      '$_publicJpg@1760w.webp',
    ]) {
      expect(
        frame(untrusted).resizedPublicAtlasUrl(2048),
        isNull,
        reason: untrusted,
      );
    }
    expect(frame(_publicJpg).resizedPublicAtlasUrl(5000), isNull);
  });
}
