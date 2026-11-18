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
  static Future<VideoTagMode> load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(key);
      return VideoTagMode.values.where((m) => m.name == stored).firstOrNull ??
          VideoTagMode.onTap;
    } catch (_) {
      return VideoTagMode.onTap;
    }
  }

  static Future<bool> save(VideoTagMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(key, mode.name)) {
        await prefs.reload();
        return false;
      }
      changes.value++;
      return true;
    } catch (_) {
      return false;
    }
  }
}
