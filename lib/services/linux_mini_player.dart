import 'dart:io';
import 'dart:ui';
import 'package:window_manager/window_manager.dart';

/// Reuses the existing video surface in a small desktop window, without a second player.
class LinuxMiniPlayer {
  static Size normalMinimumSize = Size.zero;
  Size _previousMinimum = Size.zero;
  bool _disposed = false;
  Future<bool>? _pendingToggle;
  bool active = false;
  bool _changing = false;
  Rect? _bounds;
  bool _wasAlwaysOnTop = false;
  bool _wasMaximized = false;
  bool _wasFullscreen = false;

  Future<bool> toggle(double aspectRatio) {
    if (_disposed || _pendingToggle != null) return Future<bool>.value(false);
    final operation = _toggle(aspectRatio);
    _pendingToggle = operation;
    operation.whenComplete(() {
      if (identical(_pendingToggle, operation)) _pendingToggle = null;
    });
    return operation;
  }

  Future<bool> _toggle(double aspectRatio) async {
    if (!Platform.isLinux ||
        _changing ||
        !aspectRatio.isFinite ||
        aspectRatio <= 0) {
      return false;
    }
    _changing = true;
    try {
      if (active) {
        await _restore();
        return true;
      }
      _previousMinimum = normalMinimumSize;
      _bounds = await windowManager.getBounds();
      _wasAlwaysOnTop = await windowManager.isAlwaysOnTop();
      _wasMaximized = await windowManager.isMaximized();
      _wasFullscreen = await windowManager.isFullScreen();
      if (_wasFullscreen) await windowManager.setFullScreen(false);
      if (_wasMaximized) await windowManager.unmaximize();
      await windowManager.setMinimumSize(const Size(260, 180));
      await windowManager.setSize(
        Size(440, (440 / aspectRatio + 48).clamp(220, 500)),
      );
      // Some Wayland compositors may ignore this request. Window content still works.
      await windowManager.setAlwaysOnTop(true);
      active = true;
      return true;
    } catch (_) {
      await _restore();
      return false;
    } finally {
      _changing = false;
    }
  }

  Future<void> restore() async {
    await _pendingToggle;
    await _restore();
  }

  Future<void> dispose() async {
    _disposed = true;
    await restore();
  }

  Future<void> _restore() async {
    if (_bounds == null) {
      active = false;
      return;
    }
    final bounds = _bounds!;
    _bounds = null;
    active = false;
    try {
      await windowManager.setAlwaysOnTop(_wasAlwaysOnTop);
      await windowManager.setMinimumSize(_previousMinimum);
      await windowManager.setBounds(bounds);
      if (_wasMaximized) await windowManager.maximize();
      if (_wasFullscreen) await windowManager.setFullScreen(true);
    } catch (_) {
      // Window teardown must not prevent media resource disposal.
    }
  }
}
