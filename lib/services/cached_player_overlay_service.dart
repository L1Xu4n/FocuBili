import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/player_overlay_data.dart';
import 'cache_lifecycle.dart';
import 'player_overlay_service.dart';
import 'subtitle_diagnostic_log.dart';

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
      <
        Object,
        ({
          SubtitleCueLoadResult value,
          int size,
          DateTime expires,
          String? bvid,
          int? cid,
          String? trackId,
        })
      >{};

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

  /// 转移已完成且有效的正文，保留原始过期时间和字节计数。
  void _move(Object from, Object to, DateTime now) {
    if (get(from, now) == null) return;
    _entries[to] = _entries.remove(from)!;
  }

  void put(
    Object key,
    SubtitleCueLoadResult value,
    DateTime now, {
    String? bvid,
    int? cid,
    String? trackId,
  }) {
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
      bvid: bvid,
      cid: cid,
      trackId: trackId,
    );
    usage.value += size;
  }

  /// Only parsed text/timestamps and public video identities leave this cache.
  /// Session tokens, account revision markers and temporary URLs stay private.
  List<Map<String, Object?>> exportCues(DateTime now) => [
    for (final entry in _entries.values)
      if (entry.expires.isAfter(now) &&
          entry.bvid != null &&
          entry.cid != null &&
          entry.trackId != null)
        {
          'bvid': entry.bvid,
          'cid': entry.cid,
          'trackId': entry.trackId,
          'cues': [
            for (final cue in entry.value.cues)
              {
                'fromMs': cue.from.inMilliseconds,
                'toMs': cue.to.inMilliseconds,
                'content': cue.content,
              },
          ],
        },
  ];

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
  /// 注入时钟和弹幕缓存上限，便于验证缓存淘汰与竞态。
  CachedPlayerOverlayService(
    this.delegate, {
    SubtitleMemoryCache? cache,
    DateTime Function()? clock,
    this.danmakuCapacityBytes = 16 * 1024 * 1024,
    this.danmakuCapacitySegments = 24,
    this.danmakuTtl = const Duration(minutes: 30),
  }) : _cache = cache ?? SubtitleMemoryCache.instance,
       _clock = clock ?? DateTime.now {
    CacheLifecycle.subtitles.addListener(_clear);
  }
  final PlayerOverlayService delegate;
  final SubtitleMemoryCache _cache;
  final DateTime Function() _clock;
  final _sessions = <(String, int), (Object, List<SubtitleTrack>)>{};
  final _trackRequests = <(String, int), Object>{};
  final _pending = <Object, Future<SubtitleCueLoadResult>>{};
  final int danmakuCapacityBytes;
  final int danmakuCapacitySegments;
  final Duration danmakuTtl;
  final _danmaku = <Object, (DateTime, int, DanmakuSegmentLoadResult)>{};
  final _danmakuPending = <Object, Future<DanmakuSegmentLoadResult>>{};
  int _danmakuBytes = 0;
  int _epoch = 0;
  Future<void> _clearing = Future.value();

  /// 释放当前代次的会话和弹幕，拒绝清理前的异步响应。
  void _clear() {
    _epoch++;
    _sessions.clear();
    _trackRequests.clear();
    _pending.clear();
    _danmaku.clear();
    _danmakuPending.clear();
    _danmakuBytes = 0;
    if (delegate case final SubtitleSessionInvalidator invalidator) {
      _clearing = invalidator.clearSubtitleSessions().catchError((Object _) {});
    }
  }

  /// 每次调用代表一次新的轨道刷新，后来者取代旧在途请求，成功时迁移同文档 ID 的已完成正文。
  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async {
    final identity = (bvid, cid);
    final requestToken = Object();
    final epoch = _epoch;
    final revision = CacheLifecycle.subtitles.value;
    _trackRequests[identity] = requestToken;
    await _clearing;
    if (epoch != _epoch ||
        revision != CacheLifecycle.subtitles.value ||
        !identical(_trackRequests[identity], requestToken)) {
      return const SubtitleTrackLoadResult.unavailable();
    }
    final SubtitleTrackLoadResult result;
    try {
      result = await delegate.loadSubtitleTracks(bvid: bvid, cid: cid);
    } catch (_) {
      if (identical(_trackRequests[identity], requestToken)) {
        _trackRequests.remove(identity);
      }
      rethrow;
    }
    if (epoch != _epoch ||
        revision != CacheLifecycle.subtitles.value ||
        !identical(_trackRequests[identity], requestToken)) {
      return const SubtitleTrackLoadResult.unavailable();
    }
    _trackRequests.remove(identity);
    if (result.status != SubtitleLoadStatus.unavailable) {
      final old = _sessions.remove(identity);
      final token = Object();
      if (old != null) {
        final previousTracks = {for (final track in old.$2) track.id: track};
        for (final track in result.tracks) {
          final previous = previousTracks[track.id];
          if (track.documentId.trim().isNotEmpty &&
              previous?.documentId == track.documentId &&
              previous?.language == track.language) {
            _cache._move((old.$1, track.id), (token, track.id), _clock());
          }
        }
        _cache.removeWhere(
          (key) => key is (Object, String) && key.$1 == old.$1,
        );
      }
      _sessions[identity] = (
        token,
        List<SubtitleTrack>.unmodifiable(result.tracks),
      );
      while (_sessions.length > 8) {
        final removed = _sessions.remove(_sessions.keys.first);
        _cache.removeWhere(
          (key) => key is (Object, String) && key.$1 == removed?.$1,
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
    final key = (session.$1, trackId);
    final cached = _cache.get(key, _clock());
    if (cached != null) {
      SubtitleDiagnosticLog.instance.record(
        bvid: bvid,
        cid: cid,
        stage: 'cache-hit',
        source: 'memory-cache',
        facts: {
          'trackId': trackId,
          'cuesHash': SubtitleDiagnosticLog.cueHash(cached.cues),
        },
      );
      return cached;
    }
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
        _cache.put(
          key,
          result,
          _clock(),
          bvid: bvid,
          cid: cid,
          trackId: trackId,
        );
        SubtitleDiagnosticLog.instance.record(
          bvid: bvid,
          cid: cid,
          stage: 'cache-write',
          source: 'memory-cache',
          facts: {
            'trackId': trackId,
            'cuesHash': SubtitleDiagnosticLog.cueHash(result.cues),
          },
        );
      }
      return result;
    });
    try {
      return await operation;
    } finally {
      if (identical(_pending[key], operation)) _pending.remove(key);
    }
  }

  /// 按分段合并并复用成功弹幕，失败结果允许立即重试。
  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    final key = (CacheLifecycle.account.value, _epoch, bvid, cid, segmentIndex);
    final cached = _danmaku.remove(key);
    if (cached != null) {
      if (_clock().isBefore(cached.$1)) {
        _danmaku[key] = cached;
        return cached.$3;
      }
      _danmakuBytes -= cached.$2;
    }
    final work = _danmakuPending.putIfAbsent(key, () async {
      final result = await delegate.loadDanmakuSegment(
        bvid: bvid,
        cid: cid,
        segmentIndex: segmentIndex,
      );
      if (key.$1 != CacheLifecycle.account.value || key.$2 != _epoch) {
        return DanmakuSegmentLoadResult.unavailable(segmentIndex: segmentIndex);
      }
      if (result.status != DanmakuLoadStatus.unavailable) {
        _rememberDanmaku(key, result);
      }
      return result;
    });
    try {
      return await work;
    } finally {
      if (identical(_danmakuPending[key], work)) _danmakuPending.remove(key);
    }
  }

  /// 按 UTF-8 正文和每条弹幕的字段估算缓存开销。
  void _rememberDanmaku(Object key, DanmakuSegmentLoadResult result) {
    final size = result.entries.fold<int>(
      0,
      (bytes, entry) => bytes + 24 + utf8.encode(entry.content).length,
    );
    if (size > danmakuCapacityBytes || danmakuCapacitySegments <= 0) return;
    while (_danmaku.isNotEmpty &&
        (_danmaku.length >= danmakuCapacitySegments ||
            _danmakuBytes + size > danmakuCapacityBytes)) {
      _danmakuBytes -= _danmaku.remove(_danmaku.keys.first)!.$2;
    }
    _danmaku[key] = (_clock().add(danmakuTtl), size, result);
    _danmakuBytes += size;
  }

  void dispose() {
    CacheLifecycle.subtitles.removeListener(_clear);
    _clear();
  }
}
