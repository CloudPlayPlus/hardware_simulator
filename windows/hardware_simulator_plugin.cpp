#include "hardware_simulator_plugin.h"

#include "cursor_monitor.h"
#include "desktop_service_input_client.h"
#include "gamecontroller_manager.h"
#include "notification_window.h"
#include "trackpad_scroll_accumulator.h"
#include "virtual_display_control.h"
#include "windows_editing_event_monitor.h"
#include "windows_text_input_injector.h"
#include "SmartKeyboardBlocker.h"

// This must be included before many other Windows headers.
#include <windows.h>

// For getPlatformVersion; remove unless needed for your plugin implementation.
#include <VersionHelpers.h>

// For HID usage constants
#include <hidusage.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <thread>

// Used to run win32 service.
#include <sddl.h>
#include <shellapi.h>
#include <shlwapi.h>  // PathCombineW, PathRemoveFileSpecW
#include <commctrl.h>
#include <string>

#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "comctl32.lib")

typedef HSYNTHETICPOINTERDEVICE(WINAPI* PFN_CreateSyntheticPointerDevice)(POINTER_INPUT_TYPE pointerType, ULONG maxCount, POINTER_FEEDBACK_MODE mode);
typedef BOOL(WINAPI* PFN_InjectSyntheticPointerInput)(HSYNTHETICPOINTERDEVICE device, CONST POINTER_TYPE_INFO* pointerInfo, UINT32 count);
typedef VOID(WINAPI* PFN_DestroySyntheticPointerDevice)(HSYNTHETICPOINTERDEVICE device);

