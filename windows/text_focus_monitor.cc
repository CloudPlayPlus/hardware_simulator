#include "text_focus_monitor.h"

#include <UIAutomation.h>
#include <windows.h>

#include <atomic>
#include <cctype>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

namespace hardware_simulator {
namespace {

std::mutex g_mutex;
std::map<int, TextFocusMonitor::Callback> g_callbacks;
std::thread g_worker;
HANDLE g_stop_event = nullptr;
bool g_running = false;

std::mutex g_pointer_mutex;
std::optional<POINT> g_last_pointer_pos;
ULONGLONG g_last_pointer_tick_ms = 0;
constexpr ULONGLONG kPointerFocusWindowMs = 1200;
constexpr LONG kPointerHitTolerancePx = 8;
constexpr UINT kInspectPointerClickMessage = WM_APP + 218;
DWORD g_worker_thread_id = 0;

std::mutex g_notify_mutex;
std::string g_last_notify_key;
ULONGLONG g_last_notify_tick_ms = 0;
constexpr ULONGLONG kDuplicateNotifyWindowMs = 350;

std::string WideToUtf8(const wchar_t* value, int length) {
  if (value == nullptr || length <= 0) {
    return "";
  }
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, value, length, nullptr, 0, nullptr,
                          nullptr);
  if (size <= 0) {
    return "";
  }
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, length, output.data(), size, nullptr,
                      nullptr);
  return output;
}

std::string BstrToUtf8(BSTR value) {
  if (value == nullptr) {
    return "";
  }
  return WideToUtf8(value, static_cast<int>(SysStringLen(value)));
}

std::string ToLowerAscii(std::string value) {
  for (auto& ch : value) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  return value;
}

std::string ProcessNameFromPid(int process_id) {
  if (process_id <= 0) {
    return "";
  }

  HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return "";
  }

  wchar_t path[MAX_PATH] = {};
  DWORD length = MAX_PATH;
  std::string result;
  if (QueryFullProcessImageNameW(process, 0, path, &length) && length > 0) {
    std::wstring full_path(path, length);
    const auto pos = full_path.find_last_of(L"\\/");
    const std::wstring name =
        pos == std::wstring::npos ? full_path : full_path.substr(pos + 1);
    result = WideToUtf8(name.c_str(), static_cast<int>(name.size()));
  }

  CloseHandle(process);
  return result;
}

std::string GetBstrProperty(
    IUIAutomationElement* element,
    HRESULT (__stdcall IUIAutomationElement::*getter)(BSTR*)) {
  BSTR value = nullptr;
  if (FAILED((element->*getter)(&value)) || value == nullptr) {
    return "";
  }
  std::string result = BstrToUtf8(value);
  SysFreeString(value);
  return result;
}

bool GetBoolProperty(IUIAutomationElement* element, PROPERTYID property_id,
                     bool fallback = false) {
  VARIANT value;
  VariantInit(&value);
  bool result = fallback;
  if (SUCCEEDED(element->GetCurrentPropertyValue(property_id, &value)) &&
      value.vt == VT_BOOL) {
    result = value.boolVal == VARIANT_TRUE;
  }
  VariantClear(&value);
  return result;
}

std::string ControlTypeName(CONTROLTYPEID control_type) {
  switch (control_type) {
    case UIA_EditControlTypeId:
      return "Edit";
    case UIA_DocumentControlTypeId:
      return "Document";
    case UIA_ComboBoxControlTypeId:
      return "ComboBox";
    case UIA_PaneControlTypeId:
      return "Pane";
    case UIA_CustomControlTypeId:
      return "Custom";
    default:
      return "";
  }
}

bool IsKnownRichTextEditor(const std::string& process_name) {
  const auto lower = ToLowerAscii(process_name);
  return lower == "winword.exe";
}

bool HasActiveTextCaret(IUIAutomationElement* element) {
  IUnknown* pattern_unknown = nullptr;
  if (FAILED(element->GetCurrentPattern(UIA_TextPattern2Id,
                                        &pattern_unknown)) ||
      pattern_unknown == nullptr) {
    return false;
  }

  IUIAutomationTextPattern2* pattern = nullptr;
  if (FAILED(pattern_unknown->QueryInterface(IID_PPV_ARGS(&pattern))) ||
      pattern == nullptr) {
    pattern_unknown->Release();
    return false;
  }
  pattern_unknown->Release();

  BOOL is_active = FALSE;
  IUIAutomationTextRange* range = nullptr;
  const HRESULT hr = pattern->GetCaretRange(&is_active, &range);
  if (range != nullptr) {
    range->Release();
  }
  pattern->Release();
  return SUCCEEDED(hr) && is_active == TRUE;
}

