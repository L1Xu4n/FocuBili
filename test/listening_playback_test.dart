import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'windows_local_source_resume_test.dart' show QuietLocalStreams;

/// 只提供一组分离轨道，路径差异使测试能发现误打开视频画面的行为。
class ListeningSources extends BilibiliDesktopPlaybackSourceService {
  Completer<void>? gate;

  /// 返回无需网络和账号的已校验音视频计划。
  @override
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
  }) async {
    await gate?.future;
    return const DesktopPlaybackSources(
      videoUrls: ['https://example.test/video.m4s'],
      audioUrls: ['https://example.test/audio.m4s'],
      referer: '',
      cookieHeader: '',
      actualQuality: 64,
      qualities: [],
      videoCodec: 'avc1',
      audioCodec: 'mp4a',
    );
  }
}

/// 记录所有真正交给播放器的媒体；读取元数据不被误当成下载了视频。
class ListeningPlayer extends Fake implements Player {
  PlayerState current = const PlayerState();
  final opened = <Media>[];
  final attached = <AudioTrack>[];
  int plays = 0;

  /// 不启动本机 libmpv。
  @override
  PlatformPlayer? get platform => null;

  /// 提供正常订阅接口，事件由服务自身发出。
  @override
  PlayerStream get stream => QuietLocalStreams();

  /// 返回受控解码状态。
  @override
  PlayerState get state => current;

  /// 停止旧媒体，但维持倍速设置。
  @override
  Future<void> stop() async => current = PlayerState(rate: current.rate);

  /// 记录实际加载地址并提供音频和视频的解码参数。
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media);
    current = current.copyWith(
      duration: const Duration(minutes: 3),
      position: media.start ?? Duration.zero,
      playing: play,
      audioParams: const AudioParams(format: 'float', channelCount: 2),
      videoParams: const VideoParams(pixelformat: 'yuv420p', w: 320, h: 180),
    );
  }

  /// 记录独立音轨挂载，听视频应不再外挂另一条媒体。
  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    attached.add(track);
  }

  /// 模拟画面轨的启停。
  @override
  Future<void> setVideoTrack(VideoTrack track) async {}

  /// 保留指定位置。
  @override
  Future<void> seek(Duration position) async =>
      current = current.copyWith(position: position);

  /// 记录播放次数，用于发现暂停状态切换时的意外自动播放。
  @override
  Future<void> play() async {
    plays++;
    current = current.copyWith(playing: true);
  }

  /// 模拟系统或定时暂停。
  @override
  Future<void> pause() async => current = current.copyWith(playing: false);

  /// 保存倍速供模式切换验证。
  @override
  Future<void> setRate(double rate) async =>
      current = current.copyWith(rate: rate);

  /// 替身不持有系统资源。
  @override
  Future<void> dispose() async {}
}

/// 模拟 mpv 接收 open 后稍后才载入，以及首次解码重置早期 seek。
class DelayedListeningPlayer extends ListeningPlayer {
  Completer<Media> audioOpened = Completer<Media>();
  bool waitingForAudio = false;
  bool resetOnNextPlay = false;
  int prematureSeeks = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    if (!media.uri.contains('/audio.m4s')) {
      waitingForAudio = false;
      await super.open(playable, play: play);
      return;
    }
    opened.add(media);
    waitingForAudio = true;
    current = PlayerState(rate: current.rate);
    audioOpened.complete(media);
  }

  void finishAudioLoad() {
    waitingForAudio = false;
    // 故意忽略 start，以覆盖底层未兑现加载位置时的补偿路径。
    current = current.copyWith(duration: const Duration(minutes: 3));
    resetOnNextPlay = true;
  }

  @override
  Future<void> seek(Duration position) async {
    if (waitingForAudio) {
      prematureSeeks++;
      return;
    }
    await super.seek(position);
  }

  @override
  Future<void> play() async {
    if (resetOnNextPlay) {
      resetOnNextPlay = false;
      current = current.copyWith(
        position: Duration.zero,
        audioParams: const AudioParams(format: 'float', channelCount: 2),
      );
    }
    await super.play();
  }
}