namespace hardware_simulator {

// Marks the one programmatic mouse move used to re-seed the viewer cursor
// after pointer lock. The Flutter child-window subclass consumes only moves
// with this tag so Flutter never forwards them to the remote host.
constexpr ULONG_PTR kCursorReseedExtraInfo =
    static_cast<ULONG_PTR>(0x43505052);  // "CPPR"
constexpr UINT_PTR kCursorReseedSubclassId =
    static_cast<UINT_PTR>(0x43505052);
constexpr wchar_t kWindowsTextInputDecisionMessageName[] =
    L"CloudPlayPlus.HardwareSimulator.WindowsTextInputDecision";
// Dart normalizes platform-specific scroll magnitudes. The native adapter only
// converts the logical page direction and clamps it to a safe Win32 range.
constexpr double kMaxWindowsWheelDistance =
    static_cast<double>(WHEEL_DELTA) * 100.0;
int logicalScrollToWindowsWheel(double logical_distance, bool invert) {
  if (!std::isfinite(logical_distance)) {
    return 0;
  }
  const double direction = invert ? -1.0 : 1.0;
  const double scaled = logical_distance * direction;
  const double clamped = (std::clamp)(
      scaled, -kMaxWindowsWheelDistance, kMaxWindowsWheelDistance);
  return static_cast<int>(std::lround(clamped));
}

std::optional<std::int64_t> ReadOptionalInt64(
    const flutter::EncodableMap* args,
    const char* key) {
  if (args == nullptr) {
    return std::nullopt;
  }
  const auto iterator = args->find(flutter::EncodableValue(key));
  if (iterator == args->end()) {
    return std::nullopt;
  }
  if (const auto value = std::get_if<std::int32_t>(&iterator->second)) {
    return static_cast<std::int64_t>(*value);
  }
  if (const auto value = std::get_if<std::int64_t>(&iterator->second)) {
    return *value;
  }
  return std::nullopt;
}

bool adjust_touch_to_screen(
    int screen_index,
    double x_percent,
    double y_percent,
    LONG& out_x,
    LONG& out_y);

std::optional<POINT> NormalizedPointOnMonitor(
    const RECT& monitor_rect,
    double x_percent,
    double y_percent) {
  if (!std::isfinite(x_percent) || !std::isfinite(y_percent) ||
      monitor_rect.right <= monitor_rect.left ||
      monitor_rect.bottom <= monitor_rect.top) {
    return std::nullopt;
  }
  const double clamped_x = (std::clamp)(x_percent, 0.0, 1.0);
  const double clamped_y = (std::clamp)(y_percent, 0.0, 1.0);
  const LONG width = monitor_rect.right - monitor_rect.left;
  const LONG height = monitor_rect.bottom - monitor_rect.top;
  return POINT{
      monitor_rect.left +
          static_cast<LONG>(std::lround(clamped_x * (width - 1))),
      monitor_rect.top +
          static_cast<LONG>(std::lround(clamped_y * (height - 1)))};
}

std::optional<RECT> MonitorRectForScreenId(
    const std::vector<MonitorInfo>& monitors,
    int screen_id) {
  const auto monitor = std::find_if(
      monitors.begin(), monitors.end(), [screen_id](const MonitorInfo& info) {
        return info.screen_id == screen_id;
      });
  return monitor == monitors.end() ? std::nullopt
                                   : std::optional<RECT>(monitor->rect);
}

std::optional<POINT> PointerPointForScreen(
    int screen_id,
    double x,
    double y) {
  LONG point_x = 0;
  LONG point_y = 0;
  if (!adjust_touch_to_screen(screen_id, x, y, point_x, point_y)) {
    return std::nullopt;
  }
  return POINT{point_x, point_y};
}

LRESULT CALLBACK CursorReseedSubclassProc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam,
    UINT_PTR subclass_id,
    DWORD_PTR reference_data) {
  if (message == WM_MOUSEMOVE &&
      GetMessageExtraInfo() == kCursorReseedExtraInfo) {
    return 0;
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

// Function declarations
void performKeyEvent(uint16_t modcode, bool isDown, bool isRepeat);
void performTouchEvent(int screenId, double x, double y, uint32_t touchId, bool isDown, bool isRepeat);
void performPenEvent(int screenId, double x, double y, bool isDown, bool hasButton, double pressure, double rotation, double tilt);
void performPenMove(int screenId, double x, double y, bool hasButton, double pressure, double rotation, double tilt);
void performPenHover(int screenId, double x, double y);
void send_pen_input();
void clearAllPressedEvents();
bool setPrimaryDisplay(int displayIndex);

thread_local HDESK _lastKnownInputDesktop = nullptr;
PFN_CreateSyntheticPointerDevice fnCreateSyntheticPointerDevice = nullptr;
PFN_InjectSyntheticPointerInput fnInjectSyntheticPointerInput = nullptr;
PFN_DestroySyntheticPointerDevice fnDestroySyntheticPointerDevice = nullptr;

HSYNTHETICPOINTERDEVICE g_touchDevice = nullptr;
POINTER_TYPE_INFO g_touchInfo[10] = {};
UINT32 g_activeTouchSlots = 0;

HSYNTHETICPOINTERDEVICE g_penDevice = nullptr;
POINTER_TYPE_INFO g_penInfo = {};

// auto repeat feature
struct KeyState {
    bool isDown = false;
    std::chrono::steady_clock::time_point lastEventTime;
};

struct TouchState {
    bool isDown = false;
    double x = 0;
    double y = 0;
    int screenId = 0;
    std::chrono::steady_clock::time_point lastEventTime;
};

static bool g_auto_repeat_enabled = true;
static std::atomic<bool> g_thread_running{false};
static std::recursive_mutex g_event_mutex;
static std::unordered_map<uint16_t, KeyState> g_key_states;
static uint16_t g_last_known_key_down = 0;
static std::unordered_map<uint32_t, TouchState> g_touch_states;
static std::chrono::steady_clock::time_point g_last_pen_input_time;
static std::chrono::steady_clock::time_point g_last_pen_refresh_time;
constexpr auto PEN_REPEAT_INTERVAL = std::chrono::milliseconds(50);
constexpr auto PEN_HOVER_IDLE_TIMEOUT = std::chrono::milliseconds(250);
constexpr auto EDGE_TRIGGERED_POINTER_FLAGS =
    POINTER_FLAG_DOWN | POINTER_FLAG_UP | POINTER_FLAG_CANCELED | POINTER_FLAG_UPDATE;

static void clearPenEdgeTriggeredFlags() {
    g_penInfo.penInfo.pointerInfo.pointerFlags &= ~EDGE_TRIGGERED_POINTER_FLAGS;
}

static bool hasActivePenPointer() {
    return g_penInfo.penInfo.pointerInfo.pointerFlags != POINTER_FLAG_NONE;
}

static bool hasHoverOnlyPenPointer() {
    auto flags = g_penInfo.penInfo.pointerInfo.pointerFlags;
    return (flags & POINTER_FLAG_INRANGE) != 0 &&
        (flags & POINTER_FLAG_INCONTACT) == 0;
}

static void clearActivePenPointer() {
    if (!hasActivePenPointer()) {
        return;
    }

    auto& penFlags = g_penInfo.penInfo.pointerInfo.pointerFlags;
    const bool wasInContact = (penFlags & POINTER_FLAG_INCONTACT) != 0;
    penFlags &= ~(POINTER_FLAG_INCONTACT | POINTER_FLAG_INRANGE);
    penFlags |= wasInContact ? POINTER_FLAG_UP : POINTER_FLAG_UPDATE;
    send_pen_input();
    clearPenEdgeTriggeredFlags();
    g_last_pen_input_time = {};
    g_last_pen_refresh_time = {};
}

static void recordPenInputAfterSend() {
    if (!hasActivePenPointer()) {
        g_last_pen_input_time = {};
        g_last_pen_refresh_time = {};
        return;
    }

    auto now = std::chrono::steady_clock::now();
    g_last_pen_input_time = now;
    g_last_pen_refresh_time = now;
}

static void EventMonitorThread() {
    while (g_thread_running) {
        if (g_auto_repeat_enabled) {
            auto now = std::chrono::steady_clock::now();
            
            {
                std::lock_guard<std::recursive_mutex> lock(g_event_mutex);
                
                // Check key states
                if (g_key_states.find(g_last_known_key_down) != g_key_states.end()) {
                    if (g_key_states[g_last_known_key_down].isDown) {
                        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(
                            now - g_key_states[g_last_known_key_down].lastEventTime).count();
                        if (duration >= 500) {  // 500ms repeat interval for keys
                            performKeyEvent(g_last_known_key_down, true, true);
                        }
                    }
                }
                
                // Check touch states
                for (auto& [id, state] : g_touch_states) {
                    if (state.isDown) {
                        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(
                            now - state.lastEventTime).count();
                        if (duration >= 300) {  // 300ms repeat interval for touch
                            performTouchEvent(state.screenId, state.x, state.y, id, true, true);
                            state.lastEventTime = now;
                        }
                    }
                }

                if (hasActivePenPointer()) {
                    // Keep the current pointer state alive, but do not keep a
                    // stale hover alive forever after the real pen leaves range.
                    if (hasHoverOnlyPenPointer() &&
                        now - g_last_pen_input_time >= PEN_HOVER_IDLE_TIMEOUT) {
                        clearActivePenPointer();
                    } else if (now - g_last_pen_refresh_time >= PEN_REPEAT_INTERVAL) {
                        send_pen_input();
                        g_last_pen_refresh_time = now;
                    }
                }
            }
        }
        
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

void HardwareSimulatorPlugin::StopMonitorThread() {
    if (g_thread_running) {
        g_thread_running = false;
        if (monitor_thread_ && monitor_thread_->joinable()) {
            monitor_thread_->join();
        }
        monitor_thread_.reset();
    }
}

void HardwareSimulatorPlugin::StartMonitorThread() {
    if (!g_thread_running) {
        g_thread_running = true;
        monitor_thread_ = std::make_unique<std::thread>(EventMonitorThread);
    }
}

void SetAutoRepeatEnabled(bool enabled) {
    if (g_auto_repeat_enabled == enabled) {
        return;  // No change needed
    }

    g_auto_repeat_enabled = enabled;
    
    // Note: Since this is a global function, we can't access the plugin instance directly.
    // The auto-repeat state will be handled when the thread is next started/stopped.
    if (!enabled) {
        // Clear any existing states
        std::lock_guard<std::recursive_mutex> lock(g_event_mutex);
        g_key_states.clear();
        g_touch_states.clear();
    }
}
// end of auto repeat feature

//Todo:OpenInputDesktop should fail because we have a window resource in this process.
//We need to create another process to handle this scenario.
HDESK syncThreadDesktop() {
    auto hDesk = OpenInputDesktop(DF_ALLOWOTHERACCOUNTHOOK, FALSE, GENERIC_ALL);
    if (!hDesk) {
        //auto err = GetLastError();
        //BOOST_LOG(error) << "Failed to Open Input Desktop [0x"sv << util::hex(err).to_string_view() << ']';

        return nullptr;
    }

    if (!SetThreadDesktop(hDesk)) {
        //auto err = GetLastError();
        //BOOST_LOG(error) << "Failed to sync desktop to thread [0x"sv << util::hex(err).to_string_view() << ']';
    }

    CloseDesktop(hDesk);

    return hDesk;
}

std::optional<int> HardwareSimulatorPlugin::dpi_monitor_proc_id_ = std::nullopt;
std::vector<MonitorInfo> HardwareSimulatorPlugin::static_monitors_;
std::map<int, std::function<void(int)>> HardwareSimulatorPlugin::display_count_callbacks_;
std::mutex HardwareSimulatorPlugin::display_count_callbacks_mutex_;
int HardwareSimulatorPlugin::previous_display_count_ = -1;

void HardwareSimulatorPlugin::UpdateStaticMonitors() {
    static_monitors_.clear();
    
    // Original implementation using EnumDisplayMonitors (commented out)
    /*
    EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR hMon, HDC, LPRECT rect, LPARAM data) {
        auto& list = *reinterpret_cast<std::vector<MonitorInfo>*>(data);
        MONITORINFO info{ sizeof(MONITORINFO) };
        GetMonitorInfo(hMon, &info);
        list.push_back({ info.rcMonitor, (info.dwFlags & MONITORINFOF_PRIMARY) != 0 });
        return TRUE;
        }, reinterpret_cast<LPARAM>(&static_monitors_));
    */
    
    // New implementation using EnumDisplayDevices
    DISPLAY_DEVICE displayDevice;
    displayDevice.cb = sizeof(DISPLAY_DEVICE);
    
    for (DWORD deviceNum = 0; EnumDisplayDevices(NULL, deviceNum, &displayDevice, 0); deviceNum++) {
        if (displayDevice.StateFlags & DISPLAY_DEVICE_ACTIVE) {
            DEVMODE devMode;
            devMode.dmSize = sizeof(DEVMODE);
            
            if (EnumDisplaySettings(displayDevice.DeviceName, ENUM_CURRENT_SETTINGS, &devMode)) {
                MonitorInfo info;
                info.rect.left = devMode.dmPosition.x;
                info.rect.top = devMode.dmPosition.y;
                info.rect.right = devMode.dmPosition.x + devMode.dmPelsWidth;
                info.rect.bottom = devMode.dmPosition.y + devMode.dmPelsHeight;
                info.is_primary = (displayDevice.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
                info.screen_id = static_cast<int>(deviceNum);
                
                static_monitors_.push_back(info);
            }
        }
    }
    
    // Check if display count changed and notify callbacks
    int current_display_count = static_cast<int>(static_monitors_.size());
    // We report even the count is not changed, because it maybe a screen switch
    //if (current_display_count != previous_display_count_) {
    notifyDisplayCountChanged(current_display_count);
    //}
}

const std::vector<MonitorInfo>& HardwareSimulatorPlugin::GetStaticMonitors() {
    return static_monitors_;
}

std::vector<MonitorInfo> get_monitors() {
    return HardwareSimulatorPlugin::GetStaticMonitors();
}

bool adjust_to_virtual_desktop(int screen_id, double x_percent, double y_percent, LONG& out_x, LONG& out_y) {
    auto monitors = get_monitors();
    const auto monitor_rect = MonitorRectForScreenId(monitors, screen_id);
    if (!monitor_rect.has_value()) return false;
    const auto point =
        NormalizedPointOnMonitor(*monitor_rect, x_percent, y_percent);
    if (!point.has_value()) return false;

    const int virtual_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int virtual_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int virtual_width =
        (std::max)(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
    const int virtual_height =
        (std::max)(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
    out_x = MulDiv(
        point->x - virtual_x, 65535, (std::max)(1, virtual_width - 1));
    out_y = MulDiv(
        point->y - virtual_y, 65535, (std::max)(1, virtual_height - 1));
    return true;
}

bool adjust_touch_to_screen(int screen_id, double x_percent, double y_percent, LONG& out_x, LONG& out_y) {
    auto monitors = get_monitors();
    const auto monitor_rect = MonitorRectForScreenId(monitors, screen_id);
    if (!monitor_rect.has_value()) {
        out_x = out_y = 0;
        return false;
    }

    const auto point = NormalizedPointOnMonitor(
        *monitor_rect, x_percent, y_percent);
    if (!point.has_value()) {
        out_x = out_y = 0;
        return false;
    }
    out_x = point->x;
    out_y = point->y;
    return true;
}

bool initTouchAPI() {
    HMODULE hUser32 = GetModuleHandleA("user32.dll");
    if (!hUser32) {
        return false;
    }

    fnCreateSyntheticPointerDevice = (PFN_CreateSyntheticPointerDevice)GetProcAddress(hUser32, "CreateSyntheticPointerDevice");
    fnInjectSyntheticPointerInput = (PFN_InjectSyntheticPointerInput)GetProcAddress(hUser32, "InjectSyntheticPointerInput");
    fnDestroySyntheticPointerDevice = (PFN_DestroySyntheticPointerDevice)GetProcAddress(hUser32, "DestroySyntheticPointerDevice");

    return fnCreateSyntheticPointerDevice && fnInjectSyntheticPointerInput && fnDestroySyntheticPointerDevice;
}

bool createTouchDevice() {
    if (!fnCreateSyntheticPointerDevice) {
        initTouchAPI();
        if (!fnCreateSyntheticPointerDevice) {
            return false;
        }
    }

    g_touchDevice = fnCreateSyntheticPointerDevice(PT_TOUCH, ARRAYSIZE(g_touchInfo), POINTER_FEEDBACK_DEFAULT);
    return g_touchDevice != nullptr;
}

void destroyTouchDevice() {
    if (g_touchDevice && fnDestroySyntheticPointerDevice) {
        fnDestroySyntheticPointerDevice(g_touchDevice);
        g_touchDevice = nullptr;
    }
}

bool createPenDevice() {
    if (!fnCreateSyntheticPointerDevice) {
        initTouchAPI();
        if (!fnCreateSyntheticPointerDevice) {
            return false;
        }
    }

    g_penDevice = fnCreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT);
    return g_penDevice != nullptr;
}

void destroyPenDevice() {
    if (g_penDevice && fnDestroySyntheticPointerDevice) {
        fnDestroySyntheticPointerDevice(g_penDevice);
        g_penDevice = nullptr;
    }
    g_penInfo = {};
    g_last_pen_input_time = {};
    g_last_pen_refresh_time = {};
}

bool sendTouchInput() {
    if (DesktopServiceInputClient::Instance().SendTouchInput(
            g_touchInfo, g_activeTouchSlots)) {
        return true;
    }

    if (!g_touchDevice && !createTouchDevice()) {
        return false;
    }
    if (!fnInjectSyntheticPointerInput) {
        return false;
    }

    if (fnInjectSyntheticPointerInput(g_touchDevice, g_touchInfo, g_activeTouchSlots)) {
        return true;
    }

    return false;
}

void async_send_touch_input_retry() {
    while (true) {
        auto send = sendTouchInput();
        if (send == 1) {
            break;
        }

        auto hDesk = syncThreadDesktop();
        if (_lastKnownInputDesktop != hDesk) {
            _lastKnownInputDesktop = hDesk;
        }
        else {
            break;
        }
    }
}

void send_touch_input() {
    auto send = sendTouchInput();
    if (send != true) {
        // put resend into new thread.
        std::future<void> retry_future = std::async(std::launch::async, async_send_touch_input_retry);
        retry_future.wait();
    }
}

bool sendPenInput() {
    if (DesktopServiceInputClient::Instance().SendPenInput(g_penInfo)) {
        return true;
    }

    if (!g_penDevice && !createPenDevice()) {
        return false;
    }
    if (!fnInjectSyntheticPointerInput) {
        return false;
    }

    if (fnInjectSyntheticPointerInput(g_penDevice, &g_penInfo, 1)) {
        return true;
    }

    return false;
}

void async_send_pen_input_retry() {
    while (true) {
        auto send = sendPenInput();
        if (send == 1) {
            break;
        }

        auto hDesk = syncThreadDesktop();
        if (_lastKnownInputDesktop != hDesk) {
            _lastKnownInputDesktop = hDesk;
        }
        else {
            break;
        }
    }
}

void send_pen_input() {
    auto send = sendPenInput();
    if (send != true) {
        // put resend into new thread.
        std::future<void> retry_future = std::async(std::launch::async, async_send_pen_input_retry);
        retry_future.wait();
    }
}

void performTouchEvent(int screenId, double x, double y, uint32_t touchId, bool isDown, bool isRepeat = false) {
    POINTER_TYPE_INFO* pointer = nullptr;
    for (UINT32 i = 0; i < ARRAYSIZE(g_touchInfo); i++) {
        if (g_touchInfo[i].touchInfo.pointerInfo.pointerId == touchId) {
            pointer = &g_touchInfo[i];
            break;
        }
    }

    if (!pointer) {
        for (UINT32 i = 0; i < ARRAYSIZE(g_touchInfo); i++) {
            if (g_touchInfo[i].touchInfo.pointerInfo.pointerFlags == POINTER_FLAG_NONE) {
                pointer = &g_touchInfo[i];
                g_touchInfo[i].touchInfo.pointerInfo.pointerId = touchId;
                g_activeTouchSlots = (g_activeTouchSlots > (i + 1)) ? g_activeTouchSlots : (i + 1);
                break;
            }
        }
    }

    if (!pointer) {
        return;
    }

    pointer->type = PT_TOUCH;
    auto& touchInfo = pointer->touchInfo;
    touchInfo.pointerInfo.pointerType = PT_TOUCH;

    LONG out_x, out_y;
    if (!adjust_touch_to_screen(screenId,x,y,out_x,out_y)) return;
    touchInfo.pointerInfo.ptPixelLocation.x = out_x;//static_cast<LONG>(x * GetSystemMetrics(SM_CXSCREEN));
    touchInfo.pointerInfo.ptPixelLocation.y = out_y;//static_cast<LONG>(y * GetSystemMetrics(SM_CYSCREEN));

    if (isDown) {
        touchInfo.pointerInfo.pointerFlags = TOUCHEVENTF_PRIMARY | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN;
    } else {
        touchInfo.pointerInfo.pointerFlags = POINTER_FLAG_UP;
    }

    touchInfo.touchMask = TOUCH_MASK_CONTACTAREA | TOUCH_MASK_ORIENTATION | TOUCH_MASK_PRESSURE;

    touchInfo.rcContact.left = touchInfo.pointerInfo.ptPixelLocation.x - 10;
    touchInfo.rcContact.right = touchInfo.pointerInfo.ptPixelLocation.x + 10;
    touchInfo.rcContact.top = touchInfo.pointerInfo.ptPixelLocation.y - 10;
    touchInfo.rcContact.bottom = touchInfo.pointerInfo.ptPixelLocation.y + 10;

    touchInfo.pressure = 1024;

    send_touch_input();

    // Add state tracking
    if (g_auto_repeat_enabled && !isRepeat) {
        std::lock_guard<std::recursive_mutex> lock(g_event_mutex);
        if (isDown) {
            g_touch_states[touchId] = {true, x, y, screenId, std::chrono::steady_clock::now()};
        } else if (g_touch_states.find(touchId) != g_touch_states.end()) {
            g_touch_states.erase(touchId);
        }
    }
}

void performTouchMove(int screenId, double x, double y, uint32_t touchId) {
    POINTER_TYPE_INFO* pointer = nullptr;
    for (UINT32 i = 0; i < ARRAYSIZE(g_touchInfo); i++) {
        if (g_touchInfo[i].touchInfo.pointerInfo.pointerId == touchId) {
            pointer = &g_touchInfo[i];
            break;
        }
    }

    if (!pointer) {
        return;
    }

    auto& touchInfo = pointer->touchInfo;

    LONG out_x, out_y;
    if (!adjust_touch_to_screen(screenId, x, y, out_x, out_y)) return;
    touchInfo.pointerInfo.ptPixelLocation.x = out_x;//static_cast<LONG>(x * GetSystemMetrics(SM_CXSCREEN));
    touchInfo.pointerInfo.ptPixelLocation.y = out_y;//static_cast<LONG>(y * GetSystemMetrics(SM_CYSCREEN));

    touchInfo.pointerInfo.pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE;

    touchInfo.rcContact.left = touchInfo.pointerInfo.ptPixelLocation.x - 10;
    touchInfo.rcContact.right = touchInfo.pointerInfo.ptPixelLocation.x + 10;
    touchInfo.rcContact.top = touchInfo.pointerInfo.ptPixelLocation.y - 10;
    touchInfo.rcContact.bottom = touchInfo.pointerInfo.ptPixelLocation.y + 10;

    if (g_auto_repeat_enabled) {
        std::lock_guard<std::recursive_mutex> lock(g_event_mutex);
        if (g_touch_states.find(touchId) != g_touch_states.end()) {
            //update the position
            g_touch_states[touchId] = { true, x, y, screenId, std::chrono::steady_clock::now() };
        }
    }

    send_touch_input();
}

void performPenEvent(int screenId, double x, double y, bool isDown, bool hasButton, double pressure, double rotation, double tilt) {
    std::unique_lock<std::recursive_mutex> lock(g_event_mutex);

    g_penInfo.type = PT_PEN;
    auto& penInfo = g_penInfo.penInfo;
    penInfo.pointerInfo.pointerType = PT_PEN;
    penInfo.pointerInfo.pointerId = 0;

    LONG out_x, out_y;
    if (!adjust_touch_to_screen(screenId, x, y, out_x, out_y)) return;
    penInfo.pointerInfo.ptPixelLocation.x = out_x;
    penInfo.pointerInfo.ptPixelLocation.y = out_y;

    if (isDown) {
        penInfo.pointerInfo.pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN;
    } else {
        // Clear contact and range flags first, then set UP flag
        penInfo.pointerInfo.pointerFlags &= ~(POINTER_FLAG_INCONTACT | POINTER_FLAG_INRANGE);
        penInfo.pointerInfo.pointerFlags |= POINTER_FLAG_UP;
    }

    // Windows only supports a single pen button, so send all buttons as the barrel button
    if (hasButton) {
        penInfo.penFlags |= PEN_FLAG_BARREL;
    } else {
        penInfo.penFlags &= ~PEN_FLAG_BARREL;
    }

    // Default to pen tool type (not eraser)
    penInfo.penFlags &= ~PEN_FLAG_ERASER;

    penInfo.penMask = PEN_MASK_NONE;

    // Windows doesn't support hover distance, so only pass pressure when the pointer is in contact
    if ((penInfo.pointerInfo.pointerFlags & POINTER_FLAG_INCONTACT) && pressure > 0.0) {
        penInfo.penMask |= PEN_MASK_PRESSURE;
        // Convert the 0.0..1.0 double to the 0..1024 range that Windows uses
        penInfo.pressure = static_cast<UINT32>(pressure * 1024.0);
    } else {
        penInfo.pressure = 0;
    }

    if (rotation >= 0.0 && rotation <= 360.0) {
        penInfo.penMask |= PEN_MASK_ROTATION;
        penInfo.rotation = static_cast<INT32>(rotation);
    } else {
        penInfo.rotation = 0;
    }

    // We require rotation and tilt to perform the conversion to X and Y tilt angles
    if (tilt >= 0.0 && rotation >= 0.0 && rotation <= 360.0) {
        const double M_PI = 3.14159265358979323846;
        auto rotationRads = rotation * (M_PI / 180.0);
        auto tiltRads = tilt * (M_PI / 180.0);
        auto r = std::sin(tiltRads);
        auto z = std::cos(tiltRads);

        // Convert polar coordinates into X and Y tilt angles
        penInfo.penMask |= PEN_MASK_TILT_X | PEN_MASK_TILT_Y;
        penInfo.tiltX = static_cast<INT32>(std::atan2(std::sin(-rotationRads) * r, z) * 180.0 / M_PI);
        penInfo.tiltY = static_cast<INT32>(std::atan2(std::cos(-rotationRads) * r, z) * 180.0 / M_PI);
    } else {
        penInfo.tiltX = 0;
        penInfo.tiltY = 0;
    }

    send_pen_input();

    // Clear edge-triggered flags after sending, leaving IN_RANGE/IN_CONTACT
    // for the monitor thread to refresh while the pen remains active.
    clearPenEdgeTriggeredFlags();
    recordPenInputAfterSend();
    lock.unlock();
    CursorMonitor::syncNow();
}

void performPenMove(int screenId, double x, double y, bool hasButton, double pressure, double rotation, double tilt) {
    std::unique_lock<std::recursive_mutex> lock(g_event_mutex);

    if (g_penInfo.penInfo.pointerInfo.pointerFlags == POINTER_FLAG_NONE) {
        return;
    }

    g_penInfo.type = PT_PEN;
    auto& penInfo = g_penInfo.penInfo;
    penInfo.pointerInfo.pointerType = PT_PEN;
    penInfo.pointerInfo.pointerId = 0;

    LONG out_x, out_y;
    if (!adjust_touch_to_screen(screenId, x, y, out_x, out_y)) return;
    penInfo.pointerInfo.ptPixelLocation.x = out_x;
    penInfo.pointerInfo.ptPixelLocation.y = out_y;

    penInfo.pointerInfo.pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE;

    // Windows only supports a single pen button, so send all buttons as the barrel button
    if (hasButton) {
        penInfo.penFlags |= PEN_FLAG_BARREL;
    } else {
        penInfo.penFlags &= ~PEN_FLAG_BARREL;
    }

    penInfo.penMask = PEN_MASK_NONE;

    // Windows doesn't support hover distance, so only pass pressure when the pointer is in contact
    if (pressure > 0.0) {
        penInfo.penMask |= PEN_MASK_PRESSURE;
        // Convert the 0.0..1.0 double to the 0..1024 range that Windows uses
        penInfo.pressure = static_cast<UINT32>(pressure * 1024.0);
    } else {
        penInfo.pressure = 0;
    }

    if (rotation >= 0.0 && rotation <= 360.0) {
        penInfo.penMask |= PEN_MASK_ROTATION;
        penInfo.rotation = static_cast<INT32>(rotation);
    } else {
        penInfo.rotation = 0;
    }

    // We require rotation and tilt to perform the conversion to X and Y tilt angles
    if (tilt >= 0.0 && rotation >= 0.0 && rotation <= 360.0) {
        const double M_PI = 3.14159265358979323846;
        auto rotationRads = rotation * (M_PI / 180.0);
        auto tiltRads = tilt * (M_PI / 180.0);
        auto r = std::sin(tiltRads);
        auto z = std::cos(tiltRads);

        // Convert polar coordinates into X and Y tilt angles
        penInfo.penMask |= PEN_MASK_TILT_X | PEN_MASK_TILT_Y;
        penInfo.tiltX = static_cast<INT32>(std::atan2(std::sin(-rotationRads) * r, z) * 180.0 / M_PI);
        penInfo.tiltY = static_cast<INT32>(std::atan2(std::cos(-rotationRads) * r, z) * 180.0 / M_PI);
    } else {
        penInfo.tiltX = 0;
        penInfo.tiltY = 0;
    }

    send_pen_input();

    // Clear edge-triggered flags after sending, leaving IN_RANGE/IN_CONTACT
    // for the monitor thread to refresh while the pen remains active.
    clearPenEdgeTriggeredFlags();
    recordPenInputAfterSend();
    lock.unlock();
    CursorMonitor::syncNow();
}

void performPenHover(int screenId, double x, double y) {
    std::unique_lock<std::recursive_mutex> lock(g_event_mutex);

    g_penInfo.type = PT_PEN;
    auto& penInfo = g_penInfo.penInfo;
    penInfo.pointerInfo.pointerType = PT_PEN;
    penInfo.pointerInfo.pointerId = 0;

    LONG out_x, out_y;
    if (!adjust_touch_to_screen(screenId, x, y, out_x, out_y)) return;
    penInfo.pointerInfo.ptPixelLocation.x = out_x;
    penInfo.pointerInfo.ptPixelLocation.y = out_y;

    penInfo.pointerInfo.pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE;
    penInfo.penFlags &= ~(PEN_FLAG_BARREL | PEN_FLAG_ERASER);
    penInfo.penMask = PEN_MASK_NONE;
    penInfo.pressure = 0;
    penInfo.rotation = 0;
    penInfo.tiltX = 0;
    penInfo.tiltY = 0;

    send_pen_input();

    // Keep IN_RANGE after the update edge is sent so hover can be refreshed.
    clearPenEdgeTriggeredFlags();
    recordPenInputAfterSend();
    lock.unlock();
    CursorMonitor::syncNow();
}

BOOL IsRunningAsSystem() {
    BOOL bIsSystem = FALSE;
    HANDLE hToken = NULL;
    DWORD dwLengthNeeded = 0;
    PTOKEN_USER pTokenUser = NULL;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken)) {
        return FALSE;
    }

    if (!GetTokenInformation(hToken, TokenUser, NULL, 0, &dwLengthNeeded) &&
        (GetLastError() != ERROR_INSUFFICIENT_BUFFER)) {
        CloseHandle(hToken);
        return FALSE;
    }

    pTokenUser = (PTOKEN_USER)LocalAlloc(LPTR, dwLengthNeeded);
    if (!pTokenUser) {
        CloseHandle(hToken);
        return FALSE;
    }

    if (!GetTokenInformation(hToken, TokenUser, pTokenUser, dwLengthNeeded, &dwLengthNeeded)) {
        LocalFree(pTokenUser);
        CloseHandle(hToken);
        return FALSE;
    }

    PSID pSystemSid = NULL;
    SID_IDENTIFIER_AUTHORITY NtAuthority = SECURITY_NT_AUTHORITY;
    if (!AllocateAndInitializeSid(&NtAuthority, 1, SECURITY_LOCAL_SYSTEM_RID,
        0, 0, 0, 0, 0, 0, 0, &pSystemSid)) {
        LocalFree(pTokenUser);
        CloseHandle(hToken);
        return FALSE;
    }

    if (EqualSid(pTokenUser->User.Sid, pSystemSid)) {
        bIsSystem = TRUE;
    }

    FreeSid(pSystemSid);
    LocalFree(pTokenUser);
    CloseHandle(hToken);

    return bIsSystem;
}

bool RunBatchAsAdmin(
    LPCWSTR lpBatchFileName, 
    DWORD* pErrorCode = nullptr, 
    bool bWait = false
) {
    WCHAR exePath[MAX_PATH] = {0};
    if (0 == GetModuleFileNameW(nullptr, exePath, MAX_PATH)) {
        if (pErrorCode) *pErrorCode = GetLastError();
        return false;
    }

    WCHAR exeDir[MAX_PATH] = {0};
    wcscpy_s(exeDir, exePath);
    if (!PathRemoveFileSpecW(exeDir)) {
        if (pErrorCode) *pErrorCode = ERROR_PATH_NOT_FOUND;
        return false;
    }

    WCHAR batchPath[MAX_PATH] = {0};
    if (!PathCombineW(batchPath, exeDir, lpBatchFileName)) {
        if (pErrorCode) *pErrorCode = ERROR_INVALID_NAME;
        return false;
    }

    if (INVALID_FILE_ATTRIBUTES == GetFileAttributesW(batchPath)) {
        if (pErrorCode) *pErrorCode = GetLastError();
        return false;
    }

    SHELLEXECUTEINFOW sei = { sizeof(sei) };
    sei.lpVerb = L"runas";       // require admin
    sei.lpFile = batchPath;      // whole path
    sei.nShow = SW_SHOW;
    
    if (bWait) {
        sei.fMask = SEE_MASK_NOCLOSEPROCESS; 
    }

    if (!ShellExecuteExW(&sei)) {
        const DWORD err = GetLastError();
        if (pErrorCode) *pErrorCode = err;
        return false;
    }

    // if needed, wait for result.
    if (bWait && sei.hProcess) {
        WaitForSingleObject(sei.hProcess, INFINITE);
        CloseHandle(sei.hProcess);
    }

    return true;
}

bool RunExeAsAdmin(
    LPCWSTR lpExeFileName,
    LPCWSTR lpArguments,
    DWORD* pErrorCode = nullptr,
    bool bWait = false
) {
    WCHAR exePath[MAX_PATH] = {0};
    if (0 == GetModuleFileNameW(nullptr, exePath, MAX_PATH)) {
        if (pErrorCode) *pErrorCode = GetLastError();
        return false;
    }

    WCHAR exeDir[MAX_PATH] = {0};
    wcscpy_s(exeDir, exePath);
    if (!PathRemoveFileSpecW(exeDir)) {
        if (pErrorCode) *pErrorCode = ERROR_PATH_NOT_FOUND;
        return false;
    }

    WCHAR targetPath[MAX_PATH] = {0};
    if (!PathCombineW(targetPath, exeDir, lpExeFileName)) {
        if (pErrorCode) *pErrorCode = ERROR_INVALID_NAME;
        return false;
    }

    if (INVALID_FILE_ATTRIBUTES == GetFileAttributesW(targetPath)) {
        if (pErrorCode) *pErrorCode = GetLastError();
        return false;
    }

    SHELLEXECUTEINFOW sei = { sizeof(sei) };
    sei.lpVerb = L"runas";
    sei.lpFile = targetPath;
    sei.lpParameters = lpArguments;
    sei.nShow = SW_HIDE;

    if (bWait) {
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    }

    if (!ShellExecuteExW(&sei)) {
        const DWORD err = GetLastError();
        if (pErrorCode) *pErrorCode = err;
        return false;
    }

    if (bWait && sei.hProcess) {
        WaitForSingleObject(sei.hProcess, INFINITE);
        CloseHandle(sei.hProcess);
    }

    return true;
}

// https://sunlogin.oray.com/news/16158.html
void setDragWindowContents(bool enable) {
  HKEY hKey;
  if (RegOpenKeyEx(HKEY_CURRENT_USER, TEXT("Control Panel\\Desktop"), 0,
                   KEY_SET_VALUE, &hKey) == ERROR_SUCCESS) {
    DWORD value = enable ? 1 : 0;
    RegSetValueEx(hKey, TEXT("DragFullWindows"), 0, REG_DWORD,
                  (const BYTE *)&value, sizeof(value));
    RegCloseKey(hKey);
    SystemParametersInfo(SPI_SETDRAGFULLWINDOWS, value, nullptr,
                         SPIF_UPDATEINIFILE | SPIF_SENDCHANGE);

  } else {
    std::cerr << "Failed to open registry key." << std::endl;
  }
}

// static
void HardwareSimulatorPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "hardware_simulator",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<HardwareSimulatorPlugin>();
  auto plugin_pointer = plugin.get();

  plugin->channel_ = std::move(channel);
  plugin->registrar_ = registrar;  // Save registrar reference
  if (auto *view = registrar->GetView()) {
    plugin->flutter_view_window_ = view->GetNativeWindow();
    if (plugin->flutter_view_window_ != nullptr) {
      SetWindowSubclass(
          plugin->flutter_view_window_,
          CursorReseedSubclassProc,
          kCursorReseedSubclassId,
          0);
    }
  }
  CursorMonitor::initializeSourceDevicePixelRatio(
      plugin->flutter_view_window_);

  plugin->channel_->SetMethodCallHandler(
      [plugin_pointer](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  // Start the monitor thread if auto-repeat is enabled
  if (g_auto_repeat_enabled) {
      plugin_pointer->StartMonitorThread();
  }

  registrar->AddPlugin(std::move(plugin));

  // start to monitor display resolution and DPI.
  HardwareSimulatorPlugin::UpdateStaticMonitors();
  dpi_monitor_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) -> std::optional<LRESULT> {
          if (message == WM_DPICHANGED || message == WM_DISPLAYCHANGE) {
              HardwareSimulatorPlugin::UpdateStaticMonitors();
          }
          return std::nullopt;
      });
}

HardwareSimulatorPlugin::HardwareSimulatorPlugin() {
    // Initialize cursor lock members
    cursor_locked_ = false;
    raw_input_registered_ = false;
    main_window_ = nullptr;
    registrar_ = nullptr;
    memset(&clip_rect_, 0, sizeof(clip_rect_));
    memset(&locked_cursor_pos_, 0, sizeof(locked_cursor_pos_));
}

HardwareSimulatorPlugin::~HardwareSimulatorPlugin() {
    StopWindowsEditingEventMonitor();
    if (flutter_view_window_ != nullptr) {
        RemoveWindowSubclass(
            flutter_view_window_,
            CursorReseedSubclassProc,
            kCursorReseedSubclassId);
        flutter_view_window_ = nullptr;
    }
    DesktopServiceInputClient::Instance().Close();
    StopMonitorThread();
    destroyTouchDevice();
    destroyPenDevice();
    CleanupCursorLock();
    if (dpi_monitor_proc_id_.has_value()) {
        registrar_->UnregisterTopLevelWindowProcDelegate(dpi_monitor_proc_id_.value());
        dpi_monitor_proc_id_.reset();
    }
}

bool HardwareSimulatorPlugin::StartWindowsEditingEventMonitor() {
  if (windows_editing_event_monitor_ &&
      windows_editing_event_monitor_->is_running()) {
    return true;
  }
  if (windows_editing_event_monitor_ || windows_editing_proc_id_.has_value()) {
    StopWindowsEditingEventMonitor();
  }
  if (registrar_ == nullptr) {
    return false;
  }

  windows_editing_window_ = FindFlutterWindow();
  windows_editing_message_id_ =
      RegisterWindowMessageW(kWindowsTextInputDecisionMessageName);
  if (windows_editing_window_ == nullptr || windows_editing_message_id_ == 0) {
    StopWindowsEditingEventMonitor();
    return false;
  }

  windows_editing_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND, UINT message, WPARAM wparam,
             LPARAM) -> std::optional<LRESULT> {
        if (message != windows_editing_message_id_ ||
            wparam != reinterpret_cast<WPARAM>(this)) {
          return std::nullopt;
        }

        std::unique_ptr<WindowsTextInputDecision> decision;
        {
          std::lock_guard<std::mutex> lock(windows_editing_event_mutex_);
          decision = std::move(pending_windows_text_input_decision_);
          windows_editing_message_posted_ = false;
        }
        if (decision) {
          SendWindowsTextInputDecision(*decision);
        }
        return 0;
      });

  windows_editing_event_monitor_ =
      std::make_unique<WindowsEditingEventMonitor>(
          [this](const WindowsTextInputDecision& decision) {
            QueueWindowsTextInputDecision(decision);
          });
  if (!windows_editing_event_monitor_->Start()) {
    StopWindowsEditingEventMonitor();
    return false;
  }
  return true;
}

void HardwareSimulatorPlugin::StopWindowsEditingEventMonitor() {
  windows_editing_event_monitor_.reset();

  {
    std::lock_guard<std::mutex> lock(windows_editing_event_mutex_);
    pending_windows_text_input_decision_.reset();
    windows_editing_message_posted_ = false;
  }
  if (windows_editing_window_ != nullptr &&
      windows_editing_message_id_ != 0) {
    MSG message = {};
    while (PeekMessageW(&message, windows_editing_window_,
                        windows_editing_message_id_,
                        windows_editing_message_id_, PM_REMOVE)) {
    }
  }
  if (registrar_ != nullptr && windows_editing_proc_id_.has_value()) {
    registrar_->UnregisterTopLevelWindowProcDelegate(
        windows_editing_proc_id_.value());
  }
  windows_editing_proc_id_.reset();
  windows_editing_window_ = nullptr;
  windows_editing_message_id_ = 0;
}

void HardwareSimulatorPlugin::QueueWindowsTextInputDecision(
    const WindowsTextInputDecision& decision) {
  std::lock_guard<std::mutex> lock(windows_editing_event_mutex_);
  pending_windows_text_input_decision_ =
      std::make_unique<WindowsTextInputDecision>(decision);
  if (windows_editing_message_posted_) {
    return;
  }
  windows_editing_message_posted_ = true;
  if (!PostMessageW(windows_editing_window_, windows_editing_message_id_,
                    reinterpret_cast<WPARAM>(this), 0)) {
    pending_windows_text_input_decision_.reset();
    windows_editing_message_posted_ = false;
  }
}

void HardwareSimulatorPlugin::SendWindowsTextInputDecision(
    const WindowsTextInputDecision& decision) {
  if (!channel_) {
    return;
  }
  flutter::EncodableMap message;
  message[flutter::EncodableValue("active")] =
      flutter::EncodableValue(decision.active);
  message[flutter::EncodableValue("secure")] =
      decision.secure.has_value()
          ? flutter::EncodableValue(decision.secure.value())
          : flutter::EncodableValue();
  message[flutter::EncodableValue("editFocusRequestId")] =
      decision.edit_focus_request_id.has_value()
          ? flutter::EncodableValue(decision.edit_focus_request_id.value())
          : flutter::EncodableValue();
  channel_->InvokeMethod(
      "onTextInputDecision",
      std::make_unique<flutter::EncodableValue>(message));
}

void async_send_input_retry(INPUT& i) {
    while (true) {
        auto send = SendInput(1, &i, sizeof(INPUT));
        if (send == 1) {
            break;
        }

        auto hDesk = syncThreadDesktop();
        if (_lastKnownInputDesktop != hDesk) {
            _lastKnownInputDesktop = hDesk;
        }
        else {
            break;
        }
    }
}

void send_input(INPUT& i) {
    if (DesktopServiceInputClient::Instance().SendInputMessage(i)) {
        return;
    }

    auto send = SendInput(1, &i, sizeof(INPUT));
    if (send != 1) {
        // put resend into new thread.
        std::future<void> retry_future = std::async(std::launch::async, async_send_input_retry, std::ref(i));
        retry_future.wait();
    }
}

void performMouseButton(int button, bool release) {
    //SHORT KEY_STATE_DOWN = 0x8000;

    INPUT i{};

    i.type = INPUT_MOUSE;
    auto& mi = i.mi;

    int mouse_button;
    if (button == 1) {
        mi.dwFlags = release ? MOUSEEVENTF_LEFTUP : MOUSEEVENTF_LEFTDOWN;
        mouse_button = VK_LBUTTON;
    }
    else if (button == 2) {
        mi.dwFlags = release ? MOUSEEVENTF_MIDDLEUP : MOUSEEVENTF_MIDDLEDOWN;
        mouse_button = VK_MBUTTON;
    }
    else if (button == 3) {
        mi.dwFlags = release ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_RIGHTDOWN;
        mouse_button = VK_RBUTTON;
    }
    else if (button == 4) {
        mi.dwFlags = release ? MOUSEEVENTF_XUP : MOUSEEVENTF_XDOWN;
        mi.mouseData = XBUTTON1;
        mouse_button = VK_XBUTTON1;
    }
    else {
        mi.dwFlags = release ? MOUSEEVENTF_XUP : MOUSEEVENTF_XDOWN;
        mi.mouseData = XBUTTON2;
        mouse_button = VK_XBUTTON2;
    }
    
    //Haichao: what is it used for? It blocks button up for UAC window.
    /*auto key_state = GetAsyncKeyState(mouse_button);
    bool key_state_down = (key_state & 0x8000) != 0;
    if (key_state_down != release) {
        return;
    }*/

    send_input(i);
}

#pragma warning(disable:4244)

void performKeyEvent(uint16_t modcode, bool isDown, bool isRepeat = false) {
    INPUT i{};
    i.type = INPUT_KEYBOARD;
    auto& ki = i.ki;

    // For some reason, MapVirtualKey(VK_LWIN, MAPVK_VK_TO_VSC) doesn't seem to work :/
    if (modcode != VK_LWIN && modcode != VK_RWIN && modcode != VK_PAUSE) {
        ki.wScan = MapVirtualKey(modcode, MAPVK_VK_TO_VSC);
        ki.dwFlags = KEYEVENTF_SCANCODE;
    }
    else {
        ki.wVk = modcode;
    }

    // https://docs.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input#keystroke-message-flags
    switch (modcode) {
    case VK_RMENU:
    case VK_RCONTROL:
    case VK_INSERT:
    case VK_DELETE:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_UP:
    case VK_DOWN:
    case VK_LEFT:
    case VK_RIGHT:
    case VK_DIVIDE:
        ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
        break;
    default:
        break;
    }

    if (!isDown) {
        ki.dwFlags |= KEYEVENTF_KEYUP;
    }

    send_input(i);

    // Add state tracking
    if (g_auto_repeat_enabled && !isRepeat) {
        std::lock_guard<std::recursive_mutex> lock(g_event_mutex);
        if (isDown) {
            g_key_states[modcode] = {true, std::chrono::steady_clock::now()};
            g_last_known_key_down = modcode;
        } else if (g_key_states.find(modcode) != g_key_states.end()) {
            g_key_states.erase(modcode);
        }
    }
}

void clearAllPressedEvents() {
    std::unique_lock<std::recursive_mutex> lock(g_event_mutex);
    bool shouldSyncCursor = false;
    
    // Clear all pressed keyboard keys
    for (auto& [keyCode, state] : g_key_states) {
        if (state.isDown) {
            performKeyEvent(keyCode, false); // Send key up event
        }
    }
    g_key_states.clear();
    g_last_known_key_down = 0;
    
    // Clear all pressed touch points
    for (auto& [touchId, state] : g_touch_states) {
        if (state.isDown) {
            performTouchEvent(state.screenId, state.x, state.y, touchId, false); // Send touch up event
        }
    }
    g_touch_states.clear();
    
    // Clear pen device if it has an active hover or contact state.
    if (hasActivePenPointer()) {
        clearActivePenPointer();
        shouldSyncCursor = true;
    }
    
    // Clear mouse buttons (left and right)
    // Check if mouse buttons are currently pressed using GetAsyncKeyState
    if (GetAsyncKeyState(VK_LBUTTON) & 0x8000) {
        performMouseButton(1, true); // Left button up
    }
    if (GetAsyncKeyState(VK_RBUTTON) & 0x8000) {
        performMouseButton(3, true); // Right button up
    }
    if (GetAsyncKeyState(VK_MBUTTON) & 0x8000) {
        performMouseButton(2, true); // Middle button up
    }
    if (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) {
        performMouseButton(4, true); // XButton1 up
    }
    if (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) {
        performMouseButton(5, true); // XButton2 up
    }

    lock.unlock();
    if (shouldSyncCursor) {
        CursorMonitor::syncNow();
    }
}

bool setPrimaryDisplay(int displayIndex) {
    // Use ChangeDisplaySettingsEx method
    DEVMODE devMode = {};
    devMode.dmSize = sizeof(DEVMODE);
    
    // Get display device information
    DISPLAY_DEVICE displayDevice = {};
    displayDevice.cb = sizeof(DISPLAY_DEVICE);
    
    if (!EnumDisplayDevices(nullptr, displayIndex, &displayDevice, 0)) {
        return false;
    }
    
    // Get current display mode
    if (!EnumDisplaySettings(displayDevice.DeviceName, ENUM_CURRENT_SETTINGS, &devMode)) {
        return false;
    }
    
    // Set as primary display
    devMode.dmFields = DM_POSITION;
    devMode.dmPosition.x = 0;
    devMode.dmPosition.y = 0;
    
    // Apply settings
    LONG result = ChangeDisplaySettingsEx(displayDevice.DeviceName, 
                                        &devMode, 
                                        nullptr, 
                                        CDS_SET_PRIMARY | CDS_UPDATEREGISTRY, 
                                        nullptr);
    
    return (result == DISP_CHANGE_SUCCESSFUL);
}

void performMouseMoveRelative(double x,double y){
    INPUT i {};

    i.type = INPUT_MOUSE;
    auto &mi = i.mi;

    mi.dwFlags = MOUSEEVENTF_MOVE;
    mi.dx = x;
    mi.dy = y;

    send_input(i);
}

void performMouseMoveAbsl(double x,double y,int screenId){
    INPUT i {};

    i.type = INPUT_MOUSE;
    auto &mi = i.mi;

    LONG newx = 0, newy = 0;


    mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                 MOUSEEVENTF_VIRTUALDESK;
    if (!adjust_to_virtual_desktop(screenId, x,y, newx, newy)) return;
    mi.dx = newx;
    mi.dy = newy;

    send_input(i);
}

void performMouseMoveToWindowPosition(
    double percentx,
    double percenty,
    HWND target_window = nullptr,
    ULONG_PTR extra_info = 0) {
    //if (!SmartKeyboardBlocker::IsTargetWindowActive()) return;

    INPUT i{};

    i.type = INPUT_MOUSE;
    auto& mi = i.mi;

    // Get the current window handle (Flutter window)
    HWND hwnd = target_window != nullptr
        ? target_window
        : SmartKeyboardBlocker::target_window_;  // GetForegroundWindow();
    if (!hwnd) return;

    // Get client area rectangle (excluding title bar and borders)
    RECT clientRect;
    if (!GetClientRect(hwnd, &clientRect)) return;

    // Calculate the actual client area position on screen
    POINT clientTopLeft = {0, 0};
    if (!ClientToScreen(hwnd, &clientTopLeft)) return;

    // Calculate target position based on percentages
    const double clamped_x = (std::clamp)(percentx, 0.0, 1.0);
    const double clamped_y = (std::clamp)(percenty, 0.0, 1.0);
    const int client_width =
        (std::max)(1L, clientRect.right - clientRect.left);
    const int client_height =
        (std::max)(1L, clientRect.bottom - clientRect.top);
    const int targetX = clientTopLeft.x +
        static_cast<int>(std::lround(clamped_x * (client_width - 1)));
    const int targetY = clientTopLeft.y +
        static_cast<int>(std::lround(clamped_y * (client_height - 1)));

    // Convert to absolute virtual-desktop coordinates (0-65535 range).
    const int virtual_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int virtual_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int virtual_width =
        (std::max)(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
    const int virtual_height =
        (std::max)(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));

    mi.dwFlags =
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
        MOUSEEVENTF_VIRTUALDESK;
    mi.dx =
        MulDiv(targetX - virtual_x, 65535, (std::max)(1, virtual_width - 1));
    mi.dy =
        MulDiv(targetY - virtual_y, 65535, (std::max)(1, virtual_height - 1));
    mi.dwExtraInfo = extra_info;

    if (extra_info == kCursorReseedExtraInfo) {
        // This is a viewer-local cursor re-seed. Do not route it through the
        // privileged desktop-service input path; the tag must reach this
        // Flutter window's message queue so its delegate can consume it.
        SendInput(1, &i, sizeof(INPUT));
    } else {
        send_input(i);
    }
}

void scroll(int distance) {
    INPUT i{};

    i.type = INPUT_MOUSE;
    auto& mi = i.mi;

    mi.dwFlags = MOUSEEVENTF_WHEEL;
    mi.mouseData = distance;

    send_input(i);
}

void hscroll(int distance) {
    INPUT i{};

    i.type = INPUT_MOUSE;
    auto& mi = i.mi;

    mi.dwFlags = MOUSEEVENTF_HWHEEL;
    mi.mouseData = distance;

    send_input(i);
}

void performMouseScroll(double dx, double dy) {
    // RD_MOUSE_SCROLL uses logical page direction: +x right, +y down.
    // Win32 horizontal wheel uses the same sign, while vertical wheel uses
    // the physical wheel direction (+ is forward/page-up), so y is inverted.
    const int horizontal_distance = logicalScrollToWindowsWheel(dx, false);
    const int vertical_distance = logicalScrollToWindowsWheel(dy, true);

    if (horizontal_distance != 0) {
        hscroll(horizontal_distance);
    }
    if (vertical_distance != 0) {
        scroll(vertical_distance);
    }
}

void performTrackpadScroll(double dx, double dy) {
    // Windows 10 has no public precision-touchpad injection API. Replay each
    // native trackpad frame as an ordinary high-resolution wheel event. The
    // legacy API is integral, so each axis carries its fractional wheel-unit
    // remainder forward. Cross-platform magnitude scaling belongs to Dart.
    thread_local TrackpadScrollAccumulator horizontal_accumulator(
        kMaxWindowsWheelDistance);
    thread_local TrackpadScrollAccumulator vertical_accumulator(
        kMaxWindowsWheelDistance);
    const int horizontal_distance =
        horizontal_accumulator.Convert(dx, false);
    const int vertical_distance =
        vertical_accumulator.Convert(dy, true);

    if (horizontal_distance != 0) {
        hscroll(horizontal_distance);
    }
    if (vertical_distance != 0) {
        scroll(vertical_distance);
    }
}

std::wstring stringToWstring(const std::string& str) {
    int wideCharLen = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, nullptr, 0);
    if (wideCharLen <= 0) return L"";

    std::wstring wstr(wideCharLen - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &wstr[0], wideCharLen);
    return wstr;
}

void HardwareSimulatorPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
  if (method_call.method_name().compare("getPlatformVersion") == 0) {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
  } else if (method_call.method_name().compare(
                 "startTextInputDecisionCapture") == 0 ||
             method_call.method_name().compare(
                 "startWindowsTextInputDecisionCapture") == 0) {
    result->Success(
        flutter::EncodableValue(StartWindowsEditingEventMonitor()));
  } else if (method_call.method_name().compare(
                 "stopTextInputDecisionCapture") == 0 ||
             method_call.method_name().compare(
                 "stopWindowsTextInputDecisionCapture") == 0) {
    StopWindowsEditingEventMonitor();
    result->Success(nullptr);
  } else if (method_call.method_name().compare("setDesktopServiceAvailable") == 0) {
    bool available = false;
    if (args) {
      auto available_iter = args->find(flutter::EncodableValue("available"));
      if (available_iter != args->end() &&
          std::holds_alternative<bool>(available_iter->second)) {
        available = std::get<bool>(available_iter->second);
      }
    }
    DesktopServiceInputClient::Instance().SetServiceAvailable(available);
    result->Success(nullptr);
  } else if (method_call.method_name().compare("getMonitorCount") == 0) {
    int monitorCount = GetSystemMetrics(SM_CMONITORS);
    //update_monitors();
    result->Success(flutter::EncodableValue(monitorCount));
  } else if (method_call.method_name().compare("KeyPress") == 0) {
        auto keyCode = (args->find(flutter::EncodableValue("code")))->second;
        auto isDown = (args->find(flutter::EncodableValue("isDown")))->second;
        performKeyEvent(static_cast<int>(std::get<int>((keyCode))), static_cast<bool>(std::get<bool>((isDown))));
        result->Success(nullptr);
  } else if (method_call.method_name().compare("performTextInput") == 0) {
        if (!args) {
          result->Error("INVALID_TEXT", "Missing text input arguments");
          return;
        }
        const auto text_iter = args->find(flutter::EncodableValue("text"));
        if (text_iter == args->end() ||
            !std::holds_alternative<std::string>(text_iter->second)) {
          result->Error("INVALID_TEXT", "Text input must be a string");
          return;
        }
        std::vector<INPUT> inputs;
        if (!BuildWindowsUnicodeTextInputs(
                std::get<std::string>(text_iter->second), &inputs)) {
          result->Error("INVALID_TEXT", "Text input is invalid or too long");
          return;
        }
        for (auto& input : inputs) {
          send_input(input);
        }
        result->Success(nullptr);
  } else if (method_call.method_name().compare("mouseMoveR") == 0) {
        auto deltax = (args->find(flutter::EncodableValue("x")))->second;
        auto deltay = (args->find(flutter::EncodableValue("y")))->second;
        performMouseMoveRelative(static_cast<double>(std::get<double>((deltax))), static_cast<double>(std::get<double>((deltay))));
        result->Success(nullptr);
  } else if (method_call.method_name().compare("mouseMoveA") == 0) {
        auto percentx = (args->find(flutter::EncodableValue("x")))->second;
        auto percenty = (args->find(flutter::EncodableValue("y")))->second;
        auto screenId = (args->find(flutter::EncodableValue("screenId")))->second;
        performMouseMoveAbsl(static_cast<double>(std::get<double>((percentx))), static_cast<double>(std::get<double>((percenty))), static_cast<int>(std::get<int>((screenId))));
        result->Success(nullptr);
  } else if (method_call.method_name().compare("mouseMoveToWindowPosition") == 0) {
        auto percentx = (args->find(flutter::EncodableValue("x")))->second;
        auto percenty = (args->find(flutter::EncodableValue("y")))->second;
        performMouseMoveToWindowPosition(static_cast<double>(std::get<double>((percentx))), static_cast<double>(std::get<double>((percenty))));
        result->Success(nullptr);
  } else if (method_call.method_name().compare("mousePress") == 0) {
        auto buttonid = (args->find(flutter::EncodableValue("buttonId")))->second;
        auto isDown = (args->find(flutter::EncodableValue("isDown")))->second;
        const int button = static_cast<int>(std::get<int>(buttonid));
        const bool is_down = static_cast<bool>(std::get<bool>(isDown));
        const auto edit_focus_request_id =
            ReadOptionalInt64(args, "editFocusRequestId");
        performMouseButton(button, !is_down);
        if (button == 1 && !is_down && windows_editing_event_monitor_) {
          windows_editing_event_monitor_->InspectAfterRemotePointerUp(
              edit_focus_request_id);
        }
        result->Success(nullptr);
  } else if (method_call.method_name().compare("mouseScroll") == 0) {
        auto dx = (args->find(flutter::EncodableValue("dx")))->second;
        auto dy = (args->find(flutter::EncodableValue("dy")))->second;
        performMouseScroll(
            std::get<double>(dx),
            std::get<double>(dy));
        result->Success(nullptr);
  } else if (method_call.method_name().compare("trackpadScroll") == 0) {
        auto dx = (args->find(flutter::EncodableValue("dx")))->second;
        auto dy = (args->find(flutter::EncodableValue("dy")))->second;
        performTrackpadScroll(
            std::get<double>(dx),
            std::get<double>(dy));
        result->Success(nullptr);
  } else if (method_call.method_name().compare("hookCursorImage") == 0) {
        auto callbackID = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("callbackID")))->second));
        auto hookAll = static_cast<bool>(std::get<bool>((args->find(flutter::EncodableValue("hookAll")))->second));
        CursorMonitor::startHook([this, callbackID](int message, int msg_info, const std::vector<uint8_t>& cursorImage) {
            flutter::EncodableMap encoded_message;
            encoded_message[flutter::EncodableValue("callbackID")] = flutter::EncodableValue(callbackID);
            encoded_message[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
            encoded_message[flutter::EncodableValue("msg_info")] = flutter::EncodableValue(msg_info);
            encoded_message[flutter::EncodableValue("cursorImage")] = flutter::EncodableValue(std::vector<uint8_t>(cursorImage.begin(), cursorImage.end()));
            if (channel_) {
                channel_->InvokeMethod("onCursorImageMessage", 
                    std::make_unique<flutter::EncodableValue>(encoded_message));
            }
        }, callbackID, hookAll);
        result->Success(nullptr);
  } else if (method_call.method_name().compare("unhookCursorImage") == 0) {
        auto callbackID = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("callbackID")))->second));
        CursorMonitor::endHook(callbackID);
        result->Success(nullptr);
  } else if (method_call.method_name().compare("hookCursorPosition") == 0) {
        auto callbackID = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("callbackID")))->second));
        CursorMonitor::startPositionHook([this, callbackID](int message, int screenId, double xPercent, double yPercent) {
            flutter::EncodableMap encoded_message;
            encoded_message[flutter::EncodableValue("callbackID")] = flutter::EncodableValue(callbackID);
            encoded_message[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
            encoded_message[flutter::EncodableValue("screenId")] = flutter::EncodableValue(screenId);
            encoded_message[flutter::EncodableValue("xPercent")] = flutter::EncodableValue(xPercent);
            encoded_message[flutter::EncodableValue("yPercent")] = flutter::EncodableValue(yPercent);
            if (channel_) {
                channel_->InvokeMethod("onCursorPositionMessage", 
                    std::make_unique<flutter::EncodableValue>(encoded_message));
            }
        }, callbackID);
        result->Success(nullptr);
  } else if (method_call.method_name().compare("unhookCursorPosition") == 0) {
        auto callbackID = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("callbackID")))->second));
        CursorMonitor::endPositionHook(callbackID);
        result->Success(nullptr);
  } else if (method_call.method_name().compare("addDisplayCountChangedCallback") == 0) {
        auto callbackID = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("callbackID")))->second));
        addDisplayCountChangedCallback([this, callbackID](int displayCount) {
            flutter::EncodableMap encoded_message;
            encoded_message[flutter::EncodableValue("callbackID")] = flutter::EncodableValue(callbackID);
            encoded_message[flutter::EncodableValue("displayCount")] = flutter::EncodableValue(displayCount);
            if (channel_) {
                channel_->InvokeMethod("onDisplayCountChanged", 
                    std::make_unique<flutter::EncodableValue>(encoded_message));
            }
        }, callbackID);
        result->Success(nullptr);
  } else if (method_call.method_name().compare("removeDisplayCountChangedCallback") == 0) {
        auto callbackID = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("callbackID")))->second));
        removeDisplayCountChangedCallback(callbackID);
        result->Success(nullptr);
  } else if (method_call.method_name().compare("createGameController") == 0) {
        int hr = GameControllerManager::CreateGameController();
        result->Success(flutter::EncodableValue(hr));
  } else if (method_call.method_name().compare("removeGameController") == 0) {
        auto id = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("id")))->second));
        int hr = GameControllerManager::RemoveGameController(id);
        result->Success(flutter::EncodableValue(hr));
  } else if (method_call.method_name().compare("doControlAction") == 0) {
    if (args) {
        auto id_iter = args->find(flutter::EncodableValue("id"));
        auto action_iter = args->find(flutter::EncodableValue("action"));
        
        if (id_iter != args->end() && action_iter != args->end() &&
            std::holds_alternative<int>(id_iter->second) &&
            std::holds_alternative<std::string>(action_iter->second)) {
            
            int id = std::get<int>(id_iter->second);
            std::string action = std::get<std::string>(action_iter->second);

            GameControllerManager::DoControllerAction(id, action);
            result->Success(flutter::EncodableValue());
        } else {
            result->Error("InvalidArguments", "Missing or invalid arguments for doControlAction");
        }
    } else {
        result->Error("NullArguments", "Arguments are null for doControlAction");
    }
  } else if (method_call.method_name().compare("registerService") == 0) {
        DWORD dword;
        bool allowed_to_run = RunExeAsAdmin(L"cloudplayplus_desktop_svc.exe", L"--install", &dword, true);
        result->Success(flutter::EncodableValue(allowed_to_run));
  } else if (method_call.method_name().compare("unregisterService") == 0) {
        DWORD dword;
        RunExeAsAdmin(L"cloudplayplus_desktop_svc.exe", L"--uninstall", &dword, true);
        result->Success(flutter::EncodableValue());
  } else if (method_call.method_name().compare("isRunningAsSystem") == 0) {
        if (IsRunningAsSystem()) {
            result->Success(flutter::EncodableValue(true));
        }
        else {
            result->Success(flutter::EncodableValue(false));
        }
  } else if (method_call.method_name().compare("showNotification") == 0) {
        auto content = static_cast<std::string>(std::get<std::string>((args->find(flutter::EncodableValue("content")))->second));
        NotificationWindow::Show(stringToWstring(content));
  } else if (method_call.method_name().compare("touchEvent") == 0) {
        auto screenId = (args->find(flutter::EncodableValue("screenId")))->second;
        auto x = (args->find(flutter::EncodableValue("x")))->second;
        auto y = (args->find(flutter::EncodableValue("y")))->second;
        auto touchId = (args->find(flutter::EncodableValue("touchId")))->second;
        auto isDown = (args->find(flutter::EncodableValue("isDown")))->second;
        const int screen_id = static_cast<int>(std::get<int>((screenId)));
        const double x_value = static_cast<double>(std::get<double>((x)));
        const double y_value = static_cast<double>(std::get<double>((y)));
        const bool is_down = static_cast<bool>(std::get<bool>((isDown)));
        performTouchEvent(
            screen_id,
            x_value,
            y_value,
            static_cast<uint32_t>(std::get<int>((touchId))),
            is_down
        );
        const auto inspection_point =
            PointerPointForScreen(screen_id, x_value, y_value);
        if (!is_down && windows_editing_event_monitor_ &&
            inspection_point.has_value()) {
          windows_editing_event_monitor_->InspectAfterRemotePointerUp(
              ReadOptionalInt64(args, "editFocusRequestId"),
              inspection_point);
        }
        result->Success(nullptr);
  } else if (method_call.method_name().compare("touchMove") == 0) {
        auto screenId = (args->find(flutter::EncodableValue("screenId")))->second;
        auto x = (args->find(flutter::EncodableValue("x")))->second;
        auto y = (args->find(flutter::EncodableValue("y")))->second;
        auto touchId = (args->find(flutter::EncodableValue("touchId")))->second;
        performTouchMove(
            static_cast<int>(std::get<int>((screenId))),
            static_cast<double>(std::get<double>((x))),
            static_cast<double>(std::get<double>((y))),
            static_cast<uint32_t>(std::get<int>((touchId)))
        );
        result->Success(nullptr);
  } else if (method_call.method_name().compare("penEvent") == 0) {
        auto screenId = (args->find(flutter::EncodableValue("screenId")))->second;
        auto x = (args->find(flutter::EncodableValue("x")))->second;
        auto y = (args->find(flutter::EncodableValue("y")))->second;
        auto isDown = (args->find(flutter::EncodableValue("isDown")))->second;
        auto hasButton = (args->find(flutter::EncodableValue("hasButton")))->second;
        auto pressure = (args->find(flutter::EncodableValue("pressure")))->second;
        auto rotation = (args->find(flutter::EncodableValue("rotation")))->second;
        auto tilt = (args->find(flutter::EncodableValue("tilt")))->second;
        const int screen_id = static_cast<int>(std::get<int>((screenId)));
        const double x_value = static_cast<double>(std::get<double>((x)));
        const double y_value = static_cast<double>(std::get<double>((y)));
        const bool is_down = static_cast<bool>(std::get<bool>((isDown)));
        performPenEvent(
            screen_id,
            x_value,
            y_value,
            is_down,
            static_cast<bool>(std::get<bool>((hasButton))),
            static_cast<double>(std::get<double>((pressure))),
            static_cast<double>(std::get<double>((rotation))),
            static_cast<double>(std::get<double>((tilt)))
        );
        const auto inspection_point =
            PointerPointForScreen(screen_id, x_value, y_value);
        if (!is_down && windows_editing_event_monitor_ &&
            inspection_point.has_value()) {
          windows_editing_event_monitor_->InspectAfterRemotePointerUp(
              ReadOptionalInt64(args, "editFocusRequestId"),
              inspection_point);
        }
        result->Success(nullptr);
  } else if (method_call.method_name().compare("penMove") == 0) {
        auto screenId = (args->find(flutter::EncodableValue("screenId")))->second;
        auto x = (args->find(flutter::EncodableValue("x")))->second;
        auto y = (args->find(flutter::EncodableValue("y")))->second;
        auto hasButton = (args->find(flutter::EncodableValue("hasButton")))->second;
        auto pressure = (args->find(flutter::EncodableValue("pressure")))->second;
        auto rotation = (args->find(flutter::EncodableValue("rotation")))->second;
        auto tilt = (args->find(flutter::EncodableValue("tilt")))->second;
        performPenMove(
            static_cast<int>(std::get<int>((screenId))),
            static_cast<double>(std::get<double>((x))),
            static_cast<double>(std::get<double>((y))),
            static_cast<bool>(std::get<bool>((hasButton))),
            static_cast<double>(std::get<double>((pressure))),
            static_cast<double>(std::get<double>((rotation))),
            static_cast<double>(std::get<double>((tilt)))
        );
        result->Success(nullptr);
  } else if (method_call.method_name().compare("penHover") == 0) {
        auto screenId = (args->find(flutter::EncodableValue("screenId")))->second;
        auto x = (args->find(flutter::EncodableValue("x")))->second;
        auto y = (args->find(flutter::EncodableValue("y")))->second;
        performPenHover(
            static_cast<int>(std::get<int>((screenId))),
            static_cast<double>(std::get<double>((x))),
            static_cast<double>(std::get<double>((y)))
        );
        result->Success(nullptr);
  } else if (method_call.method_name().compare("clearAllPressedEvents") == 0) {
        clearAllPressedEvents();
        result->Success(nullptr);
  } else if (method_call.method_name().compare("setPrimaryDisplay") == 0) {
        auto displayIndex = static_cast<int>(std::get<int>((args->find(flutter::EncodableValue("displayIndex")))->second));
        bool success = setPrimaryDisplay(displayIndex);
        result->Success(flutter::EncodableValue(success));
  } else if (method_call.method_name().compare("ensureConsoleForDisplay") == 0) {
    // EnsureConsoleForDisplay may block up to ~10s on tscon
    // (WaitForSingleObject). Run it on a worker thread so the Flutter platform
    // thread (UI / input / render) is never frozen; the Dart `await` still
    // receives the real result when the work completes.
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared_result =
        std::move(result);
    std::thread([shared_result]() {
      bool ok = VirtualDisplayControl::EnsureConsoleForDisplay();
      shared_result->Success(flutter::EncodableValue(ok));
    }).detach();
    return;
  } else if (method_call.method_name().compare("initParsecVdd") == 0) {
    // Runs synchronously on the platform thread: Initialize() mutates the
    // shared VDD state (initialized_/vdd_handle_/displays_), which has no lock
    // and relies on method calls being serialized on the platform thread.
    // Moving it to a worker thread would race concurrent displays_ access.
    if (!VirtualDisplayControl::IsInitialized()) {
      if (VirtualDisplayControl::Initialize()) {
        result->Success(flutter::EncodableValue(true));
      } else {
        result->Error("INIT_FAILED", "Failed to initialize ParsecVdd");
      }
    } else {
      result->Success(flutter::EncodableValue(true));
    }
  } else if (method_call.method_name().compare("createDisplay") == 0) {
     // Runs synchronously on the platform thread: AddDisplay() rebuilds the
     // shared displays_ vector (unlocked); serialization on the platform thread
     // is what keeps it race-free. Do NOT move to a worker thread.
     if (VirtualDisplayControl::IsInitialized()) {
         int displayId = VirtualDisplayControl::AddDisplay();
         if (displayId >= 0) {
             result->Success(flutter::EncodableValue(displayId));
         } else {
             result->Error("CREATE_FAILED", "Failed to create display");
         }
     } else {
         result->Error("NOT_INITIALIZED", "Parsec not initialized");
     }
  } else if (method_call.method_name().compare("removeDisplay") == 0) {
     auto displayId_iter = args->find(flutter::EncodableValue("displayUid"));
     if (displayId_iter == args->end()) {
         result->Error("MISSING_ARGUMENT", "Missing 'displayUid' argument");
         return;
     }
     auto displayId = displayId_iter->second;
     if (VirtualDisplayControl::IsInitialized()) {
        VirtualDisplayControl::RemoveDisplay(static_cast<int>(std::get<int>((displayId))));
         result->Success(flutter::EncodableValue(true));
     } else {
         result->Error("NOT_INITIALIZED", "Parsec not initialized");
     }
  } else if (method_call.method_name().compare("checkVddStatus") == 0) {
     bool status = VirtualDisplayControl::CheckVddStatus();
     result->Success(flutter::EncodableValue(status));
  } else if (method_call.method_name().compare("getAllDisplays") == 0) {
     int displayCount = VirtualDisplayControl::GetAllDisplays();
     result->Success(flutter::EncodableValue(displayCount));
  } else if (method_call.method_name().compare("getDisplayList") == 0) {
     flutter::EncodableList displayList;
     auto displays = VirtualDisplayControl::GetDetailedDisplayList();
     
     for (const auto& display : displays) {
         flutter::EncodableMap displayMap;
         displayMap[flutter::EncodableValue("index")] = flutter::EncodableValue(display.index);
         displayMap[flutter::EncodableValue("width")] = flutter::EncodableValue(display.width);
         displayMap[flutter::EncodableValue("height")] = flutter::EncodableValue(display.height);
         displayMap[flutter::EncodableValue("refreshRate")] = flutter::EncodableValue(display.refresh_rate);
         displayMap[flutter::EncodableValue("active")] = flutter::EncodableValue(display.active);
         displayMap[flutter::EncodableValue("displayUid")] = flutter::EncodableValue(display.display_uid);
         displayMap[flutter::EncodableValue("rawScreenId")] = flutter::EncodableValue(display.raw_screen_id);
         displayMap[flutter::EncodableValue("deviceName")] = flutter::EncodableValue(display.device_name);
         displayMap[flutter::EncodableValue("displayName")] = flutter::EncodableValue(display.display_name);
         displayMap[flutter::EncodableValue("isVirtual")] = flutter::EncodableValue(display.is_virtual);
         displayMap[flutter::EncodableValue("orientation")] = flutter::EncodableValue(display.orientation);
         displayMap[flutter::EncodableValue("left")] = flutter::EncodableValue(display.left);
         displayMap[flutter::EncodableValue("top")] = flutter::EncodableValue(display.top);
         displayMap[flutter::EncodableValue("right")] = flutter::EncodableValue(display.right);
         displayMap[flutter::EncodableValue("bottom")] = flutter::EncodableValue(display.bottom);
         displayMap[flutter::EncodableValue("isPrimary")] = flutter::EncodableValue(display.is_primary);
         
         displayList.push_back(flutter::EncodableValue(displayMap));
     }
     
     result->Success(flutter::EncodableValue(displayList));
  } else if (method_call.method_name().compare("changeDisplaySettings") == 0) {
     // Change display settings
     const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
     if (!arguments) {
         result->Error("INVALID_ARGUMENTS", "Arguments must be a map");
         return;
     }

     // Get display uid
     auto uid_it = arguments->find(flutter::EncodableValue("displayUid"));
     if (uid_it == arguments->end()) {
         result->Error("MISSING_ARGUMENT", "Missing 'displayUid' argument");
         return;
     }
     int display_uid = std::get<int>(uid_it->second);

     // Get new configuration
     auto width_it = arguments->find(flutter::EncodableValue("width"));
     auto height_it = arguments->find(flutter::EncodableValue("height"));
     auto refresh_rate_it = arguments->find(flutter::EncodableValue("refreshRate"));
     
     if (width_it == arguments->end() || height_it == arguments->end() || refresh_rate_it == arguments->end()) {
         result->Error("MISSING_ARGUMENT", "Missing width, height, or refreshRate arguments");
         return;
     }
     
     VirtualDisplay::DisplayConfig new_config;
     new_config.width = std::get<int>(width_it->second);
     new_config.height = std::get<int>(height_it->second);
     new_config.refresh_rate = std::get<int>(refresh_rate_it->second);
     
     bool success = VirtualDisplayControl::ChangeDisplaySettings(display_uid, new_config);
     result->Success(flutter::EncodableValue(success));
  } else if (method_call.method_name().compare("getDisplayConfigs") == 0) {
     auto display_uid_it = args->find(flutter::EncodableValue("displayUid"));
     if (display_uid_it == args->end()) {
         result->Error("MISSING_ARGUMENT", "Missing 'displayUid' argument");
         return;
     }
     
     int display_uid = std::get<int>(display_uid_it->second);
     
     auto displays = VirtualDisplayControl::GetDetailedDisplayList();
     auto it = std::find_if(displays.begin(), displays.end(),
         [display_uid](const VirtualDisplayControl::DetailedDisplayInfo& display) {
             return display.display_uid == display_uid;
         });
     
     if (it == displays.end()) {
         result->Error("DISPLAY_NOT_FOUND", "Display not found");
         return;
     }
     
     flutter::EncodableList configList;
     auto configs = VirtualDisplayControl::GetDisplayConfigs(display_uid);
     for (const auto& config : configs) {
         flutter::EncodableMap configMap;
         configMap[flutter::EncodableValue("width")] = flutter::EncodableValue(config.width);
         configMap[flutter::EncodableValue("height")] = flutter::EncodableValue(config.height);
         configMap[flutter::EncodableValue("refreshRate")] = flutter::EncodableValue(config.refresh_rate);
         configList.push_back(flutter::EncodableValue(configMap));
     }
     
     result->Success(flutter::EncodableValue(configList));
  } else if (method_call.method_name().compare("getCustomDisplayConfigs") == 0) {
     std::vector<VirtualDisplay::DisplayConfig> configs;
     if (!DesktopServiceInputClient::Instance().GetCustomDisplayConfigs(configs)) {
         configs = VirtualDisplayControl::GetCustomDisplayConfigs();
     }
     
     flutter::EncodableList configList;
     for (const auto& config : configs) {
         flutter::EncodableMap configMap;
         configMap[flutter::EncodableValue("width")] = flutter::EncodableValue(config.width);
         configMap[flutter::EncodableValue("height")] = flutter::EncodableValue(config.height);
         configMap[flutter::EncodableValue("refreshRate")] = flutter::EncodableValue(config.refresh_rate);
         configList.push_back(flutter::EncodableValue(configMap));
     }
     
     result->Success(flutter::EncodableValue(configList));
  } else if (method_call.method_name().compare("setCustomDisplayConfigs") == 0) {
     auto configs_it = args->find(flutter::EncodableValue("configs"));
     if (configs_it == args->end()) {
         result->Error("MISSING_ARGUMENT", "Missing 'configs' argument");
         return;
     }
     
     auto configs_list = std::get<flutter::EncodableList>(configs_it->second);
     std::vector<VirtualDisplay::DisplayConfig> configs;
     
     for (const auto& item : configs_list) {
         auto config_map = std::get<flutter::EncodableMap>(item);
         
         auto width_it = config_map.find(flutter::EncodableValue("width"));
         auto height_it = config_map.find(flutter::EncodableValue("height"));
         auto refresh_rate_it = config_map.find(flutter::EncodableValue("refreshRate"));
         
         if (width_it != config_map.end() && height_it != config_map.end() && refresh_rate_it != config_map.end()) {
             VirtualDisplay::DisplayConfig config;
             config.width = std::get<int>(width_it->second);
             config.height = std::get<int>(height_it->second);
             config.refresh_rate = std::get<int>(refresh_rate_it->second);
             configs.push_back(config);
         }
     }
     
     bool success = false;
     if (!DesktopServiceInputClient::Instance().SetCustomDisplayConfigs(
             configs, success)) {
         success = VirtualDisplayControl::SetCustomDisplayConfigs(configs);
     }
     result->Success(flutter::EncodableValue(success));
  } else if (method_call.method_name().compare("setDisplayOrientation") == 0) {
     auto display_uid_it = args->find(flutter::EncodableValue("displayUid"));
     auto orientation_it = args->find(flutter::EncodableValue("orientation"));
     
     if (display_uid_it == args->end() || orientation_it == args->end()) {
         result->Error("MISSING_ARGUMENT", "Missing required arguments");
         return;
     }
     
     int display_uid = std::get<int>(display_uid_it->second);
     int orientation = std::get<int>(orientation_it->second);
     
     bool success = VirtualDisplayControl::SetDisplayOrientation(display_uid, 
                                                                  static_cast<VirtualDisplay::Orientation>(orientation));
     result->Success(flutter::EncodableValue(success));
  } else if (method_call.method_name().compare("getDisplayOrientation") == 0) {
     auto display_uid_it = args->find(flutter::EncodableValue("displayUid"));
     
     if (display_uid_it == args->end()) {
         result->Error("MISSING_ARGUMENT", "Missing displayUid argument");
         return;
     }
     
     int display_uid = std::get<int>(display_uid_it->second);
     VirtualDisplay::Orientation orientation = VirtualDisplayControl::GetDisplayOrientation(display_uid);
     
     result->Success(flutter::EncodableValue(static_cast<int>(orientation)));
  } else if (method_call.method_name().compare("setMultiDisplayMode") == 0) {
     auto mode_it = args->find(flutter::EncodableValue("mode"));
     auto primary_id_it = args->find(flutter::EncodableValue("primaryDisplayId"));
     
     if (mode_it == args->end()) {
         result->Error("MISSING_ARGUMENT", "Missing mode argument");
         return;
     }
     
     int mode = std::get<int>(mode_it->second);
     int primary_display_id = 0;
     if (primary_id_it != args->end()) {
         primary_display_id = std::get<int>(primary_id_it->second);
     }
     
     bool success = VirtualDisplayControl::SetMultiDisplayMode(
         static_cast<VirtualDisplayControl::MultiDisplayMode>(mode), 
         primary_display_id);
     
     result->Success(flutter::EncodableValue(success));
  } else if (method_call.method_name().compare("getCurrentMultiDisplayMode") == 0) {
     VirtualDisplayControl::MultiDisplayMode mode = VirtualDisplayControl::GetCurrentMultiDisplayMode();
     result->Success(flutter::EncodableValue(static_cast<int>(mode)));
  } else if (method_call.method_name().compare("setPrimaryDisplayOnly") == 0) {
     auto display_uid_it = args->find(flutter::EncodableValue("displayUid"));
     
     if (display_uid_it == args->end()) {
         result->Error("MISSING_ARGUMENT", "Missing displayUid argument");
         return;
     }
     
     int display_uid = std::get<int>(display_uid_it->second);
     bool success = VirtualDisplayControl::SetPrimaryDisplayOnly(display_uid);
     
     result->Success(flutter::EncodableValue(success));
  } else if (method_call.method_name().compare("restoreDisplayConfiguration") == 0) {
     bool success = VirtualDisplayControl::RestoreDisplayConfiguration();
     result->Success(flutter::EncodableValue(success));
  } else if (method_call.method_name().compare("hasPendingConfiguration") == 0) {
     bool has_pending = VirtualDisplayControl::HasPendingConfiguration();
     result->Success(flutter::EncodableValue(has_pending));
  } else if (method_call.method_name().compare("putImmersiveModeEnabled") == 0) {
     auto enabled = (args->find(flutter::EncodableValue("enabled")))->second;
     bool immersive_enabled = static_cast<bool>(std::get<bool>((enabled)));
     SetImmersiveMode(immersive_enabled);
     result->Success(flutter::EncodableValue(true));
  } else if (method_call.method_name().compare("setDragWindowContents") == 0) {
     auto enabled = (args->find(flutter::EncodableValue("enabled")))->second;
     bool immersive_enabled = static_cast<bool>(std::get<bool>((enabled)));
     setDragWindowContents(immersive_enabled);
     result->Success();
  } else if (method_call.method_name().compare("lockCursor") == 0) {
        LockCursor();
        result->Success(flutter::EncodableValue(true));
  } else if (method_call.method_name().compare("unlockCursor") == 0) {
        UnlockCursor();
        result->Success(flutter::EncodableValue(true));
  } else if (method_call.method_name().compare("unlockCursorAndReseed") == 0) {
        auto percentx = (args->find(flutter::EncodableValue("x")))->second;
        auto percenty = (args->find(flutter::EncodableValue("y")))->second;
        UnlockCursorAndReseed(
            static_cast<double>(std::get<double>(percentx)),
            static_cast<double>(std::get<double>(percenty)));
        result->Success(flutter::EncodableValue(true));
  } else if (method_call.method_name().compare("updateStaticMonitors") == 0) {
        UpdateStaticMonitors();
        result->Success();
  } else {
    result->NotImplemented();
  }
}

