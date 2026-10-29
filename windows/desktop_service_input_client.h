#ifndef HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_
#define HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_

#include <windows.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "virtual_display.h"

#ifdef CLOUDPLAYPLUS_DIRECT_INPUT
namespace desktop_svc { class InputDispatcher; }
#endif

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
  bool RestoreDisplayConfiguration(
      const std::vector<DISPLAYCONFIG_PATH_INFO>& paths,
      const std::vector<DISPLAYCONFIG_MODE_INFO>& modes, LONG& status,
      bool persist = true);
  void Close();

 private:
  DesktopServiceInputClient();
  ~DesktopServiceInputClient();

  DesktopServiceInputClient(const DesktopServiceInputClient&) = delete;
  DesktopServiceInputClient& operator=(const DesktopServiceInputClient&) = delete;

  friend class DesktopServiceInputClientTestPeer;
#ifdef CLOUDPLAYPLUS_DIRECT_INPUT
  std::unique_ptr<desktop_svc::InputDispatcher> direct_input_;
#endif
  struct ControlConnection {
    DesktopServiceInputClient* client;
    ~ControlConnection() { client->ClosePipeLocked(); }
  };
  bool StartInputThreadLocked();
  bool EnqueueLocked(const void* data, uint32_t size);
  void InputLoop(HANDLE write_event);
  HANDLE TryConnect();
  bool EnsureConnectedLocked();
  bool SendRawLocked(const void* data, uint32_t size);
  bool ExchangeRawLocked(uint32_t type, const void* payload,
                         uint32_t payload_size, uint32_t expected_type,
                         void* response, uint32_t response_size,
                         DWORD timeout_ms = 1000);
  bool ReadRawLocked(std::vector<uint8_t>& data, DWORD timeout_ms);
  bool SendKeyboardLocked(const KEYBDINPUT& input);
  bool SendMouseLocked(const MOUSEINPUT& input);
  void ClosePipeLocked();

  std::mutex mutex_;
  std::condition_variable input_cv_;
  std::thread input_thread_;
  std::deque<std::vector<uint8_t>> input_queue_;
  HANDLE interrupt_event_ = nullptr;
  bool input_connected_ = false;
  bool stop_requested_ = false;
  bool reset_requested_ = false;
  bool service_available_ = false;
  std::wstring pipe_name_ = L"\\\\.\\pipe\\cloudplayplus_desktop_input";

  // 配置查询独占另一条连接；其等待不能持有输入队列的锁。
  std::mutex control_mutex_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  HANDLE control_write_event_ = nullptr;
  HANDLE control_read_event_ = nullptr;
  uint32_t next_seq_ = 1;
};

}  // namespace hardware_simulator

#endif  // HARDWARE_SIMULATOR_DESKTOP_SERVICE_INPUT_CLIENT_H_
