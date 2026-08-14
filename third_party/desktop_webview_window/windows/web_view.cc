//
// Created by yangbin on 2021/11/12.
//

#include "web_view.h"

#include <tchar.h>
#include <windows.h>

#include <cassert>
#include <cwctype>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <wininet.h>

#include "flutter/method_result_functions.h"
#include "strconv.h"
#include "utils.h"

namespace webview_window {

static LRESULT CALLBACK WndProc(HWND const window, UINT const message,
                                WPARAM const wparam,
                                LPARAM const lparam) noexcept {
  return DefWindowProc(window, message, wparam, lparam);
}

const auto kWebViewClassName = _T("web_view_window_web_view");

using namespace Microsoft::WRL;

WebView::WebView(
    std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
        method_channel,
    int64_t web_view_id, std::wstring userDataFolder,
    std::function<void(HRESULT)> on_web_view_created)
    : method_channel_(std::move(method_channel)),
      web_view_id_(web_view_id),
      user_data_folder_(std::move(userDataFolder)),
      on_web_view_created_callback_(std::move(on_web_view_created)) {
  RegisterWindowClass(kWebViewClassName, WndProc);
  view_window_ = wil::unique_hwnd(::CreateWindowEx(
      0, kWebViewClassName, L"", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, ::GetModuleHandle(nullptr), nullptr));
  assert(view_window_ != nullptr);
  if (!view_window_) {
    on_web_view_created_callback_(S_FALSE);
    return;
  }

  CreateCoreWebView2EnvironmentWithOptions(
      nullptr, user_data_folder_.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this](HRESULT result, ICoreWebView2Environment *env) -> HRESULT {
            if (!SUCCEEDED(result)) {
              on_web_view_created_callback_(result);
              return S_OK;
            }
            env->CreateCoreWebView2Controller(
                view_window_.get(),
                Callback<
                    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [this](HRESULT result,
                           ICoreWebView2Controller *controller) -> HRESULT {
                      if (FAILED(result) || !controller) {
                        on_web_view_created_callback_(FAILED(result) ? result
                                                                    : E_POINTER);
                        return S_OK;
                      }
                      webview_controller_ = controller;
                      // Dart may configure and navigate immediately after this
                      // callback. Report success only after webview_ and all
                      // navigation handlers are ready, otherwise the first
                      // Navigate call is silently lost and the window stays black.
                      on_web_view_created_callback_(OnWebviewControllerCreated());
                      return S_OK;
                    })
                    .Get());
            return S_OK;
          })
          .Get());
}

