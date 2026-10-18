// Real libmpv/loopback-media probe. No account, credentials, or user media.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:focubili/models/playback_buffer_range.dart';
import '../integration_test/media_fixture.dart';

Future<void> main(List<String> args) async {
  MediaKit.ensureInitialized(libmpv: args.isEmpty ? null : args.single);
  final bytes = base64Decode(appleSmokeVideoBase64);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType('video', 'mp4');
    request.response.add(bytes);
    await request.response.close();
  });
  final player = Player();
  final native = player.platform as NativePlayer;
  try {
    await native.setProperty('ao', 'null');
    await native.setProperty('vo', 'null');
    await native.setProperty('cache', 'yes');
    await player.open(
      Media('http://127.0.0.1:${server.port}/fixture.mp4'),
      play: false,
    );
    List<PlaybackBufferRange> ranges = const [];
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (ranges.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ranges = playbackBufferRangesFromMpv(
        await native.getProperty('demuxer-cache-state'),
        duration: player.state.duration,
      );
    }
    if (ranges.isEmpty) {
      throw StateError('Native player returned no usable buffer ranges');
    }
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (player.state.position <= Duration.zero) {
      throw StateError('Synthetic media did not advance');
    }
    stdout.writeln(
      jsonEncode({
        'backend': 'real libmpv',
        'input': 'synthetic loopback MP4',
        'durationMs': player.state.duration.inMilliseconds,
        'decodedPositionMs': player.state.position.inMilliseconds,
        'bufferedRangesMs': [
          for (final range in ranges)
            [range.start.inMilliseconds, range.end.inMilliseconds],
        ],
        'uiVerified': false,
      }),
    );
  } finally {
    await player.dispose();
    await server.close(force: true);
  }
}
