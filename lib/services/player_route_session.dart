import 'package:flutter/widgets.dart';

/// 为外部视频导航管理原播放器的暂停与恢复生命周期。
class PlayerRouteSession {
  /// Keeps callbacks with their owning player state rather than a global backend.
  PlayerRouteSession({required this.pause, required this.restore});
  final Future<void> Function() pause;
  final Future<void> Function() restore;
  static final List<PlayerRouteSession> _sessions = [];
  bool _attached = false;

  /// Registers the newest live player as the external navigation target.
  void attach() {
    _attached = true;
    _sessions.add(this);
  }

  /// Removes disposed routes so late navigation completions cannot revive them.
  void detach() {
    _attached = false;
    _sessions.remove(this);
  }

  /// Awaits the old player's pause before a new route may start a second backend.
  static Future<PlayerRouteSession?> suspendCurrent() async {
    final session = _sessions.lastOrNull;
    if (session != null) await session.pause();
    return session;
  }

  /// Restores the previous native surface after return, without automatic playback.
  Future<void> restoreIfAttached() async {
    if (_attached) await restore();
  }

  /// 等退出动画和路由销毁完成后恢复，避免下层播放器随后释放已恢复的资源。
  Future<void> restoreAfterRoute(TransitionRoute<dynamic> route) async {
    await route.completed;
    await restoreIfAttached();
  }
}
