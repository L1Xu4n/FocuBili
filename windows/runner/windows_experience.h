#ifndef RUNNER_WINDOWS_EXPERIENCE_H_
#define RUNNER_WINDOWS_EXPERIENCE_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>

/// Owns image clipboard and foreground-only fullscreen shell integration.
class WindowsExperience {
 public:
  /// Registers the bridge against this runner window and its Flutter messenger.
  WindowsExperience(HWND window, flutter::BinaryMessenger* messenger);
  /// Releases shell fullscreen state before window teardown.
  ~WindowsExperience();
  /// Handles activation/geometry changes without consuming normal window messages.
  void OnWindowMessage(UINT message, WPARAM wparam);

 private:
  /// Marks fullscreen and protects its bottom trigger edge while this window is active.
  bool SetFullscreen(bool enabled);
  /// Installs the bottom-edge hook only while the fullscreen window owns foreground input.
  bool RefreshMouseGuard();
  /// Releases the hook immediately on focus loss, fullscreen exit or window teardown.
  void ReleaseMouseGuard();
  /// Moves only bottom-edge points inward or directly into the monitor below.
  bool GuardBottomEdge(const POINT& point);
  /// Filters edge movement before the shell can activate an auto-hidden taskbar.
  static LRESULT CALLBACK LowLevelMouseProc(int code, WPARAM message, LPARAM data);
  static WindowsExperience* active_mouse_guard_;
  HWND window_;
  bool fullscreen_ = false;
  HHOOK mouse_hook_ = nullptr;
  HMONITOR fullscreen_monitor_ = nullptr;
  RECT fullscreen_screen_{};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
