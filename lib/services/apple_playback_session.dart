import 'dart:async';
import 'package:flutter/services.dart';
import '../platform/app_platform.dart';

/// Bridges media_kit to Apple's audio session and lock-screen transport controls.
class ApplePlaybackSession {
  ApplePlaybackSession({AppPlatform? platform})
    : enabled = (platform ?? AppPlatformDetector.current).isApple;

  static const _channel = MethodChannel('com.focubili.app/apple_media');
  static ApplePlaybackSession? _owner;
  final bool enabled;
  bool _disposed = false;
  bool isInPictureInPicture = false;
  int _lastSecond = -1;
  bool? _lastPlaying;
  String? _lastTitle;
  Duration? _lastDuration;
  double? _lastSpeed;

  Future<void> initialize({
    int? handle,
    void Function(bool)? onPictureInPictureChanged,
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required Future<void> Function(Duration) seek,
  }) async {
    if (!enabled || _disposed) return;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (_disposed || _owner != this) return;
      switch (call.method) {
        case 'pipStateChanged':
          isInPictureInPicture = call.arguments == true;
          onPictureInPictureChanged?.call(isInPictureInPicture);
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
    await _channel.invokeMethod<void>('activate', {'handle': ?handle});
  }

  void update({
    required String title,
    required Duration position,
    required Duration duration,
    required bool playing,
    required double speed,
  }) {
    if (!enabled || _disposed || _owner != this) return;
    if (_lastSecond == position.inSeconds &&
        _lastPlaying == playing &&
        _lastTitle == title &&
        _lastDuration == duration &&
        _lastSpeed == speed) {
      return;
    }
    _lastSecond = position.inSeconds;
    _lastPlaying = playing;
    _lastTitle = title;
    _lastDuration = duration;
    _lastSpeed = speed;
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

  Future<bool> startPictureInPicture(Rect rect) async {
    if (!enabled ||
        _disposed ||
        _owner != this ||
        rect.isEmpty ||
        !rect.isFinite) {
      return false;
    }
    return await _channel.invokeMethod<bool>('startPiP', {
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
        }) ??
        false;
  }

  Future<void> dispose() async {
    _disposed = true;
    if (!enabled || _owner != this) return;
    _owner = null;
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod<void>('deactivate');
  }
}
