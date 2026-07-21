#ifndef HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_
#define HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_

#include <windows.h>

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

#include "virtual_display.h"

namespace hardware_simulator {

class DesktopServiceInputClient {
 public:
  static DesktopServiceInputClient& Instance();

  void SetServiceAvailable(bool available);
  bool SendInputMessage(const INPUT& input);
  bool SendTouchInput(const POINTER_TYPE_INFO* pointers, uint32_t count);
  bool SendPenInput(const POINTER_TYPE_INFO& pointer);
  bool GetCustomDisplayConfigs(
      std::vector<VirtualDisplay::DisplayConfig>& configs);
  bool SetCustomDisplayConfigs(
      const std::vector<VirtualDisplay::DisplayConfig>& configs,
      bool& success);
  void Close();

 private:
  enum class ServiceState {
    kDisconnected,
    kProbing,
    kConnected,
  };

  DesktopServiceInputClient() = default;
  ~DesktopServiceInputClient();

  DesktopServiceInputClient(const DesktopServiceInputClient&) = delete;
  DesktopServiceInputClient& operator=(const DesktopServiceInputClient&) = delete;

  bool EnsureProbeThreadLocked();
  void RequestProbeLocked();
  void ProbeLoop();
  HANDLE TryConnect();
  bool EnsureConnectedLocked();
  bool SendRawLocked(const void* data, uint32_t size);
  bool ExchangeRawLocked(uint32_t type, const void* payload,
                         uint32_t payload_size, uint32_t expected_type,
                         void* response, uint32_t response_size);
  bool ReadRawLocked(std::vector<uint8_t>& data);
  bool SendKeyboardLocked(const KEYBDINPUT& input);
  bool SendMouseLocked(const MOUSEINPUT& input);
  void ClosePipeLocked();

  std::mutex mutex_;
  std::condition_variable probe_cv_;
  std::thread probe_thread_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  ServiceState state_ = ServiceState::kDisconnected;
  bool stop_requested_ = false;
  bool probe_requested_ = false;
  bool probe_in_flight_ = false;
  bool service_available_ = false;
  uint32_t next_seq_ = 1;
};

}  // namespace hardware_simulator

#endif  // HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_
