import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:focubili/features/player/player_page.dart';
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
  }) async {
    parts.add((part ?? video.initialPart).cid);
    emit();
  }

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);
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

Future<void> _mount(
  WidgetTester t,
  _Playback playback,
  _Metadata metadata,
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
}) async {
  return (await t.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = color,
    );
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
        expect(cache.urls, [_first, _second]);
        expect(_loading, findsOneWidget);
        expect(
          _shot,
          findsNothing,
          reason: 'do not reuse a frame for another atlas or time',
        );
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
    expect(cache.urls, ['$_publicJpg@1056w.webp', _publicJpg]);
    expect(_shot, findsOneWidget);
    expect(_unavailable, findsNothing);
    await swipe.cancel();
    await t.pump();
    expect(p.seeks, isEmpty);
    expect(_shot, findsNothing);
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

  testWidgets(
    'no thumbnails are fetched or shown during a real bottom slider drag',
    (t) async {
      final p = _Playback();
      final metadata = _Metadata((_) => _twoAtlases);
      final cache = _Atlases(
        (_) => throw StateError('unexpected image request'),
      );
      await _mount(t, p, metadata, cache);
      final slider = find.byKey(const Key('player-progress-slider'));
      final rect = t.getRect(slider);
      final drag = await t.startGesture(rect.center);
      await drag.moveBy(Offset(rect.width * .16, 0));
      await t.pump();
      expect(_shot, findsNothing);
      expect(_loading, findsNothing);
      expect(cache.urls, isEmpty);
      expect(metadata.calls, isEmpty);
      expect(p.seeks, isEmpty);
      await drag.up();
      await t.pump();
      expect(p.seeks, hasLength(1));
      expect(metadata.calls, isEmpty);
      await _remove(t, cache);
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
