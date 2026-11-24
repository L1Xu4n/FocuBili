import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';

/// Keeps unrelated streams quiet while the test supplies player errors.
class QuietLocalStreams extends Fake implements PlayerStream {
  /// Supplies errors when a fake player emits them and otherwise stays quiet.
  QuietLocalStreams([this.error = const Stream.empty()]);

  /// Leaves volume unchanged during local playback.
  @override
  Stream<double> get volume => const Stream<double>.empty();

  /// Leaves playing events under service control in this bounded loading test.
  @override
  Stream<bool> get playing => const Stream.empty();

  /// Leaves completion events unused for an unfinished local video.
  @override
  Stream<bool> get completed => const Stream.empty();

  /// Keeps initial zero positions from masquerading as loaded media events.
  @override
  Stream<Duration> get position => const Stream.empty();

  /// Models metadata arriving after open has returned.
  @override
  Stream<Duration> get duration => const Stream.empty();

  /// Leaves rate unchanged during this source-switch regression.
  @override
  Stream<double> get rate => const Stream.empty();

  /// Models an open request without fabricated buffering transitions.
  @override
  Stream<bool> get buffering => const Stream.empty();

  /// Leaves dimensions available only through the loaded state.
  @override
  Stream<int?> get width => const Stream.empty();

  /// Leaves dimensions available only through the loaded state.
  @override
  Stream<int?> get height => const Stream.empty();

  /// Carries the fake player's runtime and stop-time errors.
  @override
  final Stream<String> error;
}

/// Reproduces an asynchronous open whose early seeks are lost before loading.
class DelayedLocalPlayer extends Fake implements Player {
  var opened = Completer<Media>();
  final errors = StreamController<String>.broadcast(sync: true);
  PlayerState current = const PlayerState();
  String? errorOnStop;
  int openCalls = 0;
  int playCalls = 0;
  int loadedSeeks = 0;
  bool loaded = false;

  /// Avoids loading native libraries or creating a real video surface.
  @override
  PlatformPlayer? get platform => null;

  /// Exposes the controlled zero/loading/decoded states.
  @override
  PlayerState get state => current;

  /// Supplies the service's normal subscription contract without native events.
  @override
  PlayerStream get stream => QuietLocalStreams(errors.stream);

  /// Unloads the old source and can deliver its last error during stop.
  @override
  Future<void> stop() async {
    if (errorOnStop case final error?) errors.add(error);
    current = const PlayerState();
    loaded = false;
  }

  /// Returns before file metadata is decoded, as media_kit's command does.
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCalls++;
    opened.complete(playable as Media);
  }

  /// Publishes real local metadata at a selected initial position.
  void finishLoading(Duration position) {
    loaded = true;
    current = current.copyWith(
      duration: const Duration(minutes: 2),
      position: position,
      videoParams: const VideoParams(pixelformat: 'yuv420p', w: 320, h: 180),
    );
  }

  /// Drops premature seeks, reproducing the original lost-position failure.
  @override
  Future<void> seek(Duration position) async {
    if (!loaded) return;
    loadedSeeks++;
    current = current.copyWith(position: position);
  }

  /// Records whether playback began before the resume gate finished.
  @override
  Future<void> play() async {
    playCalls++;
    current = current.copyWith(playing: true);
  }

  /// Preserves decoded state while a resume correction is applied.
  @override
  Future<void> pause() async => current = current.copyWith(playing: false);

  /// 记录画面选择由新听视频后端管理，不在替身中建立视频解码器。
  @override
  Future<void> setVideoTrack(VideoTrack track) async {}

  /// Closes the error stream after the service cancels its subscription.
  @override
  Future<void> dispose() => errors.close();
}

/// 记录外部本地音轨，提供与真实解码输出相同的最小音频状态。
class PairedLocalPlayer extends DelayedLocalPlayer {
  final audioAttached = Completer<AudioTrack>();

  /// 只记录本地音轨并建立音频参数，供服务验证不会把纯画面当成成功。
  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    current = current.copyWith(
      audioParams: const AudioParams(format: 'float', channelCount: 2),
    );
    if (!audioAttached.isCompleted) audioAttached.complete(track);
  }
}

