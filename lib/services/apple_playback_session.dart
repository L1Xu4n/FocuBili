import 'dart:async';
import 'package:flutter/services.dart';
import '../platform/app_platform.dart';

/// Bridges media_kit to Apple's audio session and lock-screen transport controls.
class ApplePlaybackSession {
  static const _channel = MethodChannel('com.focubili.app/apple_media');
  static ApplePlaybackSession? _owner;
  final bool enabled = AppPlatformDetector.current.isApple;
  bool _disposed = false;
  int _lastSecond = -1;
  bool? _lastPlaying;

  Future<void> initialize({
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function(Duration) seek,
  }) async {
    if (!enabled) return;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (_disposed || _owner != this) return;
      switch (call.method) {
        case 'play':
          await play();
        case 'pause':
          await pause();
        case 'seek':
          final seconds = call.arguments;
          if (seconds is num && seconds.isFinite && seconds >= 0) {
            await seek(Duration(milliseconds: (seconds * 1000).round()));
          }
      }
    });
    await _channel.invokeMethod<void>('activate');
  }

  void update({
    required String title,
    required Duration position,
    required Duration duration,
    required bool playing,
    required double speed,
  }) {
    if (!enabled || _disposed || _owner != this) return;
    if (_lastSecond == position.inSeconds && _lastPlaying == playing) return;
    _lastSecond = position.inSeconds;
    _lastPlaying = playing;
    unawaited(
      _channel
          .invokeMethod<void>('update', {
            'title': title,
            'position': position.inMilliseconds / 1000,
            'duration': duration.inMilliseconds / 1000,
            'rate': playing ? speed : 0.0,
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    if (!enabled || _owner != this) return;
    _owner = null;
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod<void>('deactivate');
  }
}