HRESULT WebView::OnWebviewControllerCreated() {
  if (!webview_controller_) {
    return E_POINTER;
  }

  HRESULT hr = webview_controller_->get_CoreWebView2(&webview_);
  if (FAILED(hr) || !webview_) {
    std::cerr << "failed to get core webview" << std::endl;
    return FAILED(hr) ? hr : E_POINTER;
  }

  wil::com_ptr<ICoreWebView2Settings> settings;
  hr = webview_->get_Settings(&settings);
  if (FAILED(hr) || !settings) {
    std::cerr << "failed to get settings" << std::endl;
    return FAILED(hr) ? hr : E_POINTER;
  }

  settings->put_IsScriptEnabled(true);
  settings->put_IsZoomControlEnabled(false);
  settings->put_AreDefaultContextMenusEnabled(false);
  settings->put_IsStatusBarEnabled(false);
  settings->put_IsWebMessageEnabled(true);

  wil::com_ptr<ICoreWebView2Settings2> settings2;
  hr = settings->QueryInterface(IID_PPV_ARGS(&settings2));
  if (SUCCEEDED(hr) && settings2) {
    wil::unique_cotaskmem_string user_agent;
    hr = settings2->get_UserAgent(&user_agent);
    if (SUCCEEDED(hr) && user_agent) {
      default_user_agent_ = std::wstring(user_agent.get());
    }
  }

  UpdateBounds();

  // Preserve the opener relationship required by verification and OAuth pages.
  webview_->add_NewWindowRequested(
      Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [this](ICoreWebView2 *sender,
             ICoreWebView2NewWindowRequestedEventArgs *args) {
            wil::unique_cotaskmem_string uri;
            HRESULT hr = args->get_Uri(&uri);
            const bool allowed = SUCCEEDED(hr) && uri &&
                                 IsAllowedNavigationUri(uri.get());
            // Keep trusted links inside this isolated login window; block every other popup.
            if (allowed) {
              sender->Navigate(uri.get());
            }
            args->put_Handled(true);
            return S_OK;
          })
          .Get(),
      nullptr);

  webview_->add_ContentLoading(
      Callback<ICoreWebView2ContentLoadingEventHandler>(
          [](ICoreWebView2 *sender,
             ICoreWebView2ContentLoadingEventArgs *args) { return S_OK; })
          .Get(),
      nullptr);

  webview_->add_HistoryChanged(
      Callback<ICoreWebView2HistoryChangedEventHandler>(
          [this](ICoreWebView2 *sender, IUnknown *args) {
            auto method_args = flutter::EncodableMap{
                {flutter::EncodableValue("id"),
                 flutter::EncodableValue(web_view_id_)},
                {flutter::EncodableValue("canGoBack"),
                 flutter::EncodableValue(CanGoBack())},
                {flutter::EncodableValue("canGoForward"),
                 flutter::EncodableValue(CanGoForward())},
            };
            method_channel_->InvokeMethod(
                "onHistoryChanged",
                std::make_unique<flutter::EncodableValue>(method_args));
            return S_OK;
          })
          .Get(),
      nullptr);

  webview_->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [this](ICoreWebView2 *sender,
                 ICoreWebView2NavigationStartingEventArgs *args) {
            method_channel_->InvokeMethod(
                "onNavigationStarted",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {flutter::EncodableValue("id"),
                     flutter::EncodableValue(web_view_id_)},
                }));

            if (!allowed_navigation_hosts_.empty()) {
              wil::unique_cotaskmem_string uri;
              HRESULT hr = args->get_Uri(&uri);
              const bool allowed = SUCCEEDED(hr) && uri &&
                                   IsAllowedNavigationUri(uri.get());
              args->put_Cancel(!allowed);
            } else if (triggerOnUrlRequestedEvent) {
              wil::unique_cotaskmem_string uri;
              HRESULT hr = args->get_Uri(&uri);
              if (FAILED(hr) || !uri) {
                args->put_Cancel(true);
                return S_OK;
              }

              // Retain the upstream callback behavior for plugin users without a native allowlist.
              std::wstring uri_string(uri.get());
              auto result_handler =
                  std::make_unique<flutter::MethodResultFunctions<>>(
                      [uri_string, sender,
                       this](const flutter::EncodableValue *success_value) {
                        bool let_pass = false;
                        if (success_value &&
                            std::holds_alternative<bool>(*success_value)) {
                          let_pass = std::get<bool>(*success_value);
                        }
                        if (let_pass) {
                          this->setTriggerOnUrlRequestedEvent(false);
                          sender->Navigate(uri_string.c_str());
                        }
                      },
                      nullptr, nullptr);
              method_channel_->InvokeMethod(
                  "onUrlRequested",
                  std::make_unique<flutter::EncodableValue>(
                      flutter::EncodableMap{
                          {flutter::EncodableValue("id"),
                           flutter::EncodableValue(web_view_id_)},
                          {flutter::EncodableValue("url"),
                           flutter::EncodableValue(wide_to_utf8(uri_string))},
                      }),
                  std::move(result_handler));
              args->put_Cancel(true);
            } else {
              args->put_Cancel(false);
              triggerOnUrlRequestedEvent = true;
            }
            return S_OK;
          })
          .Get(),
      nullptr);
  webview_->add_NavigationCompleted(
      Callback<ICoreWebView2NavigationCompletedEventHandler>(
          [this](ICoreWebView2 *sender,
                 ICoreWebView2NavigationCompletedEventArgs *args) {
            BOOL is_success = FALSE;
            args->get_IsSuccess(&is_success);
            wil::unique_cotaskmem_string source;
            sender->get_Source(&source);
            auto method_args = flutter::EncodableMap{
                {flutter::EncodableValue("id"),
                 flutter::EncodableValue(web_view_id_)},
                {flutter::EncodableValue("url"),
                 flutter::EncodableValue(source
                     ? wide_to_utf8(std::wstring(source.get()))
                     : std::string())},
                {flutter::EncodableValue("isSuccess"),
                 flutter::EncodableValue(static_cast<bool>(is_success))},
            };
            method_channel_->InvokeMethod(
                "onNavigationCompleted",
                std::make_unique<flutter::EncodableValue>(method_args));
            return S_OK;
          })
          .Get(),
      nullptr);
  webview_->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
          [this](ICoreWebView2 *sender,
                 ICoreWebView2WebMessageReceivedEventArgs *args) {
            wil::unique_cotaskmem_string messageRaw;
            HRESULT hrString = args->TryGetWebMessageAsString(&messageRaw);
            if (FAILED(hrString)) {
              if (hrString == E_INVALIDARG) {
                // web message was not a string --> should only happen if it was
                // a JSON object
                HRESULT hrJson = args->get_WebMessageAsJson(&messageRaw);
                if (FAILED(hrJson)) {
                  return hrJson;
                }
              } else {
                return hrString;
              }
            }
            method_channel_->InvokeMethod(
                "onWebMessageReceived",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {flutter::EncodableValue("id"),
                     flutter::EncodableValue(web_view_id_)},
                    {flutter::EncodableValue("message"),
                     flutter::EncodableValue(
                         wide_to_utf8(std::wstring(messageRaw.get())))},
                }));
            return S_OK;
          })
          .Get(),
      nullptr);
  return S_OK;
}

