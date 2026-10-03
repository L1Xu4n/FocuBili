import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';

/// Supplies quiet streams while the test controls loading through player state.
class QuietLocalStreams extends Fake implements PlayerStream {
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

  /// Provides no errors for the controlled valid local media.
  @override
  Stream<String> get error => const Stream.empty();
}

/// Reproduces an asynchronous open whose early seeks are lost before loading.
class DelayedLocalPlayer extends Fake implements Player {
  final opened = Completer<Media>();
  PlayerState current = const PlayerState();
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
  PlayerStream get stream => QuietLocalStreams();

  /// Unloads the old source and clears its decoder state.
  @override
  Future<void> stop() async => current = const PlayerState();

  /// Returns before file metadata is decoded, as media_kit's command does.
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
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

  /// Releases no operating-system resources in this test double.
  @override
  Future<void> dispose() async {}
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

/// Verifies both load-time start and post-decode correction preserve online progress.
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
