#ifndef HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_
#define HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_

#include <windows.h>

#include <chrono>
#include <cstdint>
#include <mutex>

namespace hardware_simulator {

class DesktopServiceInputClient {
 public:
  static DesktopServiceInputClient& Instance();

  bool SendInputMessage(const INPUT& input);
  void Close();

 private:
  DesktopServiceInputClient() = default;
  ~DesktopServiceInputClient();

  DesktopServiceInputClient(const DesktopServiceInputClient&) = delete;
  DesktopServiceInputClient& operator=(const DesktopServiceInputClient&) = delete;

  bool EnsureConnectedLocked();
  bool SendRawLocked(const void* data, uint32_t size);
  bool SendKeyboardLocked(const KEYBDINPUT& input);
  bool SendMouseLocked(const MOUSEINPUT& input);
  void CloseLocked();

  std::mutex mutex_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  HANDLE stop_event_ = nullptr;
  std::chrono::steady_clock::time_point next_probe_time_{};
};

}  // namespace hardware_simulator

#endif  // HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_
