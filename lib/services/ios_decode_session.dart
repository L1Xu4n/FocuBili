import 'dart:async';

import '../models/ios_decode_preferences.dart';
import '../models/playback_preferences.dart';
import '../platform/app_platform.dart';

typedef DecodePropertyReader = Future<String> Function(String name);
typedef DecodePropertyWriter = Future<void> Function(String name, String value);

/// Owns option writes and on-demand diagnostic reads until player disposal.
/// No timer, native logs, URLs, file paths or persistent telemetry are used.
class IosDecodeSession {
  IosDecodeSession({
    required AppPlatform platform,
    required this.loadPreferences,
    required this.readProperty,
    required this.writeProperty,
    required this.canReadVideo,
  }) : enabled = supportsIosDecodePreferences(platform) {
    if (enabled) _active.add(this);
  }

  final bool enabled;
  final Future<PlaybackPreferences> Function() loadPreferences;
  final DecodePropertyReader readProperty;
  final DecodePropertyWriter writeProperty;
  final bool Function() canReadVideo;
  static final _active = <IosDecodeSession>{};
  static final _events = <Map<String, Object>>[];
  static int _nextId = 0;
  int _id = ++_nextId;
  int _revision = 0;
  final _clock = Stopwatch()..start();
  bool _disposed = false;
  Future<void> _operations = Future.value();
  IosDecodeMode _requested = IosDecodeMode.automatic;
  String _status = 'not_applied';
  String? _applied;
  bool _capturedReady = false;

  void beginSource() {
    _revision++;
    _id = ++_nextId;
    _clock.reset();
    _status = 'not_applied';
    _applied = null;
    _capturedReady = false;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Called before each media open, after VideoController has initialized.
  /// mpv 0.36 supports runtime hwdec changes; the next open initializes the
  /// decoder again, so rebuilding the texture or route is unnecessary.
  Future<bool> configure({
    required bool Function() isCurrent,
  }) => _serial(() async {
    bool current() => !_disposed && isCurrent();
    if (!enabled) return current();
    if (!current()) return false;
    var mode = IosDecodeMode.automatic;
    try {
      mode = (await loadPreferences()).iosDecodeMode;
    } catch (_) {}
    if (!current()) return false;
    _requested = mode;
    for (final candidate in <IosDecodeMode>{mode, IosDecodeMode.automatic}) {
      if (!current()) return false;
      try {
        await writeProperty('hwdec', candidate.hwdec);
        if (!current()) return false;
        final actual = await readProperty('hwdec');
        if (!current()) return false;
        if (actual == candidate.hwdec) {
          _applied = actual;
          _status = candidate == mode ? 'accepted' : 'fallback_auto';
          return true;
        }
      } catch (_) {
        // media_kit 1.2.6 discards mpv's setProperty status: readback is required.
      }
    }
    _applied = null;
    _status = 'unavailable';
    // Keep playback available; diagnostics explicitly report the failed setting.
    return current();
  });

  Future<Map<String, Object>?> _sample() => _serial(() async {
    if (_disposed) return null;
    final revision = _revision;
    final fields = <String, Object>{
      'event': 'summary',
      'session_id': _id,
      'elapsed_ms': _clock.elapsedMilliseconds,
      'backend': 'mpv_ios',
      'render_path': 'cpu_bgr0',
      'decode_preference': _requested.name,
      'decode_option_status': _status,
      'hwdec_configured': ?_applied,
    };
    if (!canReadVideo()) return fields;
    // Only these literal property names can cross this boundary. No track-list,
    // metadata, native error text, or URLs are ever requested.
    const properties = {
      'hwdec-current': 'hwdec_current',
      'video-format': 'codec_family',
      'video-codec': 'decoder',
      'container-fps': 'fps',
      'width': 'width',
      'height': 'height',
      'frame-drop-count': 'dropped_frames',
      'speed': 'speed',
      'video-params/gamma': 'transfer',
      'mpv-version': 'mpv_version',
    };
    for (final entry in properties.entries) {
      if (_disposed || revision != _revision || !canReadVideo()) return null;
      try {
        final raw = await readProperty(entry.key);
        if (_disposed || revision != _revision || !canReadVideo()) return null;
        final value = _safeProperty(entry.value, raw);
        if (value != null) fields[entry.value] = value;
      } catch (_) {
        // An unavailable property remains absent, never inferred from options.
      }
    }
    return fields;
  });

  static Object? _safeProperty(String key, String raw) {
    if (key == 'fps' || key == 'speed') {
      final value = double.tryParse(raw);
      return value != null &&
              value.isFinite &&
              value > 0 &&
              value <= (key == 'speed' ? 5 : 1000)
          ? value
          : null;
    }
    if (['width', 'height', 'dropped_frames'].contains(key)) {
      final value = int.tryParse(raw);
      return value != null && value >= 0 && value <= 9007199254740991
          ? value
          : null;
    }
    final allowed = switch (key) {
      'hwdec_current' => {'no', 'videotoolbox', 'videotoolbox-copy'},
      'codec_family' => {
        'h264',
        'hevc',
        'av1',
        'vp9',
        'vp8',
        'mpeg4',
        'mpeg2video',
      },
      'transfer' => {
        'bt.1886',
        'srgb',
        'linear',
        'gamma1.8',
        'gamma2.0',
        'gamma2.2',
        'gamma2.4',
        'gamma2.6',
        'gamma2.8',
        'prophoto',
        'pq',
        'hlg',
        'v-log',
        's-log1',
        's-log2',
        'auto',
      },
      _ => const <String>{},
    };
    if (allowed.contains(raw)) return raw;
    if (key == 'decoder') {
      // Preserve only exact known mpv/FFmpeg decoder descriptions.
      const descriptions = {
        'h264': 'h264',
        'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)': 'h264',
        'hevc': 'hevc',
        'hevc (HEVC (High Efficiency Video Coding))': 'hevc',
        'av1': 'av1',
        'libdav1d (dav1d AV1 decoder by VideoLAN)': 'libdav1d',
        'libaom-av1 (libaom AV1)': 'libaom-av1',
        'vp9': 'vp9',
        'vp8': 'vp8',
      };
      return descriptions[raw];
    }
    if (key == 'mpv_version' &&
        RegExp(r'^mpv [0-9]{1,2}\.[0-9]{1,3}\.[0-9]{1,3}$').hasMatch(raw)) {
      return raw;
    }
    return null;
  }

  static Future<List<Map<String, Object>>> readDiagnostics() async {
    for (final session in _active.toList()) {
      await session.capture();
    }
    return List.unmodifiable(_events);
  }

  /// One sample per newly ready source lets diagnostics survive closing the
  /// player route. Later samples are only taken on an explicit refresh.
  void captureReady() {
    if (!enabled || _disposed || _capturedReady || !canReadVideo()) return;
    _capturedReady = true;
    unawaited(capture());
  }

  Future<void> capture() async {
    if (!enabled || _disposed) return;
    final record = await _sample();
    if (record != null && !_disposed) {
      _events.add(Map.unmodifiable(record));
      if (_events.length > 64) _events.removeAt(0);
    }
  }

  static void clearDiagnostics() => _events.clear();

  Future<void> dispose() async {
    _disposed = true;
    _active.remove(this);
    await _operations;
    _clock.stop();
  }
}
