// A release-mode probe, packaged separately from the normal application.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dbus/dbus.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:focubili/services/flutter_video_frame_capture.dart';
import 'package:focubili/services/linux_media_session.dart';
import 'package:focubili/services/linux_mini_player.dart';
import 'package:focubili/services/linux_focus_notification_service.dart';
import '../integration_test/media_fixture.dart';

Future<void> waitFor(bool Function() condition, String name) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (!condition()) throw StateError('Timeout: $name');
  stdout.writeln('LINUX_PROBE: $name passed');
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (runWebViewTitleBarWidget(args)) return;
  final session = LinuxMediaSession();
  final mini = LinuxMiniPlayer();
  Player? player;
  DBusClient? bus;
  var success = false;
  try {
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(900, 620), title: 'FocuBili Linux QA'),
    );
    await windowManager.show();
    final p = player = Player();
    // A headless CI session has no hardware audio sink; retain audio decoding.
    if (p.platform is NativePlayer) {
      await (p.platform as NativePlayer).setProperty('ao', 'null');
    }
    final video = VideoController(
      p,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );
    final capture = FlutterVideoFrameCapture();
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: capture.wrap(
                Video(controller: video, controls: NoVideoControls),
              ),
            ),
          ),
        ),
      ),
    );
    final dir = await getTemporaryDirectory();
    await dir.create(recursive: true);
    final media = File('${dir.path}/focubili-linux-qa.mp4');
    await media.writeAsBytes(base64Decode(appleSmokeVideoBase64));
    await p.open(Media(media.path));
    await waitFor(
      () => p.state.width == 160 && p.state.position.inMilliseconds > 400,
      'native decode and position',
    );
    await p.pause();
    await p.seek(const Duration(seconds: 2));
    await p.setRate(1.5);
    await p.setVolume(35);
    await waitFor(
      () =>
          p.state.position.inMilliseconds >= 1600 &&
          p.state.rate == 1.5 &&
          p.state.volume == 35,
      'seek rate and player volume',
    );
    await session.initialize(
      play: p.play,
      pause: p.pause,
      seek: p.seek,
      setRate: p.setRate,
    );
    session.update(
      title: 'Linux QA',
      trackId: 'fixture',
      position: p.state.position,
      duration: p.state.duration,
      playing: p.state.playing,
      speed: p.state.rate,
    );
    bus = DBusClient.session();
    final remote = DBusRemoteObject(
      bus,
      name: 'org.mpris.MediaPlayer2.focubili.instance$pid',
      path: DBusObjectPath('/org/mpris/MediaPlayer2'),
    );
    final metadata = await remote.getProperty(
      LinuxMediaSession.playerInterface,
      'Metadata',
    );
    if (!metadata.toString().contains('Linux QA')) {
      throw StateError('MPRIS metadata missing');
    }
    await remote.callMethod(LinuxMediaSession.playerInterface, 'Play', []);
    await waitFor(() => p.state.playing, 'MPRIS play');
    await remote.callMethod(LinuxMediaSession.playerInterface, 'Pause', []);
    await waitFor(() => !p.state.playing, 'MPRIS pause');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('linux_probe', '中文🧪');
    await prefs.reload();
    if (prefs.getString('linux_probe') != '中文🧪') {
      throw StateError('Preferences mismatch');
    }
    await prefs.remove('linux_probe');
    const storage = FlutterSecureStorage();
    await storage.write(
      key: 'focubili_linux_probe',
      value: 'synthetic-test-value',
    );
    if (await storage.read(key: 'focubili_linux_probe') !=
        'synthetic-test-value') {
      throw StateError('Keyring mismatch');
    }
    await storage.delete(key: 'focubili_linux_probe');
    stdout.writeln('LINUX_PROBE: keyring and preferences passed');
    final notifications = LinuxNotificationClient(persistReminders: false);
    if (!await notifications.initialize()) {
      throw StateError('Notification server unavailable');
    }
    await notifications.show(id: 42001, title: 'Linux QA', body: '合成测试通知');
    await notifications.cancel(42001);
    stdout.writeln('LINUX_PROBE: notification show/cancel passed');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final png = await capture.capturePngBytes();
    if (png == null || png.isEmpty) throw StateError('Screenshot missing');
    await const MethodChannel(
      'com.focubili.app/windows_experience',
    ).invokeMethod<void>('copyImage', {'png': png});
    stdout.writeln('LINUX_CLIPBOARD_READY');
    await stdout.flush();
    await Future<void>.delayed(const Duration(seconds: 2));
    final bounds = await windowManager.getBounds();
    for (var i = 0; i < 2; i++) {
      if (!await mini.toggle(16 / 9) || !mini.active) {
        throw StateError('Mini-player did not activate');
      }
      stdout.writeln('LINUX_MINI_READY');
      await stdout.flush();
      await Future<void>.delayed(const Duration(seconds: 2));
      await mini.restore();
      if (mini.active) throw StateError('Mini-player did not restore');
      final restored = await windowManager.getBounds();
      if ((restored.width - bounds.width).abs() > 2 ||
          (restored.height - bounds.height).abs() > 2) {
        throw StateError('Window bounds not restored');
      }
    }
    for (var i = 0; i < 2; i++) {
      final webview = await WebviewWindow.create(
        configuration: const CreateConfiguration(
          title: 'Linux login window QA',
          windowWidth: 640,
          windowHeight: 480,
        ),
      );
      await webview.setUserAgent('FocuBili synthetic QA');
      await webview.setAllowedNavigationHosts(['graph.qq.com']);
      final cookies = await webview.getCookiesForUrl(
        'https://api.bilibili.com/x/web-interface/nav',
      );
      if (cookies.isNotEmpty) {
        throw StateError('New ephemeral window has cookies');
      }
      final pending = webview.getCookiesForUrl('https://www.bilibili.com/');
      webview.close();
      try {
        await pending;
      } on PlatformException {
        /* Closing may reject the read. */
      }
      await webview.onClose.timeout(const Duration(seconds: 10));
    }
    stdout.writeln('LINUX_PROBE: ephemeral WebKit windows repeat-close passed');
    await media.delete();
    success = true;
    stdout.writeln('LINUX_RUNTIME_ALL_CHECKS_PASSED');
  } catch (error, stack) {
    stderr.writeln('LINUX_RUNTIME_FAILED: $error\n$stack');
  } finally {
    await mini.restore();
    await bus?.close();
    await session.dispose();
    await player?.dispose();
    await stdout.flush();
    await stderr.flush();
    exit(success ? 0 : 1);
  }
}
