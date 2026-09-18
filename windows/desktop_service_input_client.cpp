#include "desktop_service_input_client.h"

#include <cstring>
#include <chrono>

#include "cpp_log_shim.h"

namespace hardware_simulator {
namespace {

constexpr uint32_t kMsgKeyInput = 0x02;
constexpr uint32_t kMsgMouseInput = 0x03;
constexpr uint32_t kMsgGetCustomDisplayConfigs = 0x04;
constexpr uint32_t kMsgSetCustomDisplayConfigs = 0x05;
constexpr uint32_t kMsgTouchInput = 0x06;
constexpr uint32_t kMsgPenInput = 0x07;
constexpr uint32_t kMsgCustomDisplayConfigsResp = 0x84;
constexpr uint32_t kMsgBoolResp = 0x85;
constexpr uint32_t kMsgErrorResp = 0xFF;
constexpr uint32_t kMaxMessageSize = 4096;
constexpr uint32_t kMaxCustomDisplayConfigs = 5;
constexpr uint32_t kMaxTouchContacts = 10;
constexpr DWORD kConnectBusyWaitMs = 2;
constexpr DWORD kWriteTimeoutMs = 20;
constexpr DWORD kControlTimeoutMs = 1000;

#pragma pack(push, 1)
struct MsgHeader {
  uint32_t type;
  uint32_t payload_size;
  uint32_t seq;
};

struct KeyboardInputPayload {
  uint16_t vk;
  uint16_t scan_code;
  uint32_t flags;
};

struct MouseInputPayload {
  int32_t dx;
  int32_t dy;
  uint32_t flags;
  int32_t data;
};

struct TouchContactPayload {
  uint32_t pointer_id;
  uint32_t pointer_flags;
  int32_t x;
  int32_t y;
  uint32_t touch_flags;
  uint32_t touch_mask;
  int32_t contact_left;
  int32_t contact_top;
  int32_t contact_right;
  int32_t contact_bottom;
  uint32_t orientation;
  uint32_t pressure;
};

struct TouchInputPayload {
  uint32_t count;
  TouchContactPayload contacts[kMaxTouchContacts];
};

struct PenInputPayload {
  uint32_t pointer_id;
  uint32_t pointer_flags;
  int32_t x;
  int32_t y;
  uint32_t pen_flags;
  uint32_t pen_mask;
  uint32_t pressure;
  int32_t rotation;
  int32_t tilt_x;
  int32_t tilt_y;
};

struct CustomDisplayConfigPayload {
  uint32_t width;
  uint32_t height;
  uint32_t refresh_rate;
};

struct CustomDisplayConfigListPayload {
  uint32_t count;
  CustomDisplayConfigPayload configs[kMaxCustomDisplayConfigs];
};

struct BoolResponsePayload {
  uint32_t ok;
};
#pragma pack(pop)

static_assert(sizeof(MsgHeader) == 12, "MsgHeader size must match service IPC");
static_assert(sizeof(KeyboardInputPayload) == 8,
              "KeyboardInput size must match service IPC");
static_assert(sizeof(MouseInputPayload) == 16,
              "MouseInput size must match service IPC");
static_assert(sizeof(TouchContactPayload) == 48,
              "TouchContact size must match service IPC");
static_assert(sizeof(TouchInputPayload) == 484,
              "TouchInput size must match service IPC");
static_assert(sizeof(PenInputPayload) == 40,
              "PenInput size must match service IPC");
static_assert(sizeof(CustomDisplayConfigPayload) == 12,
              "CustomDisplayConfig size must match service IPC");
static_assert(sizeof(CustomDisplayConfigListPayload) == 64,
              "CustomDisplayConfigList size must match service IPC");
static_assert(sizeof(BoolResponsePayload) == 4,
              "BoolResponse size must match service IPC");

bool IsValidConfig(const VirtualDisplay::DisplayConfig& config) {
  return config.width > 0 && config.height > 0 && config.refresh_rate > 0;
}

// 取消只是请求；完成前不能释放 OVERLAPPED 或发送缓冲区。
bool CompleteIo(HANDLE pipe, OVERLAPPED& ov, DWORD timeout,
                HANDLE interrupt, DWORD& transferred) {
  HANDLE events[] = {ov.hEvent, interrupt};
  const DWORD wait = WaitForMultipleObjects(interrupt ? 2 : 1, events,
                                           FALSE, timeout);
  if (wait == WAIT_OBJECT_0) {
    return GetOverlappedResult(pipe, &ov, &transferred, FALSE) != FALSE;
  }
  CancelIoEx(pipe, &ov);
  GetOverlappedResult(pipe, &ov, &transferred, TRUE);
  return false;
}

bool WriteMessage(HANDLE pipe, HANDLE event, HANDLE interrupt,
                  const void* data, uint32_t size) {
  OVERLAPPED ov{};
  ov.hEvent = event;
  ResetEvent(event);
  DWORD written = 0;
  if (!WriteFile(pipe, data, size, &written, &ov)) {
    if (GetLastError() != ERROR_IO_PENDING ||
        !CompleteIo(pipe, ov, kWriteTimeoutMs, interrupt, written)) return false;
  }
  return written == size;
}

bool CoalesceMouse(std::vector<uint8_t>& previous,
                   const void* data, uint32_t size) {
  if (size != sizeof(MsgHeader) + sizeof(MouseInputPayload) ||
      previous.size() != size) return false;
  MsgHeader before{}, after{};
  memcpy(&before, previous.data(), sizeof(before));
  memcpy(&after, data, sizeof(after));
  if (before.type != kMsgMouseInput || after.type != kMsgMouseInput) return false;
  MouseInputPayload a{}, b{};
  memcpy(&a, previous.data() + sizeof(before), sizeof(a));
  memcpy(&b, static_cast<const uint8_t*>(data) + sizeof(after), sizeof(b));
  constexpr DWORD allowed = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                            MOUSEEVENTF_VIRTUALDESK;
  if (a.flags != b.flags || !(b.flags & MOUSEEVENTF_MOVE) ||
      !(b.flags & MOUSEEVENTF_ABSOLUTE) || (b.flags & ~allowed) ||
      a.data || b.data) return false;
  // 相对移动的加速逐包计算，不能用位移求和替代原始采样。
  memcpy(previous.data() + sizeof(before), &b, sizeof(b));
  return true;
}

}  // namespace

DesktopServiceInputClient& DesktopServiceInputClient::Instance() {
  static DesktopServiceInputClient client;
  return client;
}

DesktopServiceInputClient::~DesktopServiceInputClient() {
  Close();
}

void DesktopServiceInputClient::SetServiceAvailable(bool available) {
  std::lock_guard<std::mutex> lock(mutex_);
  service_available_ = available;
  if (!service_available_) {
    reset_requested_ = true;
    input_connected_ = false;
    input_queue_.clear();
    if (interrupt_event_) SetEvent(interrupt_event_);
  } else {
    StartInputThreadLocked();
  }
  input_cv_.notify_all();
}

bool DesktopServiceInputClient::SendInputMessage(const INPUT& input) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!input_connected_) {
    return false;
  }

  switch (input.type) {
    case INPUT_KEYBOARD:
      return SendKeyboardLocked(input.ki);
    case INPUT_MOUSE:
      return SendMouseLocked(input.mi);
    default:
      return false;
  }
}