void HardwareSimulatorPlugin::SetImmersiveMode(bool enabled) {
    immersive_mode_enabled_ = enabled;
    
    if (enabled) {
        // Enable immersive mode, start keyboard blocking
        if (!SmartKeyboardBlocker::IsBlocking()) {
            SmartKeyboardBlocker::StartBlocking();
                              SmartKeyboardBlocker::SetCallback([this](const DWORD vk_code, bool isDown) {
                      OnKeyBlocked(vk_code, isDown);
                  });
        }
    } else {
        // Disable immersive mode, stop keyboard blocking
        SmartKeyboardBlocker::StopBlocking();
        SmartKeyboardBlocker::SetCallback(nullptr);
    }
}

void HardwareSimulatorPlugin::OnKeyBlocked(const DWORD vk_code, bool isDown) {
    // Notify Dart layer via method channel that a key was blocked
    if (channel_) {
        flutter::EncodableMap message;
        message[flutter::EncodableValue("keyCode")] = flutter::EncodableValue(static_cast<int>(vk_code));
        message[flutter::EncodableValue("isDown")] = flutter::EncodableValue(isDown);
        
        channel_->InvokeMethod("onKeyBlocked", 
            std::make_unique<flutter::EncodableValue>(message));
    }
}

// Cursor lock implementation
void HardwareSimulatorPlugin::LockCursor() {
    if (cursor_locked_) {
        return; // Already locked
    }

    //if (!SmartKeyboardBlocker::IsTargetWindowActive()) return;
    
    // Find Flutter window
    main_window_ = FindFlutterWindow();
    if (!main_window_) {
        return; // Could not find Flutter window
    }
    
    // Get current cursor position and lock it there
    if (!GetCursorPos(&locked_cursor_pos_)) {
        return; // Could not get cursor position
    }
    
    // Set clip rectangle to current cursor position (1x1 pixel)
    clip_rect_.left = locked_cursor_pos_.x;
    clip_rect_.top = locked_cursor_pos_.y;
    clip_rect_.right = locked_cursor_pos_.x;
    clip_rect_.bottom = locked_cursor_pos_.y;
    
    // Clip cursor to current position
    if (!ClipCursor(&clip_rect_)) {
        return; // Failed to clip cursor
    }
    
    cursor_locked_ = true;
    ShowCursor(!cursor_locked_);
    // Subscribe to Raw Input for mouse movement tracking
    if (!SubscribeToRawInputData()) {
        // If Raw Input fails, unlock cursor
        ClipCursor(nullptr);
        cursor_locked_ = false;
        ShowCursor(!cursor_locked_);
        return;
    }
}

