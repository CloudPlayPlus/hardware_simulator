#include "windows_editing_event_monitor.h"

#include "cpp_log_shim.h"

#include <UIAutomation.h>

#include <algorithm>
#include <cctype>
#include <utility>

namespace hardware_simulator {
namespace {

constexpr const char *kLogTag = "EDIT_FOCUS";
constexpr DWORD kFocusSettleDelayMs = 80;
constexpr LONG kPointerHitTolerancePx = 8;
constexpr int kMaximumParentDepth = 12;

std::string WideToUtf8(const wchar_t *value, int length) {
  if (value == nullptr || length <= 0) {
    return {};
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, length, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) {
    return {};
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, length, result.data(), size, nullptr,
                      nullptr);
  return result;
}

std::string ToLowerAscii(std::string value) {
  for (auto &character : value) {
    character =
        static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
  }
  return value;
}

std::string ProcessNameFromPid(int process_id) {
  if (process_id <= 0) {
    return {};
  }
  const HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return {};
  }

  wchar_t path[MAX_PATH] = {};
  DWORD length = MAX_PATH;
  std::string result;
  if (QueryFullProcessImageNameW(process, 0, path, &length) && length > 0) {
    const std::wstring full_path(path, length);
    const auto separator = full_path.find_last_of(L"\\/");
    const std::wstring name = separator == std::wstring::npos
                                  ? full_path
                                  : full_path.substr(separator + 1);
    result = WideToUtf8(name.c_str(), static_cast<int>(name.size()));
  }
  CloseHandle(process);
  return result;
}

bool IsKnownRichTextEditor(const std::string &process_name) {
  return ToLowerAscii(process_name) == "winword.exe";
}

std::optional<bool> CachedOptionalBool(IUIAutomationElement *element,
                                       PROPERTYID property_id) {
  VARIANT value = {};
  VariantInit(&value);
  std::optional<bool> result;
  if (SUCCEEDED(element->GetCachedPropertyValueEx(property_id, TRUE, &value)) &&
      value.vt == VT_BOOL) {
    result = value.boolVal == VARIANT_TRUE;
  }
  VariantClear(&value);
  return result;
}

bool CachedBool(IUIAutomationElement *element, PROPERTYID property_id,
                bool fallback = false) {
  return CachedOptionalBool(element, property_id).value_or(fallback);
}

bool HasActiveTextCaret(IUIAutomationElement *element) {
  IUnknown *pattern_unknown = nullptr;
  if (FAILED(element->GetCachedPattern(UIA_TextPattern2Id, &pattern_unknown)) ||
      pattern_unknown == nullptr) {
    return false;
  }

  IUIAutomationTextPattern2 *pattern = nullptr;
  if (FAILED(pattern_unknown->QueryInterface(IID_PPV_ARGS(&pattern))) ||
      pattern == nullptr) {
    pattern_unknown->Release();
    return false;
  }
  pattern_unknown->Release();

  BOOL active = FALSE;
  IUIAutomationTextRange *range = nullptr;
  const HRESULT result = pattern->GetCaretRange(&active, &range);
  if (range != nullptr) {
    range->Release();
  }
  pattern->Release();
  return SUCCEEDED(result) && active == TRUE;
}

bool RectContainsPointWithTolerance(const RECT &bounds, const POINT &point) {
  if (bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
    return false;
  }
  return point.x >= bounds.left - kPointerHitTolerancePx &&
         point.x <= bounds.right + kPointerHitTolerancePx &&
         point.y >= bounds.top - kPointerHitTolerancePx &&
         point.y <= bounds.bottom + kPointerHitTolerancePx;
}

IUIAutomationCacheRequest *CreateCacheRequest(IUIAutomation *automation) {
  IUIAutomationCacheRequest *request = nullptr;
  if (FAILED(automation->CreateCacheRequest(&request)) || request == nullptr) {
    return nullptr;
  }

  request->put_TreeScope(TreeScope_Element);
  constexpr PROPERTYID properties[] = {
      UIA_IsEnabledPropertyId,
      UIA_IsKeyboardFocusablePropertyId,
      UIA_ControlTypePropertyId,
      UIA_ProcessIdPropertyId,
      UIA_BoundingRectanglePropertyId,
      UIA_IsPasswordPropertyId,
      UIA_ValueIsReadOnlyPropertyId,
      UIA_IsTextPatternAvailablePropertyId,
      UIA_IsValuePatternAvailablePropertyId,
      UIA_IsTextEditPatternAvailablePropertyId,
  };
  for (const PROPERTYID property : properties) {
    request->AddProperty(property);
  }
  request->AddPattern(UIA_TextPattern2Id);
  return request;
}

} // namespace

