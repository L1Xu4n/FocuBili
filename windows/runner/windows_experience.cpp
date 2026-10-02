#include "windows_experience.h"
#include "fullscreen_mouse_guard.h"

#include <shobjidl.h>
#include <cstring>
#include <vector>

namespace {
/// Reads bounded dimensions without accepting arbitrary integer narrowing.
int ReadDimension(const flutter::EncodableMap& args, const char* key) {
  const auto item = args.find(flutter::EncodableValue(key));
  if (item == args.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&item->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&item->second)) {
    return *value > 0 && *value <= 32768 ? static_cast<int>(*value) : 0;
  }
  return 0;
}

/// Allocates movable clipboard memory without transferring ownership yet.
HGLOBAL CopyMemoryBlock(const void* data, size_t bytes) {
  HGLOBAL block = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (block == nullptr) return nullptr;
  void* memory = GlobalLock(block);
  if (memory == nullptr) { GlobalFree(block); return nullptr; }
  std::memcpy(memory, data, bytes);
  GlobalUnlock(block);
  return block;
}

/// Publishes both standard DIB pixels and lossless PNG bytes, never a file path.
bool CopyImage(HWND window, const flutter::EncodableMap& args) {
  const int width = ReadDimension(args, "width");
  const int height = ReadDimension(args, "height");
  const auto rgba_item = args.find(flutter::EncodableValue("rgba"));
  const auto png_item = args.find(flutter::EncodableValue("png"));
  if (width <= 0 || height <= 0 || width > 8192 || height > 32768 ||
      rgba_item == args.end() || png_item == args.end()) return false;
  const auto* rgba = std::get_if<std::vector<uint8_t>>(&rgba_item->second);
  const auto* png = std::get_if<std::vector<uint8_t>>(&png_item->second);
  const size_t pixel_bytes = static_cast<size_t>(width) * height * 4;
  if (pixel_bytes > 128 * 1024 * 1024 || rgba == nullptr ||
      rgba->size() != pixel_bytes || png == nullptr || png->empty() ||
      png->size() > 128 * 1024 * 1024) return false;

  std::vector<uint8_t> dib(sizeof(BITMAPINFOHEADER) + pixel_bytes, 0);
  BITMAPINFOHEADER header{};
  header.biSize = sizeof(header);
  header.biWidth = width;
  header.biHeight = height;
  header.biPlanes = 1;
  header.biBitCount = 32;
  header.biCompression = BI_RGB;
  header.biSizeImage = static_cast<DWORD>(pixel_bytes);
  std::memcpy(dib.data(), &header, sizeof(header));
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const size_t source = (static_cast<size_t>(y) * width + x) * 4;
      const size_t target = sizeof(header) +
          (static_cast<size_t>(height - 1 - y) * width + x) * 4;
      const int alpha = (*rgba)[source + 3];
      for (int c = 0; c < 3; ++c) {
        dib[target + c] = static_cast<uint8_t>(
            ((*rgba)[source + 2 - c] * alpha + 255 * (255 - alpha) + 127) / 255);
      }
      dib[target + 3] = 255;
    }
  }
  HGLOBAL dib_block = CopyMemoryBlock(dib.data(), dib.size());
  HGLOBAL png_block = CopyMemoryBlock(png->data(), png->size());
  if (dib_block == nullptr || png_block == nullptr || !OpenClipboard(window)) {
    if (dib_block != nullptr) GlobalFree(dib_block);
    if (png_block != nullptr) GlobalFree(png_block);
    return false;
  }
  bool success = false;
  if (EmptyClipboard() && SetClipboardData(CF_DIB, dib_block) != nullptr) {
    dib_block = nullptr;  // Ownership is now held by Windows.
    success = true;
    const UINT png_format = RegisterClipboardFormatW(L"PNG");
    if (png_format != 0 && SetClipboardData(png_format, png_block) != nullptr) png_block = nullptr;
  }
  CloseClipboard();
  if (dib_block != nullptr) GlobalFree(dib_block);
  if (png_block != nullptr) GlobalFree(png_block);
  return success;
}
}  // namespace

WindowsExperience* WindowsExperience::active_mouse_guard_ = nullptr;

/// Registers strictly typed native operations and converts failures into Dart errors.
WindowsExperience::WindowsExperience(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.focubili.app/windows_experience", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (call.method_name() == "copyImage") {
        if (args != nullptr && CopyImage(window_, *args)) {
          result->Success();
        } else {
          result->Error("clipboard_image_failed", "Cannot copy image to clipboard.");
        }
      } else if (call.method_name() == "setFullscreenProtection") {
        bool enabled = false;
        if (args != nullptr) {
          const auto found = args->find(flutter::EncodableValue("enabled"));
          if (found != args->end()) {
            if (const auto* value = std::get_if<bool>(&found->second)) enabled = *value;
          }
        }
        result->Success(flutter::EncodableValue(SetFullscreen(enabled)));
      } else {
        result->NotImplemented();
      }
    } catch (...) {
      result->Error("windows_experience_failed", "Windows operation failed.");
    }
  });
}