bool DesktopServiceInputClient::SendTouchInput(
    const POINTER_TYPE_INFO* pointers,
    uint32_t count) {
  if (!pointers || count == 0 || count > kMaxTouchContacts) {
    return false;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  if (!input_connected_) {
    return false;
  }

  TouchInputPayload payload = {};
  payload.count = count;
  for (uint32_t i = 0; i < count; ++i) {
    if (pointers[i].type != PT_TOUCH) {
      return false;
    }
    const auto& source = pointers[i].touchInfo;
    auto& target = payload.contacts[i];
    target.pointer_id = source.pointerInfo.pointerId;
    target.pointer_flags = source.pointerInfo.pointerFlags;
    target.x = source.pointerInfo.ptPixelLocation.x;
    target.y = source.pointerInfo.ptPixelLocation.y;
    target.touch_flags = source.touchFlags;
    target.touch_mask = source.touchMask;
    target.contact_left = source.rcContact.left;
    target.contact_top = source.rcContact.top;
    target.contact_right = source.rcContact.right;
    target.contact_bottom = source.rcContact.bottom;
    target.orientation = source.orientation;
    target.pressure = source.pressure;
  }

  uint8_t buffer[sizeof(MsgHeader) + sizeof(TouchInputPayload)] = {};
  MsgHeader header = {};
  header.type = kMsgTouchInput;
  header.payload_size = sizeof(TouchInputPayload);
  memcpy(buffer, &header, sizeof(header));
  memcpy(buffer + sizeof(header), &payload, sizeof(payload));
  return EnqueueLocked(buffer, sizeof(buffer));
}

bool DesktopServiceInputClient::SendPenInput(
    const POINTER_TYPE_INFO& pointer) {
  if (pointer.type != PT_PEN) {
    return false;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  if (!input_connected_) {
    return false;
  }

  const auto& source = pointer.penInfo;
  PenInputPayload payload = {};
  payload.pointer_id = source.pointerInfo.pointerId;
  payload.pointer_flags = source.pointerInfo.pointerFlags;
  payload.x = source.pointerInfo.ptPixelLocation.x;
  payload.y = source.pointerInfo.ptPixelLocation.y;
  payload.pen_flags = source.penFlags;
  payload.pen_mask = source.penMask;
  payload.pressure = source.pressure;
  payload.rotation = source.rotation;
  payload.tilt_x = source.tiltX;
  payload.tilt_y = source.tiltY;

  uint8_t buffer[sizeof(MsgHeader) + sizeof(PenInputPayload)] = {};
  MsgHeader header = {};
  header.type = kMsgPenInput;
  header.payload_size = sizeof(PenInputPayload);
  memcpy(buffer, &header, sizeof(header));
  memcpy(buffer + sizeof(header), &payload, sizeof(payload));
  return EnqueueLocked(buffer, sizeof(buffer));
}

bool DesktopServiceInputClient::GetCustomDisplayConfigs(
    std::vector<VirtualDisplay::DisplayConfig>& configs) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  ControlConnection connection{this};
  if (!EnsureConnectedLocked()) {
    return false;
  }

  CustomDisplayConfigListPayload response = {};
  if (!ExchangeRawLocked(kMsgGetCustomDisplayConfigs, nullptr, 0,
                         kMsgCustomDisplayConfigsResp, &response,
                         sizeof(response)) ||
      response.count > kMaxCustomDisplayConfigs) {
    return false;
  }

  configs.clear();
  for (uint32_t i = 0; i < response.count; ++i) {
    const auto& item = response.configs[i];
    if (item.width == 0 || item.height == 0 || item.refresh_rate == 0) {
      return false;
    }
    configs.emplace_back(static_cast<int>(item.width),
                         static_cast<int>(item.height),
                         static_cast<int>(item.refresh_rate));
  }
  return true;
}

bool DesktopServiceInputClient::SetCustomDisplayConfigs(
    const std::vector<VirtualDisplay::DisplayConfig>& configs,
    bool& success) {
  success = false;
  if (configs.size() > kMaxCustomDisplayConfigs) {
    return false;
  }

  CustomDisplayConfigListPayload request = {};
  request.count = static_cast<uint32_t>(configs.size());
  for (size_t i = 0; i < configs.size(); ++i) {
    if (!IsValidConfig(configs[i])) {
      return false;
    }
    request.configs[i].width = static_cast<uint32_t>(configs[i].width);
    request.configs[i].height = static_cast<uint32_t>(configs[i].height);
    request.configs[i].refresh_rate =
        static_cast<uint32_t>(configs[i].refresh_rate);
  }

  std::lock_guard<std::mutex> lock(control_mutex_);
  ControlConnection connection{this};
  if (!EnsureConnectedLocked()) {
    return false;
  }

  BoolResponsePayload response = {};
  if (!ExchangeRawLocked(kMsgSetCustomDisplayConfigs, &request,
                         sizeof(request), kMsgBoolResp, &response,
                         sizeof(response))) {
    return false;
  }

  success = response.ok != 0;
  return true;
}

void DesktopServiceInputClient::Close() {
  std::thread input_thread;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_requested_ = true;
    service_available_ = false;
    input_connected_ = false;
    input_queue_.clear();
    if (interrupt_event_) SetEvent(interrupt_event_);
    input_cv_.notify_all();
    if (input_thread_.joinable()) {
      input_thread = std::move(input_thread_);
    }
  }
  if (input_thread.joinable()) input_thread.join();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (interrupt_event_) CloseHandle(interrupt_event_);
    interrupt_event_ = nullptr;
  }
  std::lock_guard<std::mutex> lock(control_mutex_);
  ClosePipeLocked();
}

