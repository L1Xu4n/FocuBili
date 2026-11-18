#ifndef RUNNER_NETWORK_PROXY_H_
#define RUNNER_NETWORK_PROXY_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <cstdint>
#include <memory>
#include <unordered_map>

// All Flutter replies are delivered on the platform thread. WinHTTP/PAC runs
// on a bounded worker; no process-wide or OS proxy settings are modified.
class NetworkProxy {
 public:
  static constexpr UINT kResultMessage = WM_APP + 0x47;
  NetworkProxy(HWND window, flutter::BinaryMessenger* messenger);
  ~NetworkProxy();
  void CompleteResults();

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;
  struct WorkerState;
  static void Run(std::shared_ptr<WorkerState> state);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<WorkerState> state_;
  uint64_t next_request_ = 0;
  std::unordered_map<uint64_t, std::unique_ptr<Result>> results_;
};
#endif