void HardwareSimulatorPlugin::UnlockCursor() {
    if (!cursor_locked_) {
        return; // Already unlocked
    }
    
    // Unclip cursor
    ClipCursor(nullptr);
    
    // Unsubscribe from Raw Input
    UnsubscribeFromRawInputData();
    
    cursor_locked_ = false;
    ShowCursor(!cursor_locked_);
    main_window_ = nullptr;
}

void HardwareSimulatorPlugin::UnlockCursorAndReseed(
    double window_x_percent,
    double window_y_percent) {
    if (!cursor_locked_) {
        return;
    }

    HWND target_window = main_window_;

    ClipCursor(nullptr);
    UnsubscribeFromRawInputData();
    cursor_locked_ = false;

    // SendInput moves the physical cursor, while dwExtraInfo lets the window
    // procedure consume this exact synthetic WM_MOUSEMOVE before Flutter sees
    // it. No coordinate comparison or timing window is involved.
    performMouseMoveToWindowPosition(
        window_x_percent,
        window_y_percent,
        target_window,
        kCursorReseedExtraInfo);

    ShowCursor(!cursor_locked_);
    main_window_ = nullptr;
}

HWND HardwareSimulatorPlugin::FindFlutterWindow() {
    if (!registrar_) return nullptr;
    
    // Get the native window from registrar
    HWND native_window = GetParent(registrar_->GetView()->GetNativeWindow());
    if (native_window) {
        return native_window;
    }
    
    // Fallback: try to find Flutter window by class name
    HWND flutter_window = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (flutter_window) {
        return flutter_window;
    }
    
    // Try alternative window class names
    flutter_window = FindWindow(L"FlutterWindow", nullptr);
    if (flutter_window) {
        return flutter_window;
    }
    
    return nullptr;
}