bool DesktopServiceInputClient::StartInputThreadLocked() {
  if (input_thread_.joinable()) return true;
  interrupt_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!interrupt_event_) return false;
  HANDLE write_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!write_event) {
    CloseHandle(interrupt_event_);
    interrupt_event_ = nullptr;
    return false;
  }
  stop_requested_ = false;
  try {
    input_thread_ = std::thread(&DesktopServiceInputClient::InputLoop, this,
                                 write_event);
  } catch (...) {
    CloseHandle(write_event);
    CloseHandle(interrupt_event_);
    interrupt_event_ = nullptr;
    return false;
  }
  return true;
}

bool DesktopServiceInputClient::EnqueueLocked(const void* data, uint32_t size) {
  if (!input_connected_) return false;
  if (!input_queue_.empty() && CoalesceMouse(input_queue_.back(), data, size)) {
    return true;
  }
  const bool wake = input_queue_.empty();
  const auto* bytes = static_cast<const uint8_t*>(data);
  input_queue_.emplace_back(bytes, bytes + size);
  if (wake) input_cv_.notify_one();
  return true;
}

void DesktopServiceInputClient::InputLoop(HANDLE write_event) {
  HANDLE input_pipe = INVALID_HANDLE_VALUE;
  bool failure_reported = false;
  std::unique_lock<std::mutex> lock(mutex_);
  for (;;) {
    if (stop_requested_) break;
    if (!service_available_ || reset_requested_) {
      input_connected_ = false;
      input_queue_.clear();
      if (input_pipe != INVALID_HANDLE_VALUE) CloseHandle(input_pipe);
      input_pipe = INVALID_HANDLE_VALUE;
      ResetEvent(interrupt_event_);
      reset_requested_ = false;
      input_cv_.wait(lock, [this] { return stop_requested_ || service_available_; });
      continue;
    }
    if (input_pipe == INVALID_HANDLE_VALUE) {
      lock.unlock();
      input_pipe = TryConnect();
      lock.lock();
      if (stop_requested_ || !service_available_ || reset_requested_) continue;
      input_connected_ = input_pipe != INVALID_HANDLE_VALUE;
      if (!input_connected_) {
        input_cv_.wait_for(lock, std::chrono::milliseconds(250), [this] {
          return stop_requested_ || !service_available_;
        });
      }
      continue;
    }
    if (input_queue_.empty()) {
      input_cv_.wait(lock, [this] {
        return stop_requested_ || !service_available_ || !input_queue_.empty() ||
               reset_requested_;
      });
      continue;
    }
    auto packet = std::move(input_queue_.front());
    input_queue_.pop_front();
    lock.unlock();
    const bool ok = WriteMessage(input_pipe, write_event, interrupt_event_,
                                 packet.data(), static_cast<uint32_t>(packet.size()));
    lock.lock();
    if (!ok) {
      // 不重放结果不确定的输入，避免重复点击或跨连接执行旧输入。
      input_connected_ = false;
      input_queue_.clear();
      CloseHandle(input_pipe);
      input_pipe = INVALID_HANDLE_VALUE;
      if (!failure_reported) {
        CPPLOG_WARN("service_input", "Input pipe write failed; reconnecting");
        failure_reported = true;
      }
      input_cv_.wait_for(lock, std::chrono::milliseconds(250), [this] {
        return stop_requested_ || !service_available_;
      });
    } else {
      failure_reported = false;
    }
  }
  input_connected_ = false;
  input_queue_.clear();
  lock.unlock();
  if (input_pipe != INVALID_HANDLE_VALUE) CloseHandle(input_pipe);
  CloseHandle(write_event);
}