bool IsWindowsTextInputCandidate(const WindowsTextInputTraits &traits) {
  const bool is_edit = traits.control_type_id == UIA_EditControlTypeId;
  const bool is_combo = traits.control_type_id == UIA_ComboBoxControlTypeId &&
                        traits.supports_value_pattern;
  const bool is_document =
      traits.control_type_id == UIA_DocumentControlTypeId &&
      (traits.has_active_text_caret ||
       (traits.supports_text_pattern && traits.known_rich_text_editor));
  const bool supports_editing =
      traits.supports_text_edit_pattern || traits.has_active_text_caret;
  const bool likely_text_input =
      is_edit || is_combo || is_document || supports_editing;
  if (!likely_text_input) {
    return false;
  }
  if (!traits.read_only) {
    return true;
  }
  return is_document &&
         (traits.has_active_text_caret || traits.known_rich_text_editor);
}

WindowsEditingEventMonitor::WindowsEditingEventMonitor(Callback callback)
    : callback_(std::move(callback)) {}

WindowsEditingEventMonitor::~WindowsEditingEventMonitor() { Stop(); }

bool WindowsEditingEventMonitor::Start() {
  if (is_running()) {
    return true;
  }

  stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  request_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (stop_event_ == nullptr || request_event_ == nullptr) {
    Stop();
    return false;
  }

  std::promise<bool> started;
  std::future<bool> started_future = started.get_future();
  worker_thread_ = std::thread(&WindowsEditingEventMonitor::WorkerMain, this,
                               std::move(started));
  const bool success = started_future.get();
  if (!success) {
    Stop();
  }
  return success;
}

void WindowsEditingEventMonitor::Stop() {
  if (stop_event_ != nullptr) {
    SetEvent(stop_event_);
  }
  const DWORD worker_thread_id = worker_thread_id_.load();
  if (worker_thread_id != 0) {
    CoCancelCall(worker_thread_id, 0);
  }
  if (worker_thread_.joinable()) {
    worker_thread_.join();
  }
  if (request_event_ != nullptr) {
    CloseHandle(request_event_);
    request_event_ = nullptr;
  }
  if (stop_event_ != nullptr) {
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
  std::lock_guard<std::mutex> lock(request_mutex_);
  pending_request_.reset();
  running_.store(false);
}

void WindowsEditingEventMonitor::InspectAfterRemoteClick() {
  if (!is_running() || request_event_ == nullptr) {
    return;
  }
  POINT point = {};
  if (!GetCursorPos(&point)) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(request_mutex_);
    pending_request_ = InspectionRequest{
        point,
        ++next_sequence_,
    };
  }
  SetEvent(request_event_);
}

