#include "flutter_window.h"

#include <exception>
#include <optional>
#include <string>

#include <windows.h>
#include <shellapi.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kNotificationSettingsKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings";
constexpr wchar_t kDoNotDisturbValue[] = L"NOC_GLOBAL_SETTING_TOASTS_ENABLED";
constexpr wchar_t kRuntimeStateKey[] = L"Software\\FocuBili\\Runtime";
constexpr wchar_t kRestoreExistsValue[] = L"DndRestoreExists";
constexpr wchar_t kRestoreValue[] = L"DndRestoreValue";

/// 向其他进程的顶层窗口发送通知设置变化，避免同步重入当前 Flutter Runner。
BOOL CALLBACK NotifyExternalWindowOfNotificationChange(HWND window,
                                                        LPARAM parameter) {
  const DWORD current_process_id = static_cast<DWORD>(parameter);
  DWORD window_process_id = 0;
  GetWindowThreadProcessId(window, &window_process_id);
  if (window_process_id == 0 || window_process_id == current_process_id) {
    return TRUE;
  }
  SendNotifyMessageW(window, WM_SETTINGCHANGE, 0,
                     reinterpret_cast<LPARAM>(L"ImmersiveShell"));
  return TRUE;
}

/// 通知任务栏和通知中心刷新勿扰状态，但不把消息回灌到当前进程。
void BroadcastNotificationSettingChanged() {
  EnumWindows(NotifyExternalWindowOfNotificationChange,
              static_cast<LPARAM>(GetCurrentProcessId()));
}

/// 读取一个用户级 DWORD；不存在时通过 exists 返回 false。
bool ReadUserDword(const wchar_t* key_path, const wchar_t* value_name,
                   DWORD* value, bool* exists) {
  DWORD size = sizeof(DWORD);
  const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, key_path, value_name,
                                      RRF_RT_REG_DWORD, nullptr, value, &size);
  *exists = status == ERROR_SUCCESS;
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

