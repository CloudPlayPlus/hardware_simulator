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
  bool is_running() const;

private:
  struct WorkerState;

  struct InspectionRequest {
    POINT point = {};
    std::uint64_t sequence = 0;
  };

  static void WorkerMain(std::shared_ptr<WorkerState> state,
                         std::promise<bool> started);
  static WindowsTextInputDecision Inspect(
      ::IUIAutomation *automation, const InspectionRequest &request);

  Callback callback_;
  std::shared_ptr<WorkerState> state_;
  std::thread worker_thread_;
};

} // namespace hardware_simulator

#endif // HARDWARE_SIMULATOR_WINDOWS_WINDOWS_EDITING_EVENT_MONITOR_H_