/// 只验证纯音频媒体选择、进度和暂停保持，以及后端定时与取消。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('在线听视频只打开音频地址并保留进度倍速及定时暂停', () async {
    final player = ListeningPlayer();
    final sources = ListeningSources();
    final service = WindowsPlaybackService(
      player: player,
      sourceService: sources,
    );
    final snapshots = <PlaybackSnapshot>[];
    final subscription = service.states.listen(snapshots.add);
    try {
      await service.openVideo(VideoPreview.placeholder());
      await service.seekTo(const Duration(seconds: 42));
      await service.setPlaybackSpeed(1.5);
      player.opened.clear();
      player.attached.clear();
      await service.setAudioOnly(true);
      expect(player.opened.single.uri, contains('/audio.m4s'));
      expect(player.attached, isEmpty);
      expect(player.state.position, const Duration(seconds: 42));
      expect(player.state.rate, 1.5);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last.audioOnly, isTrue);
      await service.setSleepTimer(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(player.state.playing, isFalse);
      final plays = player.plays;
      await service.setAudioOnly(false);
      expect(player.opened.last.uri, contains('/video.m4s'));
      expect(player.state.position, const Duration(seconds: 42));
      expect(player.plays, plays);
      await service.play();
      await service.setSleepTimer(const Duration(milliseconds: 20));
      await service.setSleepTimer(null);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(player.state.playing, isTrue);
      sources.gate = Completer<void>();
      final switching = service.setAudioOnly(true);
      await Future<void>.delayed(Duration.zero);
      await service.setSleepTimer(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      sources.gate!.complete();
      await switching;
      expect(player.state.playing, isFalse, reason: '定时到期不能被迟到的媒体地址重新开播');
    } finally {
      await subscription.cancel();
      await service.dispose();
    }
  });
  for (final paused in [false, true]) {
    test('音轨延迟加载及首次解码归零后恢复位置，暂停=$paused', () async {
      final player = DelayedListeningPlayer();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: ListeningSources(),
      );
      final snapshots = <PlaybackSnapshot>[];
      final subscription = service.states.listen(snapshots.add);
      try {
        await service.openVideo(VideoPreview.placeholder());
        await service.seekTo(const Duration(seconds: 42));
        await service.setPlaybackSpeed(1.5);
        if (paused) await service.pause();
        final plays = player.plays;
        final switching = service.setAudioOnly(true);
        final media = await player.audioOpened.future;
        expect(media.start, const Duration(seconds: 42));
        expect(player.prematureSeeks, 0);
        await expectLater(service.setAudioOnly(false), throwsStateError);
        player.finishAudioLoad();
        await switching;
        expect(player.state.position, const Duration(seconds: 42));
        expect(player.state.rate, 1.5);
        expect(player.state.playing, !paused);
        if (paused) {
          expect(player.plays, plays);
          await service.play();
          expect(player.state.position, const Duration(seconds: 42));
        }
        await service.setAudioOnly(false);
        expect(player.state.position, const Duration(seconds: 42));
        // 再次切换必须使用当前位置，而不是第一次切换保存的旧进度。
        await service.seekTo(const Duration(seconds: 65));
        player.audioOpened = Completer<Media>();
        final secondSwitch = service.setAudioOnly(true);
        expect(
          (await player.audioOpened.future).start,
          const Duration(seconds: 65),
        );
        player.finishAudioLoad();
        await secondSwitch;
        expect(player.state.position, const Duration(seconds: 65));
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.last.phase, PlaybackPhase.ready);
      } finally {
        await subscription.cancel();
        await service.dispose();
      }
    });
  }

  test('新视频使仍在等待音轨元数据的模式切换失效', () async {
    final player = DelayedListeningPlayer();
    final service = WindowsPlaybackService(
      player: player,
      sourceService: ListeningSources(),
    );
    try {
      await service.openVideo(VideoPreview.placeholder());
      await service.seekTo(const Duration(seconds: 42));
      final switching = service.setAudioOnly(true);
      await player.audioOpened.future;
      player.audioOpened = Completer<Media>();
      final newer = service.openVideo(
        VideoPreview.placeholder(),
        initialPosition: const Duration(seconds: 70),
      );
      final media = await player.audioOpened.future;
      expect(media.start, const Duration(seconds: 70));
      player.finishAudioLoad();
      await Future.wait([switching, newer]);
      expect(player.state.position, const Duration(seconds: 70));
    } finally {
      await service.dispose();
    }
  });

  test('本地听视频只读取缓存音轨且暂停切换不自动播放', () async {
    final root = await Directory.systemTemp.createTemp('listening-pair-');
    final video = File('${root.path}/video.mp4');
    final audio = File('${root.path}/audio.m4a');
    await video.writeAsBytes([1]);
    await audio.writeAsBytes([1]);
    final player = ListeningPlayer();
    final service = WindowsPlaybackService(player: player);
    try {
      await service.openLocalTracks(
        videoFilePath: video.path,
        audioFilePath: audio.path,
        video: VideoPreview.placeholder(),
        initialPosition: const Duration(seconds: 30),
      );
      await service.pause();
      final plays = player.plays;
      player.opened.clear();
      await service.setAudioOnly(true);
      expect(player.opened.single.uri, contains('audio.m4a'));
      expect(player.plays, plays);
      expect(player.state.position, const Duration(seconds: 30));
      await service.setAudioOnly(false);
      expect(player.opened.last.uri, contains('video.mp4'));
      expect(player.plays, plays);
    } finally {
      await service.dispose();
      await root.delete(recursive: true);
    }
  });
}
