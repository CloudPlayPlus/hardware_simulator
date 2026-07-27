#ifndef FLUTTER_PLUGIN_HARDWARE_SIMULATOR_PLUGIN_H_
#define FLUTTER_PLUGIN_HARDWARE_SIMULATOR_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <mutex>
#include <thread>
#include <windows.h>
#include <vector>
#include <functional>
#include <map>
#include "SmartKeyboardBlocker.h"

struct MonitorInfo {
    RECT rect;
    bool is_primary;
};

namespace hardware_simulator {

class HardwareSimulatorPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  HardwareSimulatorPlugin();

  virtual ~HardwareSimulatorPlugin();

  // Disallow copy and assign.
  HardwareSimulatorPlugin(const HardwareSimulatorPlugin&) = delete;
  HardwareSimulatorPlugin& operator=(const HardwareSimulatorPlugin&) = delete;

  void StartMonitorThread();
  void StopMonitorThread();

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Immersive mode management
  void SetImmersiveMode(bool enabled);
  bool IsImmersiveModeEnabled() const { return immersive_mode_enabled_; }
  void OnKeyBlocked(const DWORD vk_code, bool isDown);

  // Cursor lock management
  void LockCursor();
  void UnlockCursor();
  void UnlockCursorAndReseed(double window_x_percent, double window_y_percent);
  bool IsCursorLocked() const { return cursor_locked_; }
  
  // Static monitor management
  static void UpdateStaticMonitors();
  static const std::vector<MonitorInfo>& GetStaticMonitors();
  
  // Display count change callback management
  static void addDisplayCountChangedCallback(std::function<void(int)> callback, int callbackId);
  static void removeDisplayCountChangedCallback(int callbackId);
  static void notifyDisplayCountChanged(int displayCount);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<std::thread> monitor_thread_;
  bool immersive_mode_enabled_ = false;
  
  // Cursor lock related members
  bool cursor_locked_ = false;
  RECT clip_rect_ = {0};
  POINT locked_cursor_pos_ = {0};  // 记录锁定时的鼠标位置
  HWND main_window_ = nullptr;
  HWND flutter_view_window_ = nullptr;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  
  // Raw Input related members
  bool raw_input_registered_ = false;
  std::optional<int> raw_input_proc_id_;
  static std::optional<int> dpi_monitor_proc_id_;
  
  // Static monitor management
  static std::vector<MonitorInfo> static_monitors_;
  
  // Display count change callbacks
  static std::map<int, std::function<void(int)>> display_count_callbacks_;
  static std::mutex display_count_callbacks_mutex_;
  static int previous_display_count_;
  
  // Helper methods for cursor lock
  void CleanupCursorLock();
  HWND FindFlutterWindow();
  bool SubscribeToRawInputData();
  void UnsubscribeFromRawInputData();
};

}  // namespace hardware_simulator

#endif  // FLUTTER_PLUGIN_HARDWARE_SIMULATOR_PLUGIN_H_
