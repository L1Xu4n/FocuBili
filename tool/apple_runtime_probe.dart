// Standalone macOS runtime probe: avoids the Flutter test runner's VM-discovery
// path while retaining real native playback and storage assertions.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/apple_playback_session.dart';
import 'package:focubili/services/apple_video_capabilities.dart';
import '../integration_test/media_fixture.dart';

Future<void> waitFor(bool Function() condition, String phase) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (!condition()) throw StateError('Timed out: $phase');
  stdout.writeln('APPLE_RUNTIME: $phase passed');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Player? player;
  File? file;
  final session = ApplePlaybackSession();
  var success = false;
  try {
    MediaKit.ensureInitialized();
    await AppleVideoCapabilities.initialize();
    final dir = await getTemporaryDirectory();
    await dir.create(recursive: true);
    file = File('${dir.path}/focubili-runtime-probe.mp4');
    await file.writeAsBytes(base64Decode(appleSmokeVideoBase64));
    stdout.writeln('APPLE_RUNTIME: creating player');
    final p = player = Player();
    final video = VideoController(
      p,
      configuration: AppleVideoCapabilities.configuration,
    );
    await session.initialize(
      handle: await p.handle,
      play: p.play,
      pause: p.pause,
      seek: p.seek,
    );
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Video(controller: video, controls: NoVideoControls),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    stdout.writeln('APPLE_RUNTIME: opening media');
    await p.open(Media(file.path));
    await waitFor(
      () => p.state.duration.inSeconds >= 3 && p.state.width == 160,
      'native decode',
    );
    await waitFor(() => p.state.playing, 'play');
    await p.pause();
    await waitFor(() => !p.state.playing, 'pause');
    await p.seek(const Duration(seconds: 2));
    await waitFor(
      () => (p.state.position.inMilliseconds - 2000).abs() < 600,
      'seek',
    );
    await p.setRate(1.5);
    await waitFor(() => (p.state.rate - 1.5).abs() < 0.01, 'rate');
    session.update(
      title: 'FocuBili test',
      position: p.state.position,
      duration: p.state.duration,
      playing: false,
      speed: 1.5,
    );
    const mediaChannel = MethodChannel('com.focubili.app/apple_media');
    final pipBefore = await mediaChannel.invokeMapMethod<String, dynamic>(
      'pipStatus',
    );
    if (pipBefore?['supported'] == true) {
      var started = await session.startPictureInPicture(
        const Rect.fromLTWH(0, 0, 320, 180),
      );
      if (!started) {
        stdout.writeln(
          'APPLE_PIP_PAUSED_UNAVAILABLE: ${await mediaChannel.invokeMethod<Object?>('pipStatus')}',
        );
        await p.setPlaylistMode(PlaylistMode.loop);
        final updates = p.stream.position.listen(
          (_) => session.update(
            title: 'FocuBili test',
            position: p.state.position,
            duration: p.state.duration,
            playing: p.state.playing,
            speed: p.state.rate,
          ),
        );
        await p.play();
        await waitFor(() => p.state.playing, 'PiP retry playback');
        started = await session.startPictureInPicture(
          const Rect.fromLTWH(0, 0, 320, 180),
        );
        await updates.cancel();
      }
      final status = await mediaChannel.invokeMapMethod<String, dynamic>(
        'pipStatus',
      );
      stdout.writeln('APPLE_PIP_RESULT: started=$started status=$status');
      if ((status?['frames'] as int? ?? 0) == 0) {
        throw StateError('PiP frame bridge produced no frames');
      }
      if (started && status?['active'] != true) {
        throw StateError('PiP start not confirmed');
      }
      await mediaChannel.invokeMethod<void>('stopPiP');
    } else {
      stdout.writeln('APPLE_PIP_UNSUPPORTED_ON_RUNTIME');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apple_runtime_probe', 'saved');
    await prefs.reload();
    if (prefs.getString('apple_runtime_probe') != 'saved') {
      throw StateError('storage');
    }
    await prefs.remove('apple_runtime_probe');
    final cookies = await const MethodChannel(
      'com.focubili.app/auth',
    ).invokeMethod<String>('readCookies');
    if (cookies == null) throw StateError('cookie bridge');
    final webview = await const MethodChannel(
      'com.focubili.app/device_status',
    ).invokeMapMethod<String, dynamic>('getWebViewInfo');
    if (webview?['providerAvailable'] != true) {
      throw StateError('webview bridge');
    }
    final allowed = await const MethodChannel(
      'com.focubili.app/focus_notifications',
    ).invokeMethod<bool>('hasPermission');
    if (allowed == null) throw StateError('notification bridge');
    success = true;
  } catch (error, stack) {
    stderr.writeln('APPLE_RUNTIME_FAILURE: $error\n$stack');
  } finally {
    await session.dispose();
    await player?.dispose();
    if (file != null && await file.exists()) await file.delete();
  }
  if (success) stdout.writeln('APPLE_RUNTIME_ALL_CHECKS_PASSED');
  await stdout.flush();
  await stderr.flush();
  exit(success ? 0 : 1);
}