bool IsLikelyTextInput(CONTROLTYPEID control_type, bool supports_text_pattern,
                       bool supports_value_pattern,
                       bool supports_text_edit_pattern,
                       bool has_active_text_caret,
                       const std::string& process_name) {
  if (control_type == UIA_EditControlTypeId) {
    return true;
  }
  if (control_type == UIA_ComboBoxControlTypeId && supports_value_pattern) {
    return true;
  }
  if (control_type == UIA_DocumentControlTypeId) {
    return has_active_text_caret ||
           (supports_text_pattern && IsKnownRichTextEditor(process_name));
  }
  if (supports_text_edit_pattern || has_active_text_caret) {
    return true;
  }
  return false;
}

bool RectContainsPointWithTolerance(const RECT& rect, const POINT& point) {
  if (rect.right <= rect.left || rect.bottom <= rect.top) {
    return false;
  }
  return point.x >= rect.left - kPointerHitTolerancePx &&
         point.x <= rect.right + kPointerHitTolerancePx &&
         point.y >= rect.top - kPointerHitTolerancePx &&
         point.y <= rect.bottom + kPointerHitTolerancePx;
}

bool WasFocusedByRecentPointerClick(IUIAutomationElement* element) {
  POINT pointer_pos = {};
  ULONGLONG pointer_tick_ms = 0;
  {
    std::lock_guard<std::mutex> lock(g_pointer_mutex);
    if (!g_last_pointer_pos.has_value()) {
      return false;
    }
    pointer_pos = g_last_pointer_pos.value();
    pointer_tick_ms = g_last_pointer_tick_ms;
  }

  if (GetTickCount64() - pointer_tick_ms > kPointerFocusWindowMs) {
    return false;
  }

  RECT bounding_rect = {};
  if (FAILED(element->get_CurrentBoundingRectangle(&bounding_rect))) {
    return false;
  }
  return RectContainsPointWithTolerance(bounding_rect, pointer_pos);
}

std::optional<TextFocusInfo> BuildTextFocusInfo(
    IUIAutomationElement* element,
    const std::optional<POINT>& pointer_hit = std::nullopt) {
  if (element == nullptr) {
    return std::nullopt;
  }

  BOOL is_enabled = FALSE;
  if (SUCCEEDED(element->get_CurrentIsEnabled(&is_enabled)) && !is_enabled) {
    return std::nullopt;
  }

  BOOL is_keyboard_focusable = TRUE;
  if (SUCCEEDED(element->get_CurrentIsKeyboardFocusable(
          &is_keyboard_focusable)) &&
      !is_keyboard_focusable) {
    return std::nullopt;
  }

  CONTROLTYPEID control_type = 0;
  if (FAILED(element->get_CurrentControlType(&control_type))) {
    return std::nullopt;
  }

  int process_id = 0;
  element->get_CurrentProcessId(&process_id);
  const auto process_name = ProcessNameFromPid(process_id);

  const bool supports_text_pattern =
      GetBoolProperty(element, UIA_IsTextPatternAvailablePropertyId);
  const bool supports_value_pattern =
      GetBoolProperty(element, UIA_IsValuePatternAvailablePropertyId);
  const bool supports_text_edit_pattern =
      GetBoolProperty(element, UIA_IsTextEditPatternAvailablePropertyId);
  const bool has_active_text_caret = HasActiveTextCaret(element);

  if (!IsLikelyTextInput(control_type, supports_text_pattern,
                         supports_value_pattern, supports_text_edit_pattern,
                         has_active_text_caret, process_name)) {
    return std::nullopt;
  }
  if (pointer_hit.has_value()) {
    RECT bounding_rect = {};
    if (FAILED(element->get_CurrentBoundingRectangle(&bounding_rect)) ||
        !RectContainsPointWithTolerance(bounding_rect, pointer_hit.value())) {
      return std::nullopt;
    }
  } else if (!WasFocusedByRecentPointerClick(element)) {
    return std::nullopt;
  }

  TextFocusInfo info;
  info.control_type_id = control_type;
  info.process_id = process_id;
  info.process_name = process_name;
  info.supports_text_pattern = supports_text_pattern;
  info.supports_value_pattern = supports_value_pattern;
  info.supports_text_edit_pattern = supports_text_edit_pattern;
  info.has_active_text_caret = has_active_text_caret;
  info.is_password = GetBoolProperty(element, UIA_IsPasswordPropertyId);
  info.is_read_only = GetBoolProperty(element, UIA_ValueIsReadOnlyPropertyId);
  info.name = GetBstrProperty(element, &IUIAutomationElement::get_CurrentName);
  info.localized_control_type =
      GetBstrProperty(element,
                      &IUIAutomationElement::get_CurrentLocalizedControlType);
  info.class_name =
      GetBstrProperty(element, &IUIAutomationElement::get_CurrentClassName);
  info.automation_id =
      GetBstrProperty(element, &IUIAutomationElement::get_CurrentAutomationId);
  if (info.localized_control_type.empty()) {
    info.localized_control_type = ControlTypeName(control_type);
  }

  UIA_HWND hwnd = nullptr;
  if (SUCCEEDED(element->get_CurrentNativeWindowHandle(&hwnd))) {
    info.native_window_handle = reinterpret_cast<int64_t>(hwnd);
  }

  info.timestamp_ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count();
  return info;
}

