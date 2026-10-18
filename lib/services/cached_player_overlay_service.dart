import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/player_overlay_data.dart';
import 'cache_lifecycle.dart';
import 'player_overlay_service.dart';

/// Optional lifecycle for implementations which hold temporary subtitle URLs.
abstract interface class SubtitleSessionInvalidator {
  Future<void> clearSubtitleSessions();
}

/// Parsed subtitle payloads stay in RAM only. The byte budget measures UTF-8
/// text plus timestamps, not VM heap size; current UI cues are a separate lease.
class SubtitleMemoryCache {
  SubtitleMemoryCache({this.capacityBytes = 8 * 1024 * 1024}) {
    CacheLifecycle.subtitles.addListener(clear);
  }
  static final instance = SubtitleMemoryCache();
  final int capacityBytes;
  final usage = ValueNotifier<int>(0);
  final _entries =
      <Object, ({SubtitleCueLoadResult value, int size, DateTime expires})>{};

  SubtitleCueLoadResult? get(Object key, DateTime now) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (!entry.expires.isAfter(now)) {
      usage.value -= entry.size;
      return null;
    }
    _entries[key] = entry;
    return entry.value;
  }

  void put(Object key, SubtitleCueLoadResult value, DateTime now) {
    final size = value.cues.fold<int>(
      0,
      (sum, cue) => sum + utf8.encode(cue.content).length + 16,
    );
    if (size > capacityBytes) return;
    removeWhere((candidate) => candidate == key);
    while (_entries.isNotEmpty &&
        (usage.value + size > capacityBytes || _entries.length >= 64)) {
      usage.value -= _entries.remove(_entries.keys.first)!.size;
    }
    _entries[key] = (
      value: value,
      size: size,
      expires: now.add(const Duration(minutes: 5)),
    );
    usage.value += size;
  }

  void removeWhere(bool Function(Object) test) {
    for (final key in _entries.keys.where(test).toList()) {
      usage.value -= _entries.remove(key)!.size;
    }
  }

  void clear() {
    _entries.clear();
    usage.value = 0;
  }

  void dispose() {
    CacheLifecycle.subtitles.removeListener(clear);
    usage.dispose();
  }
}

/// Cue reuse is bound to the exact successful metadata generation, BV/CID,
/// track and account/clear revision. Failed refreshes preserve valid sessions.
class CachedPlayerOverlayService implements PlayerOverlayService {
  CachedPlayerOverlayService(
    this.delegate, {
    SubtitleMemoryCache? cache,
    DateTime Function()? clock,
  }) : _cache = cache ?? SubtitleMemoryCache.instance,
       _clock = clock ?? DateTime.now {
    CacheLifecycle.subtitles.addListener(_clear);
  }
  final PlayerOverlayService delegate;
  final SubtitleMemoryCache _cache;
  final DateTime Function() _clock;
  final _sessions = <(String, int), Object>{};
  final _trackRequests = <(String, int), Object>{};
  final _pending = <Object, Future<SubtitleCueLoadResult>>{};
  Future<void> _clearing = Future.value();

  void _clear() {
    _sessions.clear();
    _trackRequests.clear();
    _pending.clear();
    if (delegate case final SubtitleSessionInvalidator invalidator) {
      _clearing = invalidator.clearSubtitleSessions().catchError((Object _) {});
    }
  }

  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async {
    final identity = (bvid, cid);
    final token = Object();
    final revision = CacheLifecycle.subtitles.value;
    _trackRequests[identity] = token;
    await _clearing;
    final SubtitleTrackLoadResult result;
    try {
      result = await delegate.loadSubtitleTracks(bvid: bvid, cid: cid);
    } catch (_) {
      if (_trackRequests[identity] == token) _trackRequests.remove(identity);
      rethrow;
    }
    if (revision != CacheLifecycle.subtitles.value ||
        _trackRequests[identity] != token) {
      return const SubtitleTrackLoadResult.unavailable();
    }
    _trackRequests.remove(identity);
    if (result.status != SubtitleLoadStatus.unavailable) {
      final old = _sessions.remove(identity);
      if (old != null) {
        _cache.removeWhere((key) => key is (Object, String) && key.$1 == old);
      }
      _sessions[identity] = Object();
      while (_sessions.length > 8) {
        final removed = _sessions.remove(_sessions.keys.first);
        _cache.removeWhere(
          (key) => key is (Object, String) && key.$1 == removed,
        );
      }
    }
    return result;
  }

  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async {
    final identity = (bvid, cid);
    final session = _sessions.remove(identity);
    if (session == null) {
      return const SubtitleCueLoadResult.locked(message: '请刷新字幕列表后重新选择。');
    }
    _sessions[identity] = session;
    final key = (session, trackId);
    final cached = _cache.get(key, _clock());
    if (cached != null) return cached;
    final operation = _pending.putIfAbsent(key, () async {
      final revision = CacheLifecycle.subtitles.value;
      final result = await delegate.loadSubtitleCues(
        bvid: bvid,
        cid: cid,
        trackId: trackId,
      );
      if (revision != CacheLifecycle.subtitles.value ||
          _sessions[identity] != session) {
        return const SubtitleCueLoadResult.unavailable(
          message: '字幕已更新，请重新选择轨道。',
        );
      }
      if (result.status == SubtitleLoadStatus.available) {
        _cache.put(key, result, _clock());
      }
      return result;
    });
    try {
      return await operation;
    } finally {
      if (identical(_pending[key], operation)) _pending.remove(key);
    }
  }

  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) => delegate.loadDanmakuSegment(
    bvid: bvid,
    cid: cid,
    segmentIndex: segmentIndex,
  );

  void dispose() {
    CacheLifecycle.subtitles.removeListener(_clear);
    _clear();
  }
}
