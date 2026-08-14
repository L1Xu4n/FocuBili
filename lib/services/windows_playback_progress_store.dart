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

  /// 读取最后分P和安全续播位置；旧数据缺少时长时保留分P但从零开始。
  Future<SavedPlaybackState?> load(String bvid) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? encoded = preferences.getString(_progressKey(bvid));
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

  /// 写入固定快照，并在接近结尾或时长未知时把位置归零但保留最后分P。
  Future<void> save(WindowsPlaybackProgressSnapshot snapshot) async {
    final Duration position = PlaybackResumePolicy.normalizeStoredPosition(
      snapshot.position,
      snapshot.duration,
    );
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _progressKey(snapshot.bvid),
      jsonEncode(<String, int>{
        'cid': snapshot.cid,
        'pageNumber': snapshot.pageNumber,
        'positionMs': position.inMilliseconds.clamp(0, 1 << 31),
        'durationMs': snapshot.duration.inMilliseconds.clamp(0, 1 << 31),
      }),
    );
  }

  /// 为单支 BV 视频生成与 Android 原生偏好相互隔离的 Windows 恢复键。
  String _progressKey(String bvid) {
    return 'windows_playback_state_${bvid.trim().toUpperCase()}';
  }
}