void WebView::UpdateBounds() {
  // Resize WebView to fit the bounds of the parent window
  RECT bounds;
  GetClientRect(view_window_.get(), &bounds);
  if (webview_controller_)
    webview_controller_->put_Bounds(bounds);
}

void WebView::Navigate(const std::wstring &url) {
  if (webview_) {
    webview_->Navigate(url.c_str());
  } else {
    std::cerr << "webview not created" << std::endl;
  }
}

void WebView::AddScriptToExecuteOnDocumentCreated(
    const std::wstring &javaScript,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
  if (!webview_) {
    completer->Error("0", "webview not created");
    return;
  }
  auto shared_result =
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
          std::move(completer));
  // Wait for WebView2's asynchronous registration result so the next
  // navigation cannot race ahead of the document-start observer.
  const HRESULT add_script_hr = webview_->AddScriptToExecuteOnDocumentCreated(
      javaScript.c_str(),
      Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
          [result = shared_result](HRESULT error, LPCWSTR) -> HRESULT {
            if (FAILED(error)) {
              result->Error("0", "Failed to register document script");
            } else {
              result->Success();
            }
            return S_OK;
          })
          .Get());
  if (FAILED(add_script_hr)) {
    shared_result->Error("0", "Failed to start document script registration");
  }
}

void WebView::SetApplicationNameForUserAgent(const std::wstring &name) {
  if (webview_) {
    wil::com_ptr<ICoreWebView2Settings> settings;
    HRESULT hr = webview_->get_Settings(&settings);
    if (FAILED(hr) || !settings) {
      return;
    }
    wil::com_ptr<ICoreWebView2Settings2> settings2;
    hr = settings->QueryInterface(IID_PPV_ARGS(&settings2));
    if (SUCCEEDED(hr) && settings2) {
      settings2->put_UserAgent((default_user_agent_ + name).c_str());
    }
  }
}

// Replaces WebView2's complete user agent so a desktop host can use a mobile
// login flow instead of merely appending an application token to a desktop UA.
HRESULT WebView::SetUserAgent(const std::wstring &user_agent) {
  if (!webview_ || user_agent.empty()) {
    return E_INVALIDARG;
  }
  wil::com_ptr<ICoreWebView2Settings> settings;
  HRESULT hr = webview_->get_Settings(&settings);
  if (FAILED(hr) || !settings) {
    return FAILED(hr) ? hr : E_POINTER;
  }
  wil::com_ptr<ICoreWebView2Settings2> settings2;
  hr = settings->QueryInterface(IID_PPV_ARGS(&settings2));
  if (FAILED(hr) || !settings2) {
    return FAILED(hr) ? hr : E_NOINTERFACE;
  }
  return settings2->put_UserAgent(user_agent.c_str());
}

void WebView::GoBack() {
  if (webview_) {
    webview_->GoBack();
  }
}

void WebView::GoForward() {
  if (webview_) {
    webview_->GoForward();
  }
}

void WebView::Reload() {
  if (webview_) {
    webview_->Reload();
  }
}

void WebView::Stop() {
  if (webview_) {
    webview_->Stop();
  }
}

// Reads every WebView2 Cookie and always completes the Flutter method call,
// including when WebView2 rejects the asynchronous request immediately.
void WebView::GetAllCookies(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  GetCookies(L"", std::move(result));
}

// Reads the Cookies that WebView2 would send to one URL, letting the browser
// apply host, domain, path, secure and same-name Cookie selection rules.
void WebView::GetCookiesForUrl(
    const std::wstring &url,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  GetCookies(url, std::move(result));
}

