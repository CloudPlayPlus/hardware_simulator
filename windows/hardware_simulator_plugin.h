#ifndef FLUTTER_PLUGIN_HARDWARE_SIMULATOR_PLUGIN_H_
#define FLUTTER_PLUGIN_HARDWARE_SIMULATOR_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <windows.h>
#include <vector>
#include <functional>
#include <map>
#include "SmartKeyboardBlocker.h"

struct MonitorInfo {
    RECT rect;
    bool is_primary;
    int screen_id = -1;
};

namespace hardware_simulator {

class WindowsEditingEventMonitor;
struct WindowsTextInputDecision;

// Converts monitor-local normalized coordinates into physical virtual-desktop
// pixels. The result intentionally preserves negative virtual origins.
std::optional<POINT> NormalizedPointOnMonitor(
    const RECT& monitor_rect,
    double x_percent,
    double y_percent);

// Resolves the raw EnumDisplayDevices device index used by libwebrtc and the
// input protocol to the current monitor bounds. Returns nullopt when the raw
// id is no longer active instead of falling back to a different monitor.
std::optional<RECT> MonitorRectForScreenId(
    const std::vector<MonitorInfo>& monitors,
    int screen_id);

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
  std::unique_ptr<WindowsEditingEventMonitor> windows_editing_event_monitor_;
  std::mutex windows_editing_event_mutex_;
  std::unique_ptr<WindowsTextInputDecision>
      pending_windows_text_input_decision_;
  bool windows_editing_message_posted_ = false;
  HWND windows_editing_window_ = nullptr;
  UINT windows_editing_message_id_ = 0;
  std::optional<int> windows_editing_proc_id_;
  bool immersive_mode_enabled_ = false;
  
  // Cursor lock related members
  bool cursor_locked_ = false;
  RECT clip_rect_ = {0};
  POINT locked_cursor_pos_ = {0};  // 记录锁定时的鼠标位置
  HWND main_window_ = nullptr;
  HWND flutter_view_window_ = nullptr;
  float cursor_source_device_pixel_ratio_ = 1.0f;
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
  bool StartWindowsEditingEventMonitor();
  void StopWindowsEditingEventMonitor();
  void QueueWindowsTextInputDecision(
      const WindowsTextInputDecision& decision);
  void SendWindowsTextInputDecision(
      const WindowsTextInputDecision& decision);
  HWND FindFlutterWindow();
  bool SubscribeToRawInputData();
  void UnsubscribeFromRawInputData();
};

}  // namespace hardware_simulator

#endif  // FLUTTER_PLUGIN_HARDWARE_SIMULATOR_PLUGIN_H_