HANDLE DesktopServiceInputClient::TryConnect() {
  HANDLE pipe = CreateFileW(pipe_name_.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                            nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED,
                            nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    const DWORD err = GetLastError();
    if (err == ERROR_PIPE_BUSY &&
        WaitNamedPipeW(pipe_name_.c_str(), kConnectBusyWaitMs)) {
      pipe = CreateFileW(pipe_name_.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                         nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED,
                         nullptr);
    }
  }

  if (pipe == INVALID_HANDLE_VALUE) {
    return INVALID_HANDLE_VALUE;
  }

  DWORD mode = PIPE_READMODE_MESSAGE;
  if (!SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr)) {
    CloseHandle(pipe);
    return INVALID_HANDLE_VALUE;
  }

  return pipe;
}

bool DesktopServiceInputClient::EnsureConnectedLocked() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!service_available_ || stop_requested_) {
      ClosePipeLocked();
      return false;
    }
  }
  if (pipe_ != INVALID_HANDLE_VALUE) {
    return true;
  }

  HANDLE pipe = TryConnect();
  if (pipe != INVALID_HANDLE_VALUE) {
    pipe_ = pipe;
    control_write_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    control_read_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!control_write_event_ || !control_read_event_) {
      ClosePipeLocked();
      return false;
    }
    return true;
  }
  return false;
}

