import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'native_playback_service.dart';
import 'playback_resume_policy.dart';

/// 固定一次 Windows 进度写入需要的全部值，避免异步等待后读取到另一支视频的状态。
class WindowsPlaybackProgressSnapshot {
  /// 创建不可变的 Windows 播放进度快照。
  const WindowsPlaybackProgressSnapshot({
    required this.bvid,
    required this.cid,
    required this.pageNumber,
    required this.position,
    required this.duration,
  });

  final String bvid;
  final int cid;
  final int pageNumber;
  final Duration position;
  final Duration duration;
}

/// 只负责 Windows 播放进度的 JSON 读写和有效性校验，不接触 media_kit 播放器。
class WindowsPlaybackProgressStore {
  /// 创建使用 SharedPreferences 的 Windows 播放进度仓库。
  const WindowsPlaybackProgressStore();

  /// 读取该 BV 最后播放的分P和安全续播位置，用于播放器首次打开时选择分P。
  Future<SavedPlaybackState?> load(String bvid) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return _decodeSavedState(preferences.getString(_progressKey(bvid)));
  }

  /// 按 BV 与 CID 读取目标分P进度；没有新键时兼容仍保存在 BV 单槽中的旧记录。
  Future<SavedPlaybackState?> loadPart(String bvid, int cid) async {
    if (cid <= 0) {
      return null;
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final SavedPlaybackState? partState = _decodeSavedState(
      preferences.getString(_partProgressKey(bvid, cid)),
    );
    if (partState?.cid == cid) {
      return partState;
    }
    final SavedPlaybackState? legacyState = _decodeSavedState(
      preferences.getString(_progressKey(bvid)),
    );
    return legacyState?.cid == cid ? legacyState : null;
  }

  /// 把单条 JSON 记录转换成安全播放状态，损坏或旧版缺少时长时采用保守结果。
  SavedPlaybackState? _decodeSavedState(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        return null;
      }
      final int cid = (decoded['cid'] as num?)?.toInt() ?? 0;
      final int pageNumber = (decoded['pageNumber'] as num?)?.toInt() ?? 0;
      final int positionMs = (decoded['positionMs'] as num?)?.toInt() ?? 0;
      final int durationMs = (decoded['durationMs'] as num?)?.toInt() ?? 0;
      if (cid <= 0 || pageNumber <= 0) {
        return null;
      }
      final Duration position = PlaybackResumePolicy.normalizeStoredPosition(
        Duration(milliseconds: positionMs),
        Duration(milliseconds: durationMs),
      );
      return SavedPlaybackState(
        cid: cid,
        pageNumber: pageNumber,
        position: position,
      );
    } on Object {
      // JSON 语法错误或字段类型损坏都只放弃这条本机记录，不能阻止播放器打开。
      return null;
    }
  }

  /// 同时写入最后分P与独立分P进度；时长未知时保留旧记录，避免瞬态覆盖。
  Future<void> save(WindowsPlaybackProgressSnapshot snapshot) async {
    if (snapshot.duration <= Duration.zero) {
      return;
    }
    final Duration position = PlaybackResumePolicy.normalizeStoredPosition(
      snapshot.position,
      snapshot.duration,
    );
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String latestProgressKey = _progressKey(snapshot.bvid);
    final String? previousEncoded = preferences.getString(latestProgressKey);
    final SavedPlaybackState? previousState = _decodeSavedState(
      previousEncoded,
    );
    if (previousEncoded != null &&
        previousState != null &&
        previousState.cid != snapshot.cid) {
      final String previousPartKey = _partProgressKey(
        snapshot.bvid,
        previousState.cid,
      );
      if (!preferences.containsKey(previousPartKey)) {
        await preferences.setString(previousPartKey, previousEncoded);
      }
    }
    final String encoded = jsonEncode(<String, int>{
      'cid': snapshot.cid,
      'pageNumber': snapshot.pageNumber,
      'positionMs': position.inMilliseconds.clamp(0, 1 << 31),
      'durationMs': snapshot.duration.inMilliseconds.clamp(0, 1 << 31),
    });
    await preferences.setString(
      _partProgressKey(snapshot.bvid, snapshot.cid),
      encoded,
    );
    await preferences.setString(latestProgressKey, encoded);
  }

  /// 为单支 BV 视频生成与 Android 原生偏好相互隔离的 Windows 恢复键。
  String _progressKey(String bvid) {
    return 'windows_playback_state_${bvid.trim().toUpperCase()}';
  }

  /// 为同一 BV 下的单个 CID 生成独立进度键，防止不同分P互相覆盖。
  String _partProgressKey(String bvid, int cid) {
    return '${_progressKey(bvid)}_cid_$cid';
  }
}
