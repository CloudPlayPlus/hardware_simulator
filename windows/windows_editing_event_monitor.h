#ifndef HARDWARE_SIMULATOR_WINDOWS_WINDOWS_EDITING_EVENT_MONITOR_H_
#define HARDWARE_SIMULATOR_WINDOWS_WINDOWS_EDITING_EVENT_MONITOR_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>

struct IUIAutomation;

namespace hardware_simulator {

struct WindowsTextInputDecision {
  bool active = false;
  std::optional<bool> secure;
};

struct WindowsTextInputTraits {
  std::int32_t control_type_id = 0;
  bool supports_text_pattern = false;
  bool supports_value_pattern = false;
  bool supports_text_edit_pattern = false;
  bool has_active_text_caret = false;
  bool read_only = false;
  bool known_rich_text_editor = false;
};

bool IsWindowsTextInputCandidate(const WindowsTextInputTraits &traits);

class WindowsEditingEventMonitor {
public:
  using Callback = std::function<void(const WindowsTextInputDecision &)>;

  explicit WindowsEditingEventMonitor(Callback callback);
  ~WindowsEditingEventMonitor();

  WindowsEditingEventMonitor(const WindowsEditingEventMonitor &) = delete;
  WindowsEditingEventMonitor &
  operator=(const WindowsEditingEventMonitor &) = delete;

  bool Start();
  void Stop();
  void InspectAfterRemoteClick();
  bool is_running() const { return running_.load(); }

private:
  struct InspectionRequest {
    POINT point = {};
    std::uint64_t sequence = 0;
  };

  void WorkerMain(std::promise<bool> started);
  WindowsTextInputDecision Inspect(const InspectionRequest &request);

  Callback callback_;
  std::atomic<bool> running_ = false;
  std::atomic<DWORD> worker_thread_id_ = 0;
  std::thread worker_thread_;
  HANDLE stop_event_ = nullptr;
  HANDLE request_event_ = nullptr;
  std::mutex request_mutex_;
  std::optional<InspectionRequest> pending_request_;
  std::uint64_t next_sequence_ = 0;
  ::IUIAutomation *automation_ = nullptr;
};

} // namespace hardware_simulator

#endif // HARDWARE_SIMULATOR_WINDOWS_WINDOWS_EDITING_EVENT_MONITOR_H_
