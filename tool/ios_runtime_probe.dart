// Simulator-only probe. Normal IPA/simulator artifacts are packaged beforehand.
// A result file avoids depending on the Flutter test runner's VM discovery.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/apple_playback_session.dart';
import 'package:focubili/services/apple_video_capabilities.dart';
import 'package:focubili/services/flutter_video_frame_capture.dart';
import '../integration_test/media_fixture.dart';

Future<void> waitFor(bool Function() condition, String stage) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (!condition()) throw StateError('Timed out: $stage');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final frameworkErrors = <String>[];
  FlutterError.onError = (details) {
    frameworkErrors.add(details.exception.runtimeType.toString());
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    frameworkErrors.add(error.runtimeType.toString());
    return true;
  };
  final report = <String, Object?>{
    'success': false,
    'checks': <String>[],
    'runId': const String.fromEnvironment('IOS_PROBE_RUN_ID'),
  };
  final checks = report['checks']! as List<String>;
  final session = ApplePlaybackSession();
  Player? player;
  File? fixture;
  try {
    if (!Platform.isIOS) throw StateError('This probe requires iOS');
    MediaKit.ensureInitialized();
    await AppleVideoCapabilities.initialize();
    final directory = await getTemporaryDirectory();
    await directory.create(recursive: true);
    fixture = File('${directory.path}/focubili-ios-runtime.mp4');
    await fixture.writeAsBytes(base64Decode(appleSmokeVideoBase64));
    final p = player = Player();
    final controller = VideoController(
      p,
      configuration: AppleVideoCapabilities.configuration,
    );
    final capture = FlutterVideoFrameCapture();
    await session.initialize(
      handle: await p.handle,
      play: p.play,
      pause: p.pause,
      seek: p.seek,
    );
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: capture.wrap(
                Video(controller: controller, controls: NoVideoControls),
              ),
            ),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    await p.open(Media(fixture.path));
    await waitFor(
      () =>
          p.state.width == 160 &&
          p.state.duration.inSeconds >= 3 &&
          p.state.playing,
      'native decode',
    );
    checks.add('native_decode');
    await p.pause();
    await waitFor(() => !p.state.playing, 'pause');
    await p.seek(const Duration(seconds: 2));
    await waitFor(
      () => (p.state.position.inMilliseconds - 2000).abs() < 600,
      'seek',
    );
    await p.setRate(1.5);
    await waitFor(() => (p.state.rate - 1.5).abs() < 0.01, 'rate');
    checks.add('pause_seek_rate');
    session.update(
      title: 'FocuBili test',
      position: p.state.position,
      duration: p.state.duration,
      playing: p.state.playing,
      speed: p.state.rate,
    );
    const media = MethodChannel('com.focubili.app/apple_media');
    final before = await media.invokeMapMethod<String, dynamic>('pipStatus');
    if (before?['supported'] == true) {
      await waitFor(() => capture.globalRect != null, 'video viewport');
      final rect = capture.globalRect!;
      var started = await session.startPictureInPicture(rect);
      if (!started) {
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
        try {
          await p.play();
          await waitFor(() => p.state.playing, 'PiP playback');
          started = await session.startPictureInPicture(rect);
        } finally {
          await updates.cancel();
        }
      }
      final after = await media.invokeMapMethod<String, dynamic>('pipStatus');
      report['pip'] = {'started': started, 'status': after};
      if ((after?['frames'] as num? ?? 0) <= 0 ||
          (started && after?['active'] != true)) {
        throw StateError('PiP frame/status check failed');
      }
      await media.invokeMethod<void>('stopPiP');
      checks.add('pip_frame_and_status');
    } else {
      report['pip'] = {'supported': false};
      checks.add('pip_runtime_unsupported');
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('ios_runtime_probe', 'persisted');
    await preferences.reload();
    if (preferences.getString('ios_runtime_probe') != 'persisted') {
      throw StateError('Preference mismatch');
    }
    await preferences.remove('ios_runtime_probe');
    checks.add('preferences');
    final cookies = await const MethodChannel(
      'com.focubili.app/auth',
    ).invokeMethod<String>('readCookies');
    if (cookies == null) throw StateError('Cookie bridge returned null');
    checks.add('cookie_bridge');
    final webview = await const MethodChannel(
      'com.focubili.app/device_status',
    ).invokeMapMethod<String, dynamic>('getWebViewInfo');
    if (webview?['providerAvailable'] != true) {
      throw StateError('WebView provider unavailable');
    }
    checks.add('webview_provider');
    final permission = await const MethodChannel(
      'com.focubili.app/focus_notifications',
    ).invokeMethod<bool>('hasPermission');
    if (permission == null) {
      throw StateError('Notification bridge returned null');
    }
    checks.add('notification_bridge');
    report['success'] = true;
  } catch (error) {
    report['error'] = error.toString();
  } finally {
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    try {
      await session.dispose();
      await player?.dispose();
      if (fixture != null && await fixture.exists()) await fixture.delete();
    } catch (error) {
      report['success'] = false;
      report['cleanupError'] = error.runtimeType.toString();
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (frameworkErrors.isNotEmpty) {
    report['success'] = false;
    report['frameworkErrors'] = frameworkErrors;
  }
  final documents = await getApplicationDocumentsDirectory();
  await documents.create(recursive: true);
  final temp = File('${documents.path}/ios-runtime-result.json.tmp');
  await temp.writeAsString(jsonEncode(report), flush: true);
  await temp.rename('${documents.path}/ios-runtime-result.json');
}
