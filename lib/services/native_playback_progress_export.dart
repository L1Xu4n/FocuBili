import 'package:flutter/services.dart';

/// Reads persisted Android progress without acquiring a player or flushing writes.
class NativePlaybackProgressExport {
  const NativePlaybackProgressExport({
    MethodChannel channel = const MethodChannel('com.focubili.app/playback'),
  }) : _channel = channel;

  final MethodChannel _channel;
  static const format = 'focubili.native-playback-progress';
  static const _maximumTimestamp = 253402300799999;
  static final _bv = RegExp(r'^[bB][vV][0-9A-Za-z]{10}$');
  static final _course = RegExp(r'^CHEESE:SS([1-9][0-9]*)$');

  Future<Map<String, Object>> read() async {
    try {
      return validate(
        await _channel.invokeMethod<Object?>('exportSavedPlaybackProgress'),
      );
    } on PlatformException {
      throw StateError('Android playback progress is unavailable');
    } on MissingPluginException {
      throw StateError('Android playback progress is unavailable');
    }
  }

  /// Validate even injected loaders: an export never accepts arbitrary native maps.
  static Map<String, Object> validate(Object? value) {
    if (value is! Map ||
        value.keys.toSet().difference(_documentFields).isNotEmpty ||
        value.length != _documentFields.length ||
        value['format'] != format ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['lastParts'] is! List ||
        value['parts'] is! List) {
      throw const FormatException('Invalid Android progress document');
    }
    final lastParts = <Map<String, Object>>[];
    final parts = <Map<String, Object>>[];
    final lastIds = <String>{};
    final partIds = <String>{};
    for (final raw in value['lastParts'] as List) {
      if (raw is! Map ||
          raw.keys.toSet().difference(_lastFields).isNotEmpty ||
          raw.length != _lastFields.length ||
          !_identity(raw['bvid']) ||
          !_positive(raw['cid']) ||
          !_positive(raw['pageNumber']) ||
          (raw['pageNumber'] as int) > 2147483647 ||
          !lastIds.add(raw['bvid'] as String)) {
        throw const FormatException('Invalid Android last-part record');
      }
      lastParts.add({
        'bvid': raw['bvid'] as String,
        'cid': raw['cid'] as int,
        'pageNumber': raw['pageNumber'] as int,
      });
    }
    for (final raw in value['parts'] as List) {
      if (raw is! Map ||
          raw.keys.toSet().difference(_partFields).isNotEmpty ||
          !_identity(raw['bvid']) ||
          !_positive(raw['cid']) ||
          !partIds.add('${raw['bvid']}:${raw['cid']}')) {
        throw const FormatException('Invalid Android part progress');
      }
      final hasPosition = raw.containsKey('positionMs');
      final hasDuration = raw.containsKey('durationMs');
      final hasTimestamp = raw.containsKey('savedAtMs');
      if (hasPosition != hasDuration ||
          (!hasPosition && !hasTimestamp) ||
          (hasPosition &&
              (!_nonnegative(raw['positionMs']) ||
                  !_positive(raw['durationMs']) ||
                  (raw['positionMs'] as int) > (raw['durationMs'] as int))) ||
          (hasTimestamp &&
              (!_nonnegative(raw['savedAtMs']) ||
                  (raw['savedAtMs'] as int) > _maximumTimestamp))) {
        throw const FormatException('Invalid Android progress values');
      }
      parts.add({
        'bvid': raw['bvid'] as String,
        'cid': raw['cid'] as int,
        if (hasPosition) 'positionMs': raw['positionMs'] as int,
        if (hasDuration) 'durationMs': raw['durationMs'] as int,
        if (hasTimestamp) 'savedAtMs': raw['savedAtMs'] as int,
      });
    }
    lastParts.sort(
      (a, b) => (a['bvid'] as String).compareTo(b['bvid'] as String),
    );
    parts.sort((a, b) {
      final identity = (a['bvid'] as String).compareTo(b['bvid'] as String);
      return identity != 0
          ? identity
          : (a['cid'] as int).compareTo(b['cid'] as int);
    });
    return {
      'format': format,
      'version': 1,
      'lastParts': lastParts,
      'parts': parts,
    };
  }

  static bool _identity(Object? value) {
    if (value is! String) return false;
    if (_bv.firstMatch(value)?.end == value.length) return true;
    final match = _course.firstMatch(value);
    return match != null &&
        match.end == value.length &&
        (int.tryParse(match.group(1)!) ?? 0) > 0;
  }

  static bool _positive(Object? value) => value is int && value > 0;
  static bool _nonnegative(Object? value) => value is int && value >= 0;
  static const _documentFields = {'format', 'version', 'lastParts', 'parts'};
  static const _lastFields = {'bvid', 'cid', 'pageNumber'};
  static const _partFields = {
    'bvid',
    'cid',
    'positionMs',
    'durationMs',
    'savedAtMs',
  };
}
