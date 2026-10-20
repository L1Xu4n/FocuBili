import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/player_overlay_data.dart';

/// Bounded, memory-only provenance. No text, URL, signature or cookie fields.
class SubtitleDiagnosticLog {
  static final instance = SubtitleDiagnosticLog();
  final _events = <Map<String, Object>>[];
  int _sequence = 0;
  static final _bvid = RegExp(r'^BV[0-9A-Za-z]{10}$');
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  static const _stages = {
    'metadata-request',
    'metadata-response',
    'document-response',
    'cache-hit',
    'cache-write',
    'select-request',
    'present',
    'request-error',
    'identity-rejected',
    'duration-warning',
  };
  static const _sources = {
    'android-http',
    'dart-http',
    'native-bridge',
    'memory-cache',
    'player-ui',
  };

  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String digestBytes(List<int> value) =>
      sha256.convert(value).toString();
  static String resourceId(Uri url, String language) =>
      digest('${url.path.length}:${url.path}${language.length}:$language');

  static String cueHash(List<SubtitleCue> cues) => digest(
    jsonEncode([
      for (final cue in cues)
        [cue.from.inMilliseconds, cue.to.inMilliseconds, cue.content],
    ]),
  );

  void record({
    required String bvid,
    required int cid,
    required String stage,
    required String source,
    Map<Object?, Object?> facts = const {},
  }) {
    if (!_bvid.hasMatch(bvid) ||
        cid <= 0 ||
        !_stages.contains(stage) ||
        !_sources.contains(source)) {
      return;
    }
    final event = <String, Object>{
      'seq': ++_sequence,
      'bvid': bvid,
      'cid': cid,
      'stage': stage,
      'source': source,
    };
    for (final key in [
      'requestId',
      'aid',
      'responseCid',
      'responseAid',
      'httpStatus',
      'apiCode',
      'cueCount',
      'bytes',
      'durationMs',
      'maxCueEndMs',
      'selectionGeneration',
    ]) {
      final value = facts[key];
      if (value is num && value.isFinite) event[key] = value.toInt();
    }
    for (final key in [
      'documentId',
      'bodyHash',
      'cuesHash',
      'trackSetHash',
      'metadataHash',
    ]) {
      final value = facts[key];
      if (value is String && _hash.hasMatch(value)) event[key] = value;
    }
    final responseBvid = facts['responseBvid'];
    if (responseBvid is String && _bvid.hasMatch(responseBvid)) {
      event['responseBvid'] = responseBvid;
    }
    final trackId = facts['trackId'];
    if (trackId is String && RegExp(r'^[0-9]{1,32}$').hasMatch(trackId)) {
      event['trackId'] = trackId;
    }
    final language = facts['language'];
    if (language is String &&
        RegExp(r'^[a-zA-Z0-9-]{1,32}$').hasMatch(language)) {
      event['language'] = language;
    }
    if (const {
      '/x/player/v2',
      '/x/player/wbi/v2',
      '/x/web-interface/nav',
      'document',
    }.contains(facts['endpoint'])) {
      event['endpoint'] = facts['endpoint']! as String;
    }
    if (facts['signed'] is bool) event['signed'] = facts['signed']! as bool;
    final error = facts['errorCode'];
    if (error is String && RegExp(r'^subtitle_[a-z_]{1,40}$').hasMatch(error)) {
      event['errorCode'] = error;
    }
    _events.add(event);
    if (_events.length > 80) _events.removeAt(0);
  }

  String report({String? bvid, int? cid}) => [
    'FocuBili subtitle provenance (memory only; no text, cookies or URLs)',
    'Metadata requests use bvid/cid; aid is not sent. responseAid is from the server.',
    for (final event in _events)
      if ((bvid == null || event['bvid'] == bvid) &&
          (cid == null || event['cid'] == cid))
        jsonEncode(event),
  ].join('\n');
}