// Performs the shared asynchronous WebView2 Cookie query and always completes
// the Flutter method call, including synchronous request failures.
void WebView::GetCookies(
    const std::wstring &url,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (webview_) {
    wil::com_ptr<ICoreWebView2_2> webView2;
    HRESULT hr = webview_->QueryInterface(IID_PPV_ARGS(&webView2));

    if (FAILED(hr) || !webView2) {
      result->Error("0", "Failed to get ICoreWebView2_2");
      return;
    }

    wil::com_ptr<ICoreWebView2CookieManager> cookieManager;
    HRESULT hrc = webView2->get_CookieManager(&cookieManager);

    if (FAILED(hrc) || !cookieManager) {
      result->Error("0", "Failed to get ICoreWebView2CookieManager");
      return;
    }

    // Keep the result alive until either the synchronous call or its callback
    // reports an outcome. Moving it only into the callback would leave Dart
    // waiting forever when GetCookies returns a failing HRESULT immediately.
    auto shared_result =
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
            std::move(result));
    const HRESULT get_cookies_hr = cookieManager->GetCookies(
        url.empty() ? nullptr : url.c_str(),
        Callback<ICoreWebView2GetCookiesCompletedHandler>(
            [result = shared_result](
                HRESULT hr, ICoreWebView2CookieList *cookieList) -> HRESULT {
              if (FAILED(hr) || !cookieList) {
                result->Error("0", "Failed to get cookies");
                return S_OK;
              }

              UINT cookieCount;
              hr = cookieList->get_Count(&cookieCount);
              if (FAILED(hr)) {
                result->Error("0", "Failed to get cookie count");
                return S_OK;
              }

              std::vector<flutter::EncodableValue> cookies;
              for (UINT i = 0; i < cookieCount; ++i) {
                wil::com_ptr<ICoreWebView2Cookie> cookie;
                hr = cookieList->GetValueAtIndex(i, &cookie);
                if (FAILED(hr) || !cookie) {
                  continue;
                }

                wil::unique_cotaskmem_string name;
                wil::unique_cotaskmem_string value;
                wil::unique_cotaskmem_string domain;
                wil::unique_cotaskmem_string path;
                double expires = -1;
                BOOL isSecure = FALSE;
                BOOL isHttpOnly = FALSE;
                BOOL isSessionOnly = FALSE;

                hr = cookie->get_Name(&name);
                if (FAILED(hr) || !name) continue;
                hr = cookie->get_Value(&value);
                if (FAILED(hr) || !value) continue;
                hr = cookie->get_Domain(&domain);
                if (FAILED(hr) || !domain) continue;

                // Completion detection only requires name, value and domain.
                // Older WebView2 runtimes may fail to expose optional metadata;
                // keep the login Cookie with safe defaults instead of silently
                // dropping SESSDATA and polling forever.
                cookie->get_Path(&path);
                cookie->get_Expires(&expires);
                cookie->get_IsSecure(&isSecure);
                cookie->get_IsHttpOnly(&isHttpOnly);
                cookie->get_IsSession(&isSessionOnly);

                std::map<flutter::EncodableValue, flutter::EncodableValue>
                    cookieMap;
                cookieMap[flutter::EncodableValue("name")] =
                    flutter::EncodableValue(
                        webview_window::ConvertLPCWSTRToString(name.get()));
                cookieMap[flutter::EncodableValue("value")] =
                    flutter::EncodableValue(
                        webview_window::ConvertLPCWSTRToString(value.get()));
                cookieMap[flutter::EncodableValue("domain")] =
                    flutter::EncodableValue(
                        webview_window::ConvertLPCWSTRToString(domain.get()));
                cookieMap[flutter::EncodableValue("path")] =
                    flutter::EncodableValue(path
                        ? webview_window::ConvertLPCWSTRToString(path.get())
                        : std::string("/"));

                // WebView2 reports zero for many session Cookies. They remain
                // valid until the isolated profile closes, so exporting zero
                // as 1970-01-01 would make Dart discard a fresh login session.
                if (!isSessionOnly && expires > 0) {
                  cookieMap[flutter::EncodableValue(std::string("expires"))] =
                      flutter::EncodableValue(static_cast<double>(expires));
                } else {
                  cookieMap[flutter::EncodableValue(std::string("expires"))] =
                      flutter::EncodableValue();
                }

                cookieMap[flutter::EncodableValue("secure")] =
                    flutter::EncodableValue(static_cast<bool>(isSecure));
                cookieMap[flutter::EncodableValue("httpOnly")] =
                    flutter::EncodableValue(static_cast<bool>(isHttpOnly));
                cookieMap[flutter::EncodableValue("sessionOnly")] =
                    flutter::EncodableValue(static_cast<bool>(isSessionOnly));

                cookies.push_back(flutter::EncodableValue(cookieMap));
              }

              result->Success(flutter::EncodableValue(cookies));
              return S_OK;
            })
            .Get());
    if (FAILED(get_cookies_hr)) {
      shared_result->Error("0", "Failed to start cookie query");
    }

  } else {
    result->Error("0", "webview not created");
  }
}