/// 写入用户级 DWORD，并按需创建应用自己的恢复状态键。
bool WriteUserDword(const wchar_t* key_path, const wchar_t* value_name,
                    DWORD value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, key_path, 0, nullptr, 0, KEY_SET_VALUE,
                      nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status = RegSetValueExW(
      key, value_name, 0, REG_DWORD,
      reinterpret_cast<const BYTE*>(&value), sizeof(value));
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

/// 删除一个用户级值；值原本不存在同样视为成功。
bool DeleteUserValue(const wchar_t* key_path, const wchar_t* value_name) {
  HKEY key = nullptr;
  const LSTATUS open_status = RegOpenKeyExW(
      HKEY_CURRENT_USER, key_path, 0, KEY_SET_VALUE, &key);
  if (open_status == ERROR_FILE_NOT_FOUND) {
    return true;
  }
  if (open_status != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status = RegDeleteValueW(key, value_name);
  RegCloseKey(key);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

/// 只恢复旧版本可能改动过的通知值，并清除旧崩溃恢复标记；新版本不会再创建这些标记。
bool RestoreLegacyNotificationSetting() {
  DWORD original_exists = 0;
  bool marker_exists = false;
  if (!ReadUserDword(kRuntimeStateKey, kRestoreExistsValue, &original_exists,
                     &marker_exists) ||
      !marker_exists) {
    return true;
  }
  bool restored = false;
  if (original_exists != 0) {
    DWORD original_value = 1;
    bool value_exists = false;
    restored = ReadUserDword(kRuntimeStateKey, kRestoreValue, &original_value,
                             &value_exists) &&
               value_exists &&
               WriteUserDword(kNotificationSettingsKey,
                              kDoNotDisturbValue, original_value);
  } else {
    restored = DeleteUserValue(kNotificationSettingsKey, kDoNotDisturbValue);
  }
  if (restored) {
    DeleteUserValue(kRuntimeStateKey, kRestoreExistsValue);
    DeleteUserValue(kRuntimeStateKey, kRestoreValue);
    BroadcastNotificationSettingChanged();
  }
  return restored;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 升级后先恢复旧版本可能遗留的全局通知值；之后不再用注册表模拟系统专注。
  RestoreLegacyNotificationSetting();

  // 只返回 Windows 明确提供的电量百分比；台式机或未知状态返回 null，
  // 让 Flutter 页面隐藏电量而不是显示虚假的 0% 或 100%。
  device_status_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.focubili.app/device_status",
      &flutter::StandardMethodCodec::GetInstance());
  device_status_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getBatteryPercent") {
          SYSTEM_POWER_STATUS power_status{};
          if (GetSystemPowerStatus(&power_status) &&
              power_status.BatteryLifePercent <= 100) {
            result->Success(flutter::EncodableValue(
                static_cast<int>(power_status.BatteryLifePercent)));
          } else {
            result->Success(flutter::EncodableValue());
          }
          return;
        }
        if (call.method_name() == "getNetworkType") {
          // Windows 播放器不展示网络类型，查询时也只返回安全的未知值。
          result->Success(flutter::EncodableValue(std::string("other")));
          return;
        }
        result->NotImplemented();
      });

  do_not_disturb_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.focubili.app/windows_do_not_disturb",
      &flutter::StandardMethodCodec::GetInstance());
  // 处理 Flutter 发来的勿扰查询和切换请求；任何原生异常都只作为平台错误返回。
  do_not_disturb_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        try {
          if (call.method_name() == "isSupported") {
            // 官方启动接口需要微软签发的受限功能令牌；当前安装包没有令牌时必须如实返回不支持。
            result->Success(flutter::EncodableValue(false));
            return;
          }
          if (call.method_name() == "openSettings") {
            const HINSTANCE opened = ShellExecuteW(
                nullptr, L"open", L"ms-settings:quiethours", nullptr, nullptr,
                SW_SHOWNORMAL);
            result->Success(flutter::EncodableValue(
                reinterpret_cast<INT_PTR>(opened) > 32));
            return;
          }
          if (call.method_name() == "setEnabled") {
            const auto* arguments = std::get_if<flutter::EncodableMap>(
                call.arguments());
            bool enabled = false;
            if (arguments != nullptr) {
              const auto iterator = arguments->find(
                  flutter::EncodableValue("enabled"));
              if (iterator != arguments->end()) {
                if (const auto* value = std::get_if<bool>(&iterator->second)) {
                  enabled = *value;
                }
              }
            }
            // 开启请求不能再写旧通知注册表；关闭请求只负责清理旧版可能遗留的状态。
            const bool applied = enabled
                                     ? false
                                     : RestoreLegacyNotificationSetting();
            result->Success(flutter::EncodableValue(applied));
            return;
          }
          result->NotImplemented();
        } catch (...) {
          // 原生勿扰异常只能降级为平台错误，不能穿过 Flutter 方法通道触发进程终止。
          result->Error("windows_do_not_disturb_failed",
                        "Windows do-not-disturb operation failed.");
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 退出时再次尝试清理旧版残留；当前版本本身不会再修改系统专注状态。
  RestoreLegacyNotificationSetting();
  do_not_disturb_channel_.reset();
  // 先释放方法通道，再销毁 Flutter 引擎，避免回调继续访问已释放窗口资源。
  device_status_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
// 将 Windows 消息交给 Flutter，并在引擎销毁期或插件异常时安全回退到系统默认处理。
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  try {
    // Give Flutter, including plugins, an opportunity to handle window messages.
    if (flutter_controller_) {
      std::optional<LRESULT> result =
          flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                        lparam);
      if (result) {
        return *result;
      }
    }

    switch (message) {
      case WM_FONTCHANGE:
        if (flutter_controller_ && flutter_controller_->engine()) {
          flutter_controller_->engine()->ReloadSystemFonts();
        }
        break;
    }

    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  } catch (...) {
    // Win32 窗口回调是 noexcept 边界；插件或引擎异常必须降级给系统处理，不能触发 std::terminate。
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
}
