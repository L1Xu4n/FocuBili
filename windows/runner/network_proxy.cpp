#include "network_proxy.h"

#include <winhttp.h>
#include <shlwapi.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cwctype>
#include <stdexcept>
#include <vector>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

namespace {
std::wstring Wide(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) throw std::runtime_error("Invalid URL encoding");
  std::wstring output(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                     static_cast<int>(value.size()), &output[0], size);
  return output;
}
std::string Utf8(const std::wstring& value) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string output(static_cast<size_t>(size), '\0');
  if (size) WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), &output[0], size, nullptr, nullptr);
  return output;
}
std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  return value;
}
std::vector<std::wstring> Tokens(const std::wstring& value) {
  std::vector<std::wstring> tokens;
  size_t start = value.find_first_not_of(L"; \t\r\n");
  while (start != std::wstring::npos) {
    const size_t end = value.find_first_of(L"; \t\r\n", start);
    tokens.push_back(value.substr(start, end - start));
    start = end == std::wstring::npos ? end : value.find_first_not_of(L"; \t\r\n", end);
  }
  return tokens;
}
struct IeConfig {
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG value{};
  ~IeConfig() {
    GlobalFree(value.lpszAutoConfigUrl);
    GlobalFree(value.lpszProxy);
    GlobalFree(value.lpszProxyBypass);
  }
};
struct ProxyInfo {
  WINHTTP_PROXY_INFO value{};
  ~ProxyInfo() { GlobalFree(value.lpszProxy); GlobalFree(value.lpszProxyBypass); }
};
struct Session {
  HINTERNET value = WinHttpOpen(L"FocuBili proxy resolver", WINHTTP_ACCESS_TYPE_NO_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  ~Session() { if (value) WinHttpCloseHandle(value); }
};

std::string Route(const wchar_t* proxy, const wchar_t* bypass,
                  const std::wstring& scheme, const std::wstring& host,
                  INTERNET_PORT port) {
  if (bypass) {
    const auto host_port = host + L":" + std::to_wstring(port);
    for (auto pattern : Tokens(Lower(bypass))) {
      if ((pattern == L"<local>" && host.find(L'.') == std::wstring::npos &&
           host.find(L':') == std::wstring::npos) ||
          PathMatchSpecW(host.c_str(), pattern.c_str()) ||
          PathMatchSpecW(host_port.c_str(), pattern.c_str())) return "DIRECT";
    }
  }
  if (!proxy || !*proxy) return "DIRECT";
  std::vector<std::wstring> generic;
  std::vector<std::wstring> matching;
  bool socks_fallback = false;
  for (const auto& token : Tokens(proxy)) {
    const auto equal = token.find(L'=');
    if (equal != std::wstring::npos) {
      const auto mapped_scheme = Lower(token.substr(0, equal));
      const auto mapped_address = token.substr(equal + 1);
      if (mapped_address.empty() ||
          (mapped_scheme != L"http" && mapped_scheme != L"https" &&
           mapped_scheme != L"ftp" && mapped_scheme != L"socks" &&
           mapped_scheme != L"socks4" && mapped_scheme != L"socks5"))
        throw std::runtime_error("Invalid system proxy scheme mapping");
      if (mapped_scheme == L"socks" || mapped_scheme == L"socks4" || mapped_scheme == L"socks5")
        socks_fallback = true;
      if (mapped_scheme == scheme) matching.push_back(mapped_address);
    } else {
      generic.push_back(token);
    }
  }
  // A scheme-specific map intentionally leaves unconfigured schemes direct.
  const auto& entries = !matching.empty() ? matching : generic;
  if (entries.empty()) {
    if (socks_fallback)
      throw std::runtime_error("SOCKS proxies are not supported");
    return "DIRECT";
  }
  std::string output;
  for (auto address : entries) {
    if (Lower(address).compare(0, 7, L"http://") == 0) address.erase(0, 7);
    if (address.empty() || address.find_first_of(L"/@;#?\\ \t\r\n") != std::wstring::npos)
      throw std::runtime_error("Only HTTP proxies without credentials are supported");
    // Require an unambiguous host:port; bracket IPv6 literals.
    const auto colon = address.rfind(L':');
    if (colon == std::wstring::npos) address += L":80";
    const auto port_start = address.rfind(L':');
    const auto port_text = address.substr(port_start + 1);
    const auto proxy_host = address.substr(0, port_start);
    if (proxy_host.empty() || port_text.empty() || port_text.size() > 5 ||
        port_text.find_first_not_of(L"0123456789") != std::wstring::npos ||
        (proxy_host.find(L':') != std::wstring::npos &&
         (proxy_host.front() != L'[' || proxy_host.back() != L']')))
      throw std::runtime_error("Invalid system proxy address");
    const auto proxy_port = std::stoul(port_text);
    if (proxy_port == 0 || proxy_port > 65535)
      throw std::runtime_error("Invalid system proxy port");
    if (!output.empty()) output += "; ";
    output += "PROXY " + Utf8(address);
  }
  return output;
}

std::string Resolve(const std::string& input, HINTERNET session) {
  const auto url = Wide(input);
  URL_COMPONENTS parts{};
  parts.dwStructSize = sizeof(parts);
  parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUserNameLength = parts.dwPasswordLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts) ||
      (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS) ||
      !parts.dwHostNameLength || parts.dwUserNameLength || parts.dwPasswordLength)
    throw std::runtime_error("Expected an HTTP(S) URL without credentials");
  const auto host = Lower(std::wstring(parts.lpszHostName, parts.dwHostNameLength));
  const auto scheme = parts.nScheme == INTERNET_SCHEME_HTTPS ? L"https" : L"http";
  IeConfig config;
  if (!WinHttpGetIEProxyConfigForCurrentUser(&config.value))
    throw std::runtime_error("Cannot read Windows system proxy settings");
  if (config.value.lpszAutoConfigUrl || config.value.fAutoDetect) {
    if (!session) throw std::runtime_error("Cannot start Windows proxy resolver");
    WINHTTP_AUTOPROXY_OPTIONS options{};
    if (config.value.lpszAutoConfigUrl) {
      options.dwFlags |= WINHTTP_AUTOPROXY_CONFIG_URL;
      options.lpszAutoConfigUrl = config.value.lpszAutoConfigUrl;
    }
    if (config.value.fAutoDetect) {
      options.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT;
      options.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A;
    }
    // Never silently send logged-in user's credentials to a PAC server.
    options.fAutoLogonIfChallenged = FALSE;
    ProxyInfo info;
    if (WinHttpGetProxyForUrl(session, url.c_str(), &options, &info.value)) {
      if (info.value.dwAccessType == WINHTTP_ACCESS_TYPE_NO_PROXY) return "DIRECT";
      if (info.value.dwAccessType != WINHTTP_ACCESS_TYPE_NAMED_PROXY ||
          !info.value.lpszProxy || Tokens(info.value.lpszProxy).empty())
        throw std::runtime_error("Windows automatic proxy resolution returned no routes");
      return Route(info.value.lpszProxy, info.value.lpszProxyBypass, scheme, host, parts.nPort);
    }
    const DWORD error = GetLastError();
    if (!config.value.lpszProxy &&
        !(error == ERROR_WINHTTP_AUTODETECTION_FAILED && !config.value.lpszAutoConfigUrl))
      throw std::runtime_error("Windows automatic proxy resolution failed");
  }
  return Route(config.value.lpszProxy, config.value.lpszProxyBypass, scheme, host, parts.nPort);
}
}  // namespace