void WebView::openDevToolsWindow() {
  if (webview_) {
    webview_->OpenDevToolsWindow();
  }
}

bool WebView::CanGoBack() const {
  if (webview_) {
    BOOL can_go_back;
    webview_->get_CanGoBack(&can_go_back);
    return can_go_back;
  }
  return false;
}

bool WebView::CanGoForward() const {
  if (webview_) {
    BOOL can_go_forward;
    webview_->get_CanGoForward(&can_go_forward);
    return can_go_forward;
  }
  return false;
}

void WebView::ExecuteJavaScript(
    const std::wstring &javaScript,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
  if (webview_) {
    webview_->ExecuteScript(
        javaScript.c_str(),
        Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
            [completer(std::move(completer))](HRESULT error,
                                              PCWSTR result) -> HRESULT {
              if (error != S_OK) {
                completer->Error("0", "Error executing JavaScript");
              } else {
                if (result) {
                  completer->Success(flutter::EncodableValue(
                      wide_to_utf8(std::wstring(result))));
                } else {
                  completer->Success(flutter::EncodableValue(""));
                }
              }
              return S_OK;
            })
            .Get());
  } else {
    completer->Error("0", "webview not created");
  }
}

void WebView::PostWebMessageAsString(
    const std::wstring &webmessage,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
  if (webview_) {
    if (webview_->PostWebMessageAsString(webmessage.c_str()) == NOERROR) {
      completer->Success();
    } else {
      completer->Error("0", "Error posting webmessage as String");
    }
  } else {
    completer->Error("0", "webview not created");
  }
}

void WebView::PostWebMessageAsJson(
    const std::wstring &webmessage,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer) {
  if (webview_) {
    if (webview_->PostWebMessageAsJson(webmessage.c_str()) == NOERROR) {
      completer->Success();
    } else {
      completer->Error("0", "Error posting webmessage as JSON");
    }
  } else {
    completer->Error("0", "webview not created");
  }
}

void WebView::setTriggerOnUrlRequestedEvent(const bool value) {
  this->triggerOnUrlRequestedEvent = value;
}

void WebView::SetAllowedNavigationHosts(
    const std::vector<std::wstring> &hosts) {
  allowed_navigation_hosts_ = hosts;
  for (auto &allowed_host : allowed_navigation_hosts_) {
    for (auto &character : allowed_host) {
      character = static_cast<wchar_t>(towlower(character));
    }
  }
}

bool WebView::IsAllowedNavigationUri(const std::wstring &url) const {
  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  components.dwSchemeLength = static_cast<DWORD>(-1);
  components.dwHostNameLength = static_cast<DWORD>(-1);
  components.dwUserNameLength = static_cast<DWORD>(-1);
  components.dwPasswordLength = static_cast<DWORD>(-1);
  // Component pointers reference the original URL, so WinINet requires flags
  // to be zero. ICU_DECODE is valid only with caller-provided output buffers
  // and otherwise rejects every URL, leaving the WebView on about:blank.
  if (!InternetCrackUrlW(url.c_str(), 0, 0, &components)) {
    return false;
  }
  const std::wstring scheme(components.lpszScheme, components.dwSchemeLength);
  std::wstring host(components.lpszHostName, components.dwHostNameLength);
  if (_wcsicmp(scheme.c_str(), L"https") != 0 ||
      components.dwUserNameLength > 0 || components.dwPasswordLength > 0) {
    return false;
  }
  for (auto &character : host) {
    character = static_cast<wchar_t>(towlower(character));
  }
  for (const auto &allowed_host : allowed_navigation_hosts_) {
    if (host == allowed_host) {
      return true;
    }
  }
  return host == L"bilibili.com" ||
         (host.size() > 13 &&
          host.compare(host.size() - 13, 13, L".bilibili.com") == 0);
}

WebView::~WebView() {
  if (webview_) {
    webview_->Stop();
  }
  if (webview_controller_) {
    webview_controller_->Close();
  }
}

}  // namespace webview_window