void HardwareSimulatorPlugin::CleanupCursorLock() {
    if (cursor_locked_) {
        UnlockCursor();
    }
}

bool HardwareSimulatorPlugin::SubscribeToRawInputData() {
    if (raw_input_registered_) {
        return true;
    }
    
    if (!registrar_) return false;
    
    // Register raw input device
    RAWINPUTDEVICE rid[1];
    rid[0].usUsagePage = HID_USAGE_PAGE_GENERIC;
    rid[0].usUsage = HID_USAGE_GENERIC_MOUSE;
    rid[0].dwFlags = RIDEV_INPUTSINK;
    rid[0].hwndTarget = GetParent(registrar_->GetView()->GetNativeWindow());
    
    if (!RegisterRawInputDevices(rid, 1, sizeof(rid[0]))) {
        return false;
    }
    
    // Register top-level window procedure delegate to handle WM_INPUT
    raw_input_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) -> std::optional<LRESULT> {
            if (message == WM_INPUT && cursor_locked_) {
                UINT dw_size = sizeof(RAWINPUT);
                static BYTE lpb[sizeof(RAWINPUT)];
                
                if (GetRawInputData((HRAWINPUT)lparam, RID_INPUT, lpb, &dw_size, sizeof(RAWINPUTHEADER)) != -1) {
                    RAWINPUT* raw = (RAWINPUT*)lpb;
                    if (raw->header.dwType == RIM_TYPEMOUSE) {
                        // Get relative mouse movement
                        int deltaX = raw->data.mouse.lLastX;
                        int deltaY = raw->data.mouse.lLastY;
                        
                        // Send mouse movement to Dart layer
                        if (channel_) {
                            flutter::EncodableMap move_message;
                            move_message[flutter::EncodableValue("dx")] = flutter::EncodableValue(static_cast<double>(deltaX));
                            move_message[flutter::EncodableValue("dy")] = flutter::EncodableValue(static_cast<double>(deltaY));
                            
                            channel_->InvokeMethod("onCursorMoved", 
                                std::make_unique<flutter::EncodableValue>(move_message));
                        }
                    }
                }
                
                // Process Raw Input
                //DefRawInputProc((PRAWINPUT*)&lparam, 1, sizeof(RAWINPUTHEADER));
                //return 0;
            }

            if (message == WM_DPICHANGED || message == WM_DISPLAYCHANGE) {
                HardwareSimulatorPlugin::UpdateStaticMonitors();
            }

            return std::nullopt;
        });
    
    raw_input_registered_ = true;
    return true;
}

