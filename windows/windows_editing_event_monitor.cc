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
constexpr DWORD kWorkerStopWaitMs = 250;
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

struct WindowsEditingEventMonitor::WorkerState {
  explicit WorkerState(Callback worker_callback)
      : callback(std::move(worker_callback)) {}

  ~WorkerState() {
    if (request_event != nullptr) {
      CloseHandle(request_event);
    }
    if (stop_event != nullptr) {
      CloseHandle(stop_event);
    }
    if (finished_event != nullptr) {
      CloseHandle(finished_event);
    }
  }

  Callback callback;
  std::mutex callback_mutex;
  std::atomic<bool> running = false;
  std::atomic<DWORD> worker_thread_id = 0;
  HANDLE stop_event = nullptr;
  HANDLE request_event = nullptr;
  HANDLE finished_event = nullptr;
  std::mutex request_mutex;
  std::optional<InspectionRequest> pending_request;
  std::uint64_t next_sequence = 0;
};

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

  state_ = std::make_shared<WorkerState>(callback_);
  state_->stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  state_->request_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  state_->finished_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (state_->stop_event == nullptr || state_->request_event == nullptr ||
      state_->finished_event == nullptr) {
    Stop();
    return false;
  }

  std::promise<bool> started;
  std::future<bool> started_future = started.get_future();
  worker_thread_ = std::thread(&WindowsEditingEventMonitor::WorkerMain, state_,
                               std::move(started));
  const bool success = started_future.get();
  if (!success) {
    Stop();
  }
  return success;
}

void WindowsEditingEventMonitor::Stop() {
  std::shared_ptr<WorkerState> state = state_;
  if (!state) {
    return;
  }

  state->running.store(false);
  {
    std::lock_guard<std::mutex> lock(state->callback_mutex);
    state->callback = nullptr;
  }
  {
    std::lock_guard<std::mutex> lock(state->request_mutex);
    state->pending_request.reset();
  }
  SetEvent(state->stop_event);
  const DWORD worker_thread_id = state->worker_thread_id.load();
  if (worker_thread_id != 0) {
    CoCancelCall(worker_thread_id, 0);
  }
  if (worker_thread_.joinable()) {
    if (WaitForSingleObject(state->finished_event, kWorkerStopWaitMs) ==
        WAIT_OBJECT_0) {
      worker_thread_.join();
    } else {
      worker_thread_.detach();
      CPPLOG_WARN(kLogTag,
                  "UIA worker did not stop within 250 ms; detaching cleanup");
    }
  }
  state_.reset();
}

bool WindowsEditingEventMonitor::is_running() const {
  const std::shared_ptr<WorkerState> state = state_;
  return state && state->running.load();
}

void WindowsEditingEventMonitor::InspectAfterRemotePointerUp(
    std::optional<std::int64_t> edit_focus_request_id,
    std::optional<POINT> point) {
  const std::shared_ptr<WorkerState> state = state_;
  if (!state || !state->running.load()) {
    return;
  }
  POINT inspection_point = {};
  if (point.has_value()) {
    inspection_point = point.value();
  } else if (!GetCursorPos(&inspection_point)) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(state->request_mutex);
    state->pending_request = InspectionRequest{
        inspection_point,
        ++state->next_sequence,
        edit_focus_request_id,
    };
  }
  SetEvent(state->request_event);
}

void WindowsEditingEventMonitor::WorkerMain(std::shared_ptr<WorkerState> state,
                                            std::promise<bool> started) {
  state->worker_thread_id.store(GetCurrentThreadId());
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_initialized = SUCCEEDED(com_result);
  const bool cancellation_enabled =
      com_initialized && SUCCEEDED(CoEnableCallCancellation(nullptr));
  IUIAutomation *automation = nullptr;
  if (com_initialized) {
    CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                     IID_PPV_ARGS(&automation));
  }
  const bool ready = com_initialized && automation != nullptr;
  state->running.store(ready);
  started.set_value(ready);
  if (!ready) {
    if (cancellation_enabled) {
      CoDisableCallCancellation(nullptr);
    }
    state->worker_thread_id.store(0);
    if (com_initialized) {
      CoUninitialize();
    }
    SetEvent(state->finished_event);
    return;
  }

  CPPLOG_INFO(kLogTag, "Remote-click text input inspector started");
  HANDLE handles[] = {state->stop_event, state->request_event};
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
        std::lock_guard<std::mutex> lock(state->request_mutex);
        request = state->pending_request;
        state->pending_request.reset();
      }
      if (request.has_value()) {
        WindowsTextInputDecision decision = Inspect(automation, request.value());
        bool superseded = false;
        {
          std::lock_guard<std::mutex> lock(state->request_mutex);
          superseded = state->pending_request.has_value() &&
                       state->pending_request->sequence > request->sequence;
        }
        if (!superseded) {
          std::lock_guard<std::mutex> lock(state->callback_mutex);
          if (state->callback) {
            state->callback(decision);
          }
        }
      }
      break;
    }
  }

  automation->Release();
  state->running.store(false);
  CPPLOG_INFO(kLogTag, "Remote-click text input inspector stopped");
  if (cancellation_enabled) {
    CoDisableCallCancellation(nullptr);
  }
  state->worker_thread_id.store(0);
  CoUninitialize();
  SetEvent(state->finished_event);
}

WindowsTextInputDecision
WindowsEditingEventMonitor::Inspect(IUIAutomation *automation,
                                    const InspectionRequest &request) {
  WindowsTextInputDecision decision;
  decision.edit_focus_request_id = request.edit_focus_request_id;

  IUIAutomationCacheRequest *cache = CreateCacheRequest(automation);
  if (cache == nullptr) {
    return decision;
  }

  IUIAutomationElement *element = nullptr;
  if (FAILED(automation->ElementFromPointBuildCache(request.point, cache,
                                                    &element)) ||
      element == nullptr) {
    cache->Release();
    return decision;
  }

  IUIAutomationTreeWalker *walker = nullptr;
  automation->get_ControlViewWalker(&walker);
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