/// Verifies offline resume, playback errors and isolation between sources.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 分离文件作为一份本地媒体打开，音轨路径与初始位置不能丢失。
  test('本地 DASH 音视频同时加载并保留续播位置', () async {
    final directory = await Directory.systemTemp.createTemp(
      'focubili-local-pair-',
    );
    final videoFile = File('${directory.path}/video.mp4');
    final audioFile = File('${directory.path}/audio.m4a');
    await videoFile.writeAsBytes([1]);
    await audioFile.writeAsBytes([1]);
    final player = PairedLocalPlayer();
    final service = WindowsPlaybackService(player: player);
    try {
      final opening = service.openLocalTracks(
        videoFilePath: videoFile.path,
        audioFilePath: audioFile.path,
        initialPosition: const Duration(seconds: 20),
      );
      final video = await player.opened.future;
      final audio = await player.audioAttached.future;
      expect(video.start, const Duration(seconds: 20));
      expect(audio.id, contains('audio.m4a'));
      expect(audio.id.startsWith('http'), isFalse);
      expect(player.playCalls, 0);
      player.finishLoading(Duration.zero);
      await opening;
      expect(player.current.position, const Duration(seconds: 20));
      expect(player.current.playing, isTrue);
      expect(player.current.audioParams.channelCount, 2);
    } finally {
      await service.dispose();
      await directory.delete(recursive: true);
    }
  });

  for (final paired in [false, true]) {
    /// 已播放的离线媒体发生持续故障时，直接报告本地错误。
    test('${paired ? '双轨' : '单文件'}离线视频播放中故障进入错误状态', () async {
      final directory = await Directory.systemTemp.createTemp(
        'focubili-error-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final videoFile = await File(
        '${directory.path}/video.mp4',
      ).writeAsBytes([1]);
      final audioFile = await File(
        '${directory.path}/audio.m4a',
      ).writeAsBytes([1]);
      final player = paired ? PairedLocalPlayer() : DelayedLocalPlayer();
      var networkRequests = 0;
      final service = WindowsPlaybackService(
        player: player,
        sourceService: BilibiliDesktopPlaybackSourceService(
          requestJson: (_, _) async {
            networkRequests++;
            throw StateError('离线视频不应请求网络播放源');
          },
        ),
      );
      addTearDown(service.dispose);
      final video = VideoPreview.placeholder();
      final ready = service.states.firstWhere(
        (state) => state.phase == PlaybackPhase.ready,
      );
      final opening = paired
          ? service.openLocalTracks(
              videoFilePath: videoFile.path,
              audioFilePath: audioFile.path,
              video: video,
              initialPosition: Duration.zero,
            )
          : service.openLocalFile(
              filePath: videoFile.path,
              video: video,
              initialPosition: Duration.zero,
            );
      await player.opened.future;
      player.finishLoading(Duration.zero);
      await opening;
      expect((await ready).isPlaying, isTrue);

      final failed = service.states
          .firstWhere((state) => state.phase == PlaybackPhase.error)
          .timeout(const Duration(seconds: 3));
      player.current = player.current.copyWith(buffering: true);
      player.errors.add(
        paired
            ? 'Failed to initialize a decoder for codec h264'
            : 'Error reading local file',
      );

      expect((await failed).message, '离线视频播放失败，请重新打开或重新下载。');
      expect(networkRequests, 0);
      expect(player.openCalls, 1);
    });
  }

  /// 已正常播放的本地文件应忽略旧网络源迟到的 HTTP 授权错误。
  test('本地播放就绪后忽略迟到的 HTTP 401', () async {
    final directory = await Directory.systemTemp.createTemp(
      'focubili-late-http-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/local.mp4').writeAsBytes([1]);
    final player = DelayedLocalPlayer();
    final service = WindowsPlaybackService(player: player);
    addTearDown(service.dispose);
    final snapshots = <PlaybackSnapshot>[];
    final subscription = service.states.listen(snapshots.add);
    addTearDown(subscription.cancel);

    final opening = service.openLocalFile(filePath: file.path);
    await player.opened.future;
    player.finishLoading(Duration.zero);
    player.current = player.current.copyWith(
      audioParams: const AudioParams(format: 'float', channelCount: 2),
    );
    await opening;
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.phase, PlaybackPhase.ready);
    expect(snapshots.last.isPlaying, isTrue);

    player.errors.add('HTTP error 401');
    await Future<void>.delayed(Duration.zero);

    expect(snapshots.last.phase, PlaybackPhase.ready);
    expect(snapshots.last.isPlaying, isTrue);
    expect(
      snapshots.where((state) => state.phase == PlaybackPhase.error),
      isEmpty,
    );
  });

  /// 隔离旧媒体已开始的健康检查，以及停流时新到达的错误。
  test('切换本地文件时旧媒体错误不会传给新文件', () async {
    final directory = await Directory.systemTemp.createTemp('focubili-switch-');
    addTearDown(() => directory.delete(recursive: true));
    final oldFile = await File('${directory.path}/old.mp4').writeAsBytes([1]);
    final newFile = await File('${directory.path}/new.mp4').writeAsBytes([1]);
    final player = DelayedLocalPlayer();
    final service = WindowsPlaybackService(player: player);
    addTearDown(service.dispose);
    final snapshots = <PlaybackSnapshot>[];
    final subscription = service.states.listen(snapshots.add);
    addTearDown(subscription.cancel);

    final firstOpen = service.openLocalFile(filePath: oldFile.path);
    await player.opened.future;
    player.finishLoading(Duration.zero);
    await firstOpen;
    player.current = player.current.copyWith(buffering: true);
    player.errors.add('Error reading old media');
    await Future<void>.delayed(Duration.zero);

    player.opened = Completer<Media>();
    player.errorOnStop = 'HTTP error 401 from old media';
    final replacement = service.openLocalFile(filePath: newFile.path);
    await player.opened.future;
    player.finishLoading(Duration.zero);
    await replacement;

    // 让新媒体处于缓冲，防止旧健康检查因碰巧看到健康输出而通过测试。
    player.current = player.current.copyWith(buffering: true);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(snapshots.last.phase, PlaybackPhase.ready);
    expect(
      snapshots.where((state) => state.phase == PlaybackPhase.error),
      isEmpty,
    );
    expect(player.openCalls, 2);
  });

  for (final decodedPosition in [20, 0]) {
    test(
      'local switch retains 20s when decoder starts at ${decodedPosition}s',
      () async {
        final directory = await Directory.systemTemp.createTemp('focubili-r5-');
        final file = File('${directory.path}/local.mp4');
        await file.writeAsBytes([1]);
        final player = DelayedLocalPlayer();
        final service = WindowsPlaybackService(player: player);
        final snapshots = <PlaybackSnapshot>[];
        final subscription = service.states.listen(snapshots.add);
        try {
          final opening = service.openLocalFile(
            filePath: file.path,
            initialPosition: const Duration(seconds: 20),
          );
          final media = await player.opened.future;
          expect(media.start, const Duration(seconds: 20));
          expect(player.playCalls, 0);
          expect(snapshots.last.phase, PlaybackPhase.loading);
          expect(snapshots.last.isRestoringPosition, isTrue);
          player.finishLoading(Duration(seconds: decodedPosition));
          await opening;
          // The service's broadcast stream delivers the final snapshot asynchronously.
          await Future<void>.delayed(Duration.zero);
          expect(player.state.position, const Duration(seconds: 20));
          expect(player.playCalls, 1);
          expect(player.loadedSeeks, decodedPosition == 0 ? 1 : 0);
          expect(snapshots.last.phase, PlaybackPhase.ready);
          expect(snapshots.last.position, const Duration(seconds: 20));
          expect(snapshots.last.isRestoringPosition, isFalse);
        } finally {
          await subscription.cancel();
          await service.dispose();
          await file.delete();
          await directory.delete();
        }
      },
    );
  }
}