bool DesktopServiceInputClient::SendRawLocked(const void* data, uint32_t size) {
  if (!WriteMessage(pipe_, control_write_event_, nullptr, data, size)) {
    ClosePipeLocked();
    return false;
  }
  return true;
}

bool DesktopServiceInputClient::ExchangeRawLocked(uint32_t type,
                                                  const void* payload,
                                                  uint32_t payload_size,
                                                  uint32_t expected_type,
                                                  void* response,
                                                  uint32_t response_size) {
  const uint32_t seq = next_seq_++;
  if (next_seq_ == 0) {
    next_seq_ = 1;
  }

  std::vector<uint8_t> request(sizeof(MsgHeader) + payload_size);
  MsgHeader header = {};
  header.type = type;
  header.payload_size = payload_size;
  header.seq = seq;
  memcpy(request.data(), &header, sizeof(header));
  if (payload_size > 0 && payload != nullptr) {
    memcpy(request.data() + sizeof(header), payload, payload_size);
  }

  if (!SendRawLocked(request.data(), static_cast<uint32_t>(request.size()))) {
    return false;
  }

  std::vector<uint8_t> response_data;
  if (!ReadRawLocked(response_data) ||
      response_data.size() < sizeof(MsgHeader)) {
    return false;
  }

  MsgHeader response_header = {};
  memcpy(&response_header, response_data.data(), sizeof(response_header));
  const uint32_t actual_payload_size =
      static_cast<uint32_t>(response_data.size() - sizeof(MsgHeader));

  if (response_header.seq != seq ||
      response_header.payload_size != actual_payload_size ||
      response_header.type == kMsgErrorResp ||
      response_header.type != expected_type ||
      response_header.payload_size != response_size) {
    return false;
  }

  memcpy(response, response_data.data() + sizeof(MsgHeader), response_size);
  return true;
}

bool DesktopServiceInputClient::ReadRawLocked(std::vector<uint8_t>& data) {
  data.resize(kMaxMessageSize);

  OVERLAPPED overlapped = {};
  overlapped.hEvent = control_read_event_;
  ResetEvent(control_read_event_);

  DWORD bytes_read = 0;
  BOOL ok = ReadFile(pipe_, data.data(), static_cast<DWORD>(data.size()),
                     &bytes_read, &overlapped);
  if (!ok) {
    const DWORD err = GetLastError();
    if (err == ERROR_IO_PENDING) {
      if (!CompleteIo(pipe_, overlapped, kControlTimeoutMs, nullptr, bytes_read)) {
        ClosePipeLocked();
        return false;
      }
    } else {
      ClosePipeLocked();
      return false;
    }
  }

  if (bytes_read == 0) {
    ClosePipeLocked();
    return false;
  }

  data.resize(bytes_read);
  return true;
}

bool DesktopServiceInputClient::SendKeyboardLocked(const KEYBDINPUT& input) {
  uint8_t buffer[sizeof(MsgHeader) + sizeof(KeyboardInputPayload)] = {};

  MsgHeader header = {};
  header.type = kMsgKeyInput;
  header.payload_size = sizeof(KeyboardInputPayload);
  header.seq = 0;

  KeyboardInputPayload payload = {};
  payload.vk = input.wVk;
  payload.scan_code = input.wScan;
  payload.flags = input.dwFlags;

  memcpy(buffer, &header, sizeof(header));
  memcpy(buffer + sizeof(header), &payload, sizeof(payload));
  return EnqueueLocked(buffer, sizeof(buffer));
}

bool DesktopServiceInputClient::SendMouseLocked(const MOUSEINPUT& input) {
  uint8_t buffer[sizeof(MsgHeader) + sizeof(MouseInputPayload)] = {};

  MsgHeader header = {};
  header.type = kMsgMouseInput;
  header.payload_size = sizeof(MouseInputPayload);
  header.seq = 0;

  MouseInputPayload payload = {};
  payload.dx = input.dx;
  payload.dy = input.dy;
  payload.flags = input.dwFlags;
  payload.data = static_cast<int32_t>(input.mouseData);

  memcpy(buffer, &header, sizeof(header));
  memcpy(buffer + sizeof(header), &payload, sizeof(payload));
  return EnqueueLocked(buffer, sizeof(buffer));
}

void DesktopServiceInputClient::ClosePipeLocked() {
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
  if (control_write_event_) CloseHandle(control_write_event_);
  if (control_read_event_) CloseHandle(control_read_event_);
  control_write_event_ = nullptr;
  control_read_event_ = nullptr;
}

}  // namespace hardware_simulator
