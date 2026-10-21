/// A second allowlist at the platform boundary. Runtime data stays in process memory.
class MediaRuntimeDiagnostic {
  const MediaRuntimeDiagnostic._(this.fields);

  static const maximumEvents = 64;
  static const maximumNumber = 9007199254740991;
  final Map<String, String> fields;

  static const _events = {
    'open',
    'request',
    'prepare',
    'state',
    'seek',
    'first_frame',
    'buffer_end',
    'load_start',
    'load_end',
    'load_error',
    'load_cancel',
    'decoder',
    'format',
    'player_error',
    'summary',
    'track_summary',
  };
  static const _numbers = {
    'session_id',
    'attempt',
    'elapsed_ms',
    'request_id',
    'queue_ms',
    'source_ms',
    'api_ms',
    'duration_ms',
    'bytes',
    'load_id',
    'error_code',
    'http_status',
    'first_frame_ms',
    'prepare_to_frame_ms',
    'buffered_ms',
    'position_ms',
    'rebuffer_count',
    'rebuffer_ms',
    'dropped_frames',
    'width',
    'height',
    'bitrate',
    'quality',
    'video_candidate',
    'audio_candidate',
    'init_ms',
  };
  static const _enums = {
    'backend': {'mpv_ios'},
    'render_path': {'cpu_bgr0'},
    'decode_preference': {'automatic', 'videoToolbox', 'software'},
    'decode_option_status': {
      'not_applied',
      'accepted',
      'fallback_auto',
      'unavailable',
    },
    'hwdec_configured': {'auto-copy', 'videotoolbox-copy', 'no'},
    'hwdec_current': {'no', 'videotoolbox', 'videotoolbox-copy'},
    'codec_family': {
      'h264',
      'hevc',
      'av1',
      'vp9',
      'vp8',
      'mpeg4',
      'mpeg2video',
    },
    'transfer': {
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
    'track': {'video', 'audio', 'muxed'},
    'state': {'idle', 'buffering', 'ready', 'ended'},
    'buffer_reason': {'initial', 'rebuffer', 'seek', 'recovery'},
    'reason': {'superseded', 'released', 'error'},
    'outcome': {'success', 'error'},
    'cause': {'timeout', 'http', 'io', 'other'},
    'mime': {
      'video/avc',
      'video/hevc',
      'video/av01',
      'video/mp4v-es',
      'audio/mp4a-latm',
      'audio/opus',
      'audio/flac',
      'audio/eac3',
      'audio/ac3',
    },
  };
  static final _decoder = RegExp(r'^(?:OMX\.|c2\.)[A-Za-z0-9_.-]{1,90}$');
  static final _codec = RegExp(
    r'^(?:avc[13]|hev1|hvc1|av01|mp4a)(?:\.[A-Za-z0-9]{1,12}){1,6}$',
  );

  static List<MediaRuntimeDiagnostic> parse(Object? raw) {
    if (raw is! List) return const [];
    final records = <MediaRuntimeDiagnostic>[];
    for (
      var i = (raw.length - maximumEvents).clamp(0, raw.length);
      i < raw.length;
      i++
    ) {
      final item = raw[i];
      if (item is! Map || !_events.contains(item['event'])) continue;
      final fields = <String, String>{'event': item['event'] as String};
      for (final key in _numbers) {
        final value = item[key];
        if (value is int && value >= 0 && value <= maximumNumber) {
          fields[key] = value.toString();
        }
      }
      if (!fields.containsKey('session_id') ||
          !fields.containsKey('elapsed_ms')) {
        continue;
      }
      for (final key in ['local', 'play_requested', 'cache_bypass']) {
        final value = item[key];
        if (value is bool) fields[key] = value.toString();
      }
      for (final entry in _enums.entries) {
        final value = item[entry.key];
        if (value is String && entry.value.contains(value)) {
          fields[entry.key] = value;
        }
      }
      for (final key in ['speed', 'fps']) {
        final value = item[key];
        if (value is num &&
            value.isFinite &&
            value >= 0.1 &&
            value <= (key == 'speed' ? 5 : 1000)) {
          fields[key] = value.toString();
        }
      }
      for (final entry in {'decoder': _decoder, 'codec': _codec}.entries) {
        final value = item[entry.key];
        if (value is String &&
            value.length <= 96 &&
            entry.value.matchAsPrefix(value)?.end == value.length) {
          fields[entry.key] = value;
        }
      }
      if (item['backend'] == 'mpv_ios') {
        if (const {
          'h264',
          'hevc',
          'av1',
          'vp9',
          'vp8',
          'libdav1d',
          'libaom-av1',
        }.contains(item['decoder'])) {
          fields['decoder'] = item['decoder'] as String;
        }
        final version = item['mpv_version'];
        if (version is String &&
            RegExp(
              r'^mpv [0-9]{1,2}\.[0-9]{1,3}\.[0-9]{1,3}$',
            ).hasMatch(version)) {
          fields['mpv_version'] = version;
        }
      }
      records.add(MediaRuntimeDiagnostic._(Map.unmodifiable(fields)));
    }
    return List.unmodifiable(records);
  }
}