void WindowsEditingEventMonitor::WorkerMain(std::promise<bool> started) {
  worker_thread_id_.store(GetCurrentThreadId());
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_initialized = SUCCEEDED(com_result);
  const bool cancellation_enabled =
      com_initialized && SUCCEEDED(CoEnableCallCancellation(nullptr));
  if (com_initialized) {
    CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                     IID_PPV_ARGS(&automation_));
  }
  const bool ready = com_initialized && automation_ != nullptr;
  running_.store(ready);
  started.set_value(ready);
  if (!ready) {
    if (cancellation_enabled) {
      CoDisableCallCancellation(nullptr);
    }
    worker_thread_id_.store(0);
    if (com_initialized) {
      CoUninitialize();
    }
    return;
  }

  CPPLOG_INFO(kLogTag, "Remote-click text input inspector started");
  HANDLE handles[] = {stop_event_, request_event_};
  bool stopping = false;
  while (!stopping) {
    DWORD wait_result = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
    if (wait_result == WAIT_OBJECT_0) {
      break;
    }
    if (wait_result != WAIT_OBJECT_0 + 1) {
      break;
    }

    while (true) {
      wait_result =
          WaitForMultipleObjects(2, handles, FALSE, kFocusSettleDelayMs);
      if (wait_result == WAIT_OBJECT_0) {
        stopping = true;
        break;
      }
      if (wait_result == WAIT_OBJECT_0 + 1) {
        continue;
      }
      if (wait_result != WAIT_TIMEOUT) {
        stopping = true;
        break;
      }

      std::optional<InspectionRequest> request;
      {
        std::lock_guard<std::mutex> lock(request_mutex_);
        request = pending_request_;
        pending_request_.reset();
      }
      if (request.has_value()) {
        WindowsTextInputDecision decision = Inspect(request.value());
        bool superseded = false;
        {
          std::lock_guard<std::mutex> lock(request_mutex_);
          superseded = pending_request_.has_value() &&
                       pending_request_->sequence > request->sequence;
        }
        if (!superseded && callback_) {
          callback_(decision);
        }
      }
      break;
    }
  }

  automation_->Release();
  automation_ = nullptr;
  running_.store(false);
  CPPLOG_INFO(kLogTag, "Remote-click text input inspector stopped");
  if (cancellation_enabled) {
    CoDisableCallCancellation(nullptr);
  }
  worker_thread_id_.store(0);
  CoUninitialize();
}

WindowsTextInputDecision
WindowsEditingEventMonitor::Inspect(const InspectionRequest &request) {
  WindowsTextInputDecision decision;

  IUIAutomationCacheRequest *cache = CreateCacheRequest(automation_);
  if (cache == nullptr) {
    return decision;
  }

  IUIAutomationElement *element = nullptr;
  if (FAILED(automation_->ElementFromPointBuildCache(request.point, cache,
                                                     &element)) ||
      element == nullptr) {
    cache->Release();
    return decision;
  }

  IUIAutomationTreeWalker *walker = nullptr;
  automation_->get_ControlViewWalker(&walker);
  for (int depth = 0; element != nullptr && depth < kMaximumParentDepth;
       ++depth) {
    BOOL enabled = FALSE;
    BOOL keyboard_focusable = FALSE;
    CONTROLTYPEID control_type = 0;
    int process_id = 0;
    RECT bounds = {};
    element->get_CachedIsEnabled(&enabled);
    element->get_CachedIsKeyboardFocusable(&keyboard_focusable);
    element->get_CachedControlType(&control_type);
    element->get_CachedProcessId(&process_id);
    element->get_CachedBoundingRectangle(&bounds);

    const bool supports_text =
        CachedBool(element, UIA_IsTextPatternAvailablePropertyId);
    const bool supports_value =
        CachedBool(element, UIA_IsValuePatternAvailablePropertyId);
    const bool supports_text_edit =
        CachedBool(element, UIA_IsTextEditPatternAvailablePropertyId);
    const bool read_only =
        supports_value && CachedBool(element, UIA_ValueIsReadOnlyPropertyId);
    const bool needs_caret = control_type == UIA_DocumentControlTypeId ||
                             supports_text || supports_text_edit;
    const bool active_caret = needs_caret && HasActiveTextCaret(element);
    const bool known_rich_editor =
        control_type == UIA_DocumentControlTypeId &&
        IsKnownRichTextEditor(ProcessNameFromPid(process_id));
    const WindowsTextInputTraits traits{
        control_type, supports_text, supports_value,    supports_text_edit,
        active_caret, read_only,     known_rich_editor,
    };

    const bool text_candidate = IsWindowsTextInputCandidate(traits);
    const bool inside_bounds =
        RectContainsPointWithTolerance(bounds, request.point);
    if (text_candidate && enabled && keyboard_focusable && inside_bounds) {
      decision.active = true;
      decision.secure = CachedOptionalBool(element, UIA_IsPasswordPropertyId);
      break;
    }

    IUIAutomationElement *parent = nullptr;
    if (walker == nullptr ||
        FAILED(walker->GetParentElementBuildCache(element, cache, &parent))) {
      parent = nullptr;
    }
    element->Release();
    element = parent;
  }

  if (element != nullptr) {
    element->Release();
  }
  if (walker != nullptr) {
    walker->Release();
  }
  cache->Release();
  return decision;
}

} // namespace hardware_simulator
