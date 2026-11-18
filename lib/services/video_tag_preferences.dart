import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum VideoTagMode {
  expanded('默认展开'),
  onTap('点击后展开'),
  hidden('隐藏');

  const VideoTagMode(this.label);
  final String label;
}

class VideoTagPreferences {
  static const key = 'appearance.video_tag_mode';
  static final changes = ValueNotifier<int>(0);
  // Legacy SharedPreferences changes its in-memory cache before writing. A
  // rejected platform write must not expose hidden tags in the next player.
  static final _failedWrite = Expando<VideoTagMode>();
  static Future<VideoTagMode> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final confirmed = _failedWrite[prefs];
      if (confirmed != null) {
        try {
          await prefs.reload();
          _failedWrite[prefs] = null;
        } catch (_) {
          return confirmed;
        }
      }
      final stored = prefs.getString(key);
      return VideoTagMode.values.where((m) => m.name == stored).firstOrNull ??
          VideoTagMode.onTap;
    } catch (_) {
      return VideoTagMode.hidden;
    }
  }

  static Future<bool> save(VideoTagMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final previous = await load();
      try {
        if (!await prefs.setString(key, mode.name)) {
          _failedWrite[prefs] = previous;
          return false;
        }
      } catch (_) {
        _failedWrite[prefs] = previous;
        return false;
      }
      _failedWrite[prefs] = null;
      changes.value++;
      return true;
    } catch (_) {
      return false;
    }
  }
}