void HardwareSimulatorPlugin::UnsubscribeFromRawInputData() {
    if (!raw_input_registered_) {
        return;
    }
    
    // Unregister top-level window procedure delegate
    if (raw_input_proc_id_.has_value()) {
        registrar_->UnregisterTopLevelWindowProcDelegate(raw_input_proc_id_.value());
        raw_input_proc_id_.reset();
    }
    
    // Unregister raw input device
    RAWINPUTDEVICE rid[1];
    rid[0].usUsagePage = HID_USAGE_PAGE_GENERIC;
    rid[0].usUsage = HID_USAGE_GENERIC_MOUSE;
    rid[0].dwFlags = RIDEV_REMOVE;
    rid[0].hwndTarget = nullptr;
    RegisterRawInputDevices(rid, 1, sizeof(RAWINPUTDEVICE));
    
    raw_input_registered_ = false;
}

// Display count change callback management
void HardwareSimulatorPlugin::addDisplayCountChangedCallback(std::function<void(int)> callback, int callbackId) {
    std::lock_guard<std::mutex> lock(display_count_callbacks_mutex_);
    display_count_callbacks_[callbackId] = callback;
}

void HardwareSimulatorPlugin::removeDisplayCountChangedCallback(int callbackId) {
    std::lock_guard<std::mutex> lock(display_count_callbacks_mutex_);
    display_count_callbacks_.erase(callbackId);
}

void HardwareSimulatorPlugin::notifyDisplayCountChanged(int displayCount) {
    std::lock_guard<std::mutex> lock(display_count_callbacks_mutex_);
    for (auto& pair : display_count_callbacks_) {
        pair.second(displayCount);
    }
}

}  // namespace hardware_simulator