/// Restores shell state even when a player route is destroyed unexpectedly.
WindowsExperience::~WindowsExperience() {
  SetFullscreen(false);
  channel_->SetMethodCallHandler(nullptr);
}

/// Marks the window in the shell and guards only its bottom taskbar trigger pixels.
bool WindowsExperience::SetFullscreen(bool enabled) {
  fullscreen_ = enabled;
  ITaskbarList2* taskbar = nullptr;
  bool marked = false;
  if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar)))) {
    if (SUCCEEDED(taskbar->HrInit())) {
      marked = SUCCEEDED(taskbar->MarkFullscreenWindow(window_, enabled ? TRUE : FALSE));
    }
    taskbar->Release();
  }
  const bool guarded = RefreshMouseGuard();
  return marked && guarded;
}

/// Installs a lightweight input hook for the active fullscreen window only.
bool WindowsExperience::RefreshMouseGuard() {
  if (!fullscreen_ || GetForegroundWindow() != window_) {
    ReleaseMouseGuard();
    return true;
  }
  MONITORINFO monitor{sizeof(MONITORINFO)};
  fullscreen_monitor_ = MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfoW(fullscreen_monitor_, &monitor)) return false;
  fullscreen_screen_ = monitor.rcMonitor;
  if (mouse_hook_ == nullptr) {
    if (active_mouse_guard_ != nullptr && active_mouse_guard_ != this) return false;
    active_mouse_guard_ = this;
    mouse_hook_ = SetWindowsHookExW(WH_MOUSE_LL, LowLevelMouseProc,
                                  GetModuleHandleW(nullptr), 0);
    if (mouse_hook_ == nullptr) {
      active_mouse_guard_ = nullptr;
      return false;
    }
  }
  POINT point{};
  if (GetCursorPos(&point)) GuardBottomEdge(point);
  return true;
}

/// Removes the process-owned hook without changing the system taskbar or cursor clipping.
void WindowsExperience::ReleaseMouseGuard() {
  if (active_mouse_guard_ == this) active_mouse_guard_ = nullptr;
  if (mouse_hook_ != nullptr) {
    UnhookWindowsHookEx(mouse_hook_);
    mouse_hook_ = nullptr;
  }
}

/// Skips the shell hotspot while permitting side exits and passage to a display below.
bool WindowsExperience::GuardBottomEdge(const POINT& point) {
  if (!fullscreen_ || GetForegroundWindow() != window_) return false;
  POINT target{};
  if (!PlanFullscreenBottomEdge(fullscreen_screen_, point, nullptr, &target)) {
    return false;
  }
  const POINT across{point.x, fullscreen_screen_.bottom};
  const HMONITOR below = MonitorFromPoint(across, MONITOR_DEFAULTTONULL);
  MONITORINFO neighbor{sizeof(MONITORINFO)};
  if (below != nullptr && below != fullscreen_monitor_ &&
      GetMonitorInfoW(below, &neighbor)) {
    PlanFullscreenBottomEdge(fullscreen_screen_, point, &neighbor.rcMonitor, &target);
  }
  return SetCursorPos(target.x, target.y) != FALSE;
}

/// Consumes only redirected mouse movement; clicks, wheel events and other apps pass through.
LRESULT CALLBACK WindowsExperience::LowLevelMouseProc(int code, WPARAM message,
                                                     LPARAM data) {
  if (code == HC_ACTION && message == WM_MOUSEMOVE && active_mouse_guard_ != nullptr) {
    const auto* mouse = reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
    if (active_mouse_guard_->GuardBottomEdge(mouse->pt)) return 1;
  }
  return CallNextHookEx(nullptr, code, message, data);
}

/// Restores shell marking on activation and releases edge filtering on focus loss.
void WindowsExperience::OnWindowMessage(UINT message, WPARAM wparam) {
  if (message == WM_DESTROY) {
    SetFullscreen(false);
  } else if ((message == WM_ACTIVATEAPP && wparam == FALSE) ||
             (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE)) {
    ReleaseMouseGuard();
  } else if (fullscreen_ && (message == WM_ACTIVATEAPP || message == WM_ACTIVATE ||
             message == WM_DISPLAYCHANGE || message == WM_DPICHANGED)) {
    SetFullscreen(true);
  } else if (fullscreen_ && message == WM_WINDOWPOSCHANGED) {
    RefreshMouseGuard();
  }
}