std::optional<TextFocusInfo> FindTextInputFromPoint(IUIAutomation* automation,
                                                    POINT point) {
  if (automation == nullptr) {
    return std::nullopt;
  }

  IUIAutomationElement* element = nullptr;
  if (FAILED(automation->ElementFromPoint(point, &element)) ||
      element == nullptr) {
    return std::nullopt;
  }

  IUIAutomationTreeWalker* walker = nullptr;
  automation->get_ControlViewWalker(&walker);

  IUIAutomationElement* current = element;
  while (current != nullptr) {
    auto info = BuildTextFocusInfo(current, point);
    if (info.has_value()) {
      current->Release();
      if (walker != nullptr) {
        walker->Release();
      }
      return info;
    }

    IUIAutomationElement* parent = nullptr;
    if (walker == nullptr ||
        FAILED(walker->GetParentElement(current, &parent)) ||
        parent == nullptr) {
      current->Release();
      break;
    }
    current->Release();
    current = parent;
  }

  if (walker != nullptr) {
    walker->Release();
  }
  return std::nullopt;
}

void NotifyCallbacks(const TextFocusInfo& info) {
  const std::string key =
      std::to_string(info.process_id) + "|" +
      std::to_string(info.native_window_handle) + "|" +
      std::to_string(info.control_type_id) + "|" + info.class_name + "|" +
      info.automation_id + "|" + info.name;
  const ULONGLONG now = GetTickCount64();
  {
    std::lock_guard<std::mutex> lock(g_notify_mutex);
    if (key == g_last_notify_key &&
        now - g_last_notify_tick_ms < kDuplicateNotifyWindowMs) {
      return;
    }
    g_last_notify_key = key;
    g_last_notify_tick_ms = now;
  }

  std::vector<TextFocusMonitor::Callback> callbacks;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    callbacks.reserve(g_callbacks.size());
    for (const auto& pair : g_callbacks) {
      callbacks.push_back(pair.second);
    }
  }

  for (const auto& callback : callbacks) {
    callback(info);
  }
}

