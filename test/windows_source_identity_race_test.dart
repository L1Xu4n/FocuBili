import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/windows_playback_service.dart';

import 'listening_playback_test.dart' show ListeningPlayer;

/// 每个 BV/CID 使用不同媒体，直接核对最终打开的字节来源。
class _IdentitySources extends BilibiliDesktopPlaybackSourceService {
  @override
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
  }) async => DesktopPlaybackSources(
    videoUrls: ['https://example.test/$bvid/$cid/video.m4s'],
    audioUrls: ['https://example.test/$bvid/$cid/audio.m4s'],
    referer: '',
    cookieHeader: '',
    actualQuality: 64,
    qualities: [],
    videoCodec: 'avc1',
    audioCodec: 'mp4a',
  );
}

/// 原生暂停已执行，但 Future 延迟完成，让另一支视频先完成打开。
class _DelayedPausePlayer extends ListeningPlayer {
  _DelayedPausePlayer(this.delayedPauseCall);
  final int delayedPauseCall;
  final paused = Completer<void>();
  final releasePause = Completer<void>();
  int pauseCalls = 0;

  @override
  Future<void> pause() async {
    await super.pause();
    if (++pauseCalls == delayedPauseCall) {
      paused.complete();
      await releasePause.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final delayedPause in [2, 3]) {
    test('Windows旧视频暂停晚到不能覆盖新视频媒体或位置，暂停点=$delayedPause', () async {
      final player = _DelayedPausePlayer(delayedPause);
      final service = WindowsPlaybackService(
        player: player,
        sourceService: _IdentitySources(),
      );
      const videoA = VideoPreview(
        bvid: 'BV1GJ411x7h7',
        cid: 123,
        title: 'A',
        ownerName: 'test',
        parts: [],
      );
      const videoB = VideoPreview(
        bvid: 'BV1Q541167Qg',
        cid: 456,
        title: 'B',
        ownerName: 'test',
        parts: [],
      );
      try {
        final openingA = service.openVideo(
          videoA,
          initialPosition: const Duration(seconds: 42),
        );
        await player.paused.future;
        await service.openVideo(
          videoB,
          initialPosition: const Duration(seconds: 7),
        );
        expect(player.opened.last.uri, contains('/BV1Q541167Qg/456/'));
        final opensAfterB = player.opened.length;
        final tracksAfterB = player.attached.length;
        player.releasePause.complete();
        await openingA;
        expect(player.opened.length, opensAfterB, reason: '旧请求不能在新视频就绪后打开旧媒体');
        expect(player.attached.length, tracksAfterB);
        expect(player.opened.last.uri, contains('/BV1Q541167Qg/456/'));
        expect(
          player.state.position,
          const Duration(seconds: 7),
          reason: '旧请求不能把新视频定位到旧视频进度',
        );
      } finally {
        if (!player.releasePause.isCompleted) player.releasePause.complete();
        await service.dispose();
      }
    });
  }
}