// This state contains no Flutter objects or references to the window owner.
// A slow PAC/WPAD call may finish after teardown without blocking the UI or
// retaining the engine. Session reuse also preserves WinHTTP's PAC/WPAD cache.
struct NetworkProxy::WorkerState {
  using Clock = std::chrono::steady_clock;
  struct Request {
    uint64_t id;
    std::string url;
    Clock::time_point deadline;
    std::string route;
    std::string error;
  };
  std::mutex mutex;
  std::condition_variable wake;
  bool stopping = false;
  HWND window = nullptr;
  std::deque<Request> pending;
  std::deque<Request> completed;
};

NetworkProxy::NetworkProxy(HWND window, flutter::BinaryMessenger* messenger)
    : state_(std::make_shared<WorkerState>()) {
  state_->window = window;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.focubili/network_proxy", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, std::unique_ptr<Result> result) {
    if (call.method_name() == "configure") { result->Success(); return; }
    if (call.method_name() != "resolve") { result->NotImplemented(); return; }
    const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!args) { result->Error("invalid_url", "Expected an HTTP(S) URL"); return; }
    const auto found = args->find(flutter::EncodableValue("url"));
    const auto* url = found != args->end() ? std::get_if<std::string>(&found->second) : nullptr;
    if (!url || url->empty() || url->size() > 32768) {
      result->Error("invalid_url", "Expected an HTTP(S) URL"); return;
    }
    // Bound outstanding replies too, not just work waiting behind a PAC call.
    CompleteResults();
    if (results_.size() >= 64) {
      result->Error("proxy_busy", "System proxy resolver is busy; retry later"); return;
    }
    const uint64_t id = ++next_request_;
    results_.emplace(id, std::move(result));
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->pending.push_back(WorkerState::Request{id, *url,
          WorkerState::Clock::now() + std::chrono::seconds(8), {}, {}});
    }
    state_->wake.notify_one();
  });
  std::thread([state = state_] { Run(state); }).detach();
}
NetworkProxy::~NetworkProxy() {
  channel_->SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->stopping = true;
    state_->window = nullptr;
    state_->pending.clear();
    state_->completed.clear();
  }
  state_->wake.notify_one();
  for (auto& entry : results_) entry.second->Error("proxy_cancelled", "Application is closing");
}
void NetworkProxy::Run(std::shared_ptr<WorkerState> state) {
  Session session;
  if (session.value) WinHttpSetTimeouts(session.value, 3000, 3000, 3000, 3000);
  for (;;) {
    WorkerState::Request request;
    {
      std::unique_lock<std::mutex> lock(state->mutex);
      state->wake.wait(lock, [&state] { return state->stopping || !state->pending.empty(); });
      if (state->stopping) return;
      request = std::move(state->pending.front());
      state->pending.pop_front();
    }
    try {
      if (WorkerState::Clock::now() >= request.deadline)
        throw std::runtime_error("System proxy lookup expired before execution");
      request.route = Resolve(request.url, session.value);
      if (WorkerState::Clock::now() >= request.deadline)
        throw std::runtime_error("System proxy lookup timed out");
    } catch (const std::exception& error) { request.error = error.what(); }
    catch (...) { request.error = "System proxy resolution failed"; }
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->stopping) return;
      state->completed.push_back(std::move(request));
      PostMessage(state->window, kResultMessage, 0, 0);
    }
  }
}
void NetworkProxy::CompleteResults() {
  std::deque<WorkerState::Request> completed;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    completed.swap(state_->completed);
  }
  for (const auto& request : completed) {
    const auto found = results_.find(request.id);
    if (found == results_.end()) continue;
    auto result = std::move(found->second);
    results_.erase(found);
    if (request.error.empty()) result->Success(flutter::EncodableValue(request.route));
    else result->Error("proxy_resolution_failed", request.error);
  }
}