class FocusChangedHandler final
    : public IUIAutomationFocusChangedEventHandler {
 public:
  FocusChangedHandler() = default;

  ULONG STDMETHODCALLTYPE AddRef() override {
    return ++ref_count_;
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const auto count = --ref_count_;
    if (count == 0) {
      delete this;
    }
    return count;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (riid == __uuidof(IUnknown) ||
        riid == __uuidof(IUIAutomationFocusChangedEventHandler)) {
      *object = static_cast<IUIAutomationFocusChangedEventHandler*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE HandleFocusChangedEvent(
      IUIAutomationElement* sender) override {
    auto info = BuildTextFocusInfo(sender);
    if (info.has_value()) {
      NotifyCallbacks(info.value());
    }
    return S_OK;
  }

 private:
  std::atomic<ULONG> ref_count_{1};
};

LRESULT CALLBACK LowLevelMouseProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code >= 0 && (wparam == WM_LBUTTONDOWN || wparam == WM_LBUTTONUP)) {
    auto* mouse = reinterpret_cast<MSLLHOOKSTRUCT*>(lparam);
    if (mouse != nullptr) {
      std::lock_guard<std::mutex> lock(g_pointer_mutex);
      g_last_pointer_pos = mouse->pt;
      g_last_pointer_tick_ms = GetTickCount64();
    }
    if (wparam == WM_LBUTTONUP && g_worker_thread_id != 0) {
      PostThreadMessageW(g_worker_thread_id, kInspectPointerClickMessage, 0,
                         0);
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

void PumpUntilStopped(HANDLE stop_event, IUIAutomation* automation = nullptr) {
  while (true) {
    const DWORD wait_result =
        MsgWaitForMultipleObjects(1, &stop_event, FALSE, INFINITE,
                                  QS_ALLINPUT);
    if (wait_result == WAIT_OBJECT_0) {
      return;
    }
    if (wait_result != WAIT_OBJECT_0 + 1) {
      return;
    }

    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == kInspectPointerClickMessage) {
        POINT pointer_pos = {};
        bool has_pointer = false;
        {
          std::lock_guard<std::mutex> lock(g_pointer_mutex);
          if (g_last_pointer_pos.has_value()) {
            pointer_pos = g_last_pointer_pos.value();
            has_pointer = true;
          }
        }
        if (has_pointer) {
          auto info = FindTextInputFromPoint(automation, pointer_pos);
          if (info.has_value()) {
            NotifyCallbacks(info.value());
          }
        }
        continue;
      }
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
  }
}

void MonitorThread(HANDLE stop_event) {
  const HRESULT coinit_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_initialized = SUCCEEDED(coinit_hr);
  if (!com_initialized) {
    PumpUntilStopped(stop_event);
    return;
  }

  IUIAutomation* automation = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_CUIAutomation, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&automation));
  if (FAILED(hr) || automation == nullptr) {
    CoUninitialize();
    PumpUntilStopped(stop_event);
    return;
  }

  auto* handler = new FocusChangedHandler();
  const bool handler_registered =
      SUCCEEDED(automation->AddFocusChangedEventHandler(nullptr, handler));

  MSG warmup_message;
  PeekMessage(&warmup_message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  g_worker_thread_id = GetCurrentThreadId();
  HHOOK mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, LowLevelMouseProc,
                                       GetModuleHandleW(nullptr), 0);

  PumpUntilStopped(stop_event, automation);

  if (mouse_hook != nullptr) {
    UnhookWindowsHookEx(mouse_hook);
  }
  g_worker_thread_id = 0;

  if (handler_registered) {
    automation->RemoveFocusChangedEventHandler(handler);
  }
  handler->Release();
  automation->Release();
  CoUninitialize();
}

void StopWorkerIfIdle() {
  HANDLE stop_event = nullptr;
  std::thread worker;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_running || !g_callbacks.empty()) {
      return;
    }
    stop_event = g_stop_event;
    if (stop_event != nullptr) {
      SetEvent(stop_event);
    }
    worker = std::move(g_worker);
    g_stop_event = nullptr;
    g_running = false;
  }

  if (worker.joinable()) {
    worker.join();
  }
  if (stop_event != nullptr) {
    CloseHandle(stop_event);
  }
}

}  // namespace

void TextFocusMonitor::Start(Callback callback, int callback_id) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_callbacks[callback_id] = std::move(callback);
  if (g_running) {
    return;
  }

  g_stop_event = CreateEvent(nullptr, TRUE, FALSE, nullptr);
  if (g_stop_event == nullptr) {
    g_callbacks.erase(callback_id);
    return;
  }
  g_running = true;
  g_worker = std::thread(MonitorThread, g_stop_event);
}

void TextFocusMonitor::Stop(int callback_id) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_callbacks.erase(callback_id);
  }
  StopWorkerIfIdle();
}

void TextFocusMonitor::StopAll() {
  HANDLE stop_event = nullptr;
  std::thread worker;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_callbacks.clear();
    if (!g_running) {
      return;
    }
    stop_event = g_stop_event;
    if (stop_event != nullptr) {
      SetEvent(stop_event);
    }
    worker = std::move(g_worker);
    g_stop_event = nullptr;
    g_running = false;
  }

  if (worker.joinable()) {
    worker.join();
  }
  if (stop_event != nullptr) {
    CloseHandle(stop_event);
  }
}

}  // namespace hardware_simulator
