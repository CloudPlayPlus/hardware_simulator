#ifndef FLUTTER_PLUGIN_HARDWARE_SIMULATOR_TEXT_FOCUS_MONITOR_H_
#define FLUTTER_PLUGIN_HARDWARE_SIMULATOR_TEXT_FOCUS_MONITOR_H_

#include <cstdint>
#include <functional>
#include <string>

namespace hardware_simulator {

struct TextFocusInfo {
  std::string name;
  std::string localized_control_type;
  std::string class_name;
  std::string automation_id;
  std::string process_name;
  int control_type_id = 0;
  int process_id = 0;
  int64_t native_window_handle = 0;
  bool is_password = false;
  bool is_read_only = false;
  bool supports_text_pattern = false;
  bool supports_value_pattern = false;
  bool supports_text_edit_pattern = false;
  bool has_active_text_caret = false;
  int64_t timestamp_ms = 0;
};

class TextFocusMonitor {
 public:
  using Callback = std::function<void(const TextFocusInfo&)>;

  static void Start(Callback callback, int callback_id);
  static void Stop(int callback_id);
  static void StopAll();
};

}  // namespace hardware_simulator

#endif  // FLUTTER_PLUGIN_HARDWARE_SIMULATOR_TEXT_FOCUS_MONITOR_H_
