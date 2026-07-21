#include "desktop_service_input_client.h"

#include <cstring>

namespace hardware_simulator {
namespace {

constexpr const wchar_t* kInputPipeName =
    L"\\\\.\\pipe\\cloudplayplus_desktop_input";
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
    ClosePipeLocked();
    probe_requested_ = false;
    return;
  }
  RequestProbeLocked();
}

bool DesktopServiceInputClient::SendInputMessage(const INPUT& input) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (pipe_ == INVALID_HANDLE_VALUE) {
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
  if (pipe_ == INVALID_HANDLE_VALUE) {
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
  return SendRawLocked(buffer, sizeof(buffer));
}

bool DesktopServiceInputClient::SendPenInput(
    const POINTER_TYPE_INFO& pointer) {
  if (pointer.type != PT_PEN) {
    return false;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  if (pipe_ == INVALID_HANDLE_VALUE) {
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
  return SendRawLocked(buffer, sizeof(buffer));
}

bool DesktopServiceInputClient::GetCustomDisplayConfigs(
    std::vector<VirtualDisplay::DisplayConfig>& configs) {
  std::lock_guard<std::mutex> lock(mutex_);
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

  std::lock_guard<std::mutex> lock(mutex_);
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
  std::thread probe_thread;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ClosePipeLocked();
    stop_requested_ = true;
    probe_requested_ = false;
    probe_cv_.notify_all();
    if (probe_thread_.joinable()) {
      probe_thread = std::move(probe_thread_);
    }
  }

  if (probe_thread.joinable()) {
    probe_thread.join();
  }
}

bool DesktopServiceInputClient::EnsureProbeThreadLocked() {
  if (probe_thread_.joinable()) {
    return true;
  }

  stop_requested_ = false;
  try {
    probe_thread_ = std::thread(&DesktopServiceInputClient::ProbeLoop, this);
  } catch (...) {
    return false;
  }
  return true;
}

void DesktopServiceInputClient::RequestProbeLocked() {
  if (pipe_ != INVALID_HANDLE_VALUE ||
      !service_available_ ||
      probe_requested_ ||
      probe_in_flight_ ||
      !EnsureProbeThreadLocked()) {
    return;
  }

  state_ = ServiceState::kProbing;
  probe_requested_ = true;
  probe_cv_.notify_one();
}

void DesktopServiceInputClient::ProbeLoop() {
  for (;;) {
    std::unique_lock<std::mutex> lock(mutex_);
    probe_cv_.wait(lock, [this] {
      return stop_requested_ || probe_requested_;
    });

    if (stop_requested_) {
      break;
    }

    probe_requested_ = false;
    if (pipe_ != INVALID_HANDLE_VALUE) {
      state_ = ServiceState::kConnected;
      continue;
    }

    state_ = ServiceState::kProbing;
    probe_in_flight_ = true;
    lock.unlock();

    HANDLE pipe = TryConnect();

    lock.lock();
    probe_in_flight_ = false;

    if (stop_requested_) {
      if (pipe != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe);
      }
      break;
    }

    if (!service_available_) {
      if (pipe != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe);
      }
      state_ = ServiceState::kDisconnected;
    } else if (pipe != INVALID_HANDLE_VALUE) {
      if (pipe_ == INVALID_HANDLE_VALUE) {
        pipe_ = pipe;
        state_ = ServiceState::kConnected;
      } else {
        CloseHandle(pipe);
      }
    } else {
      state_ = ServiceState::kDisconnected;
    }
  }
}

HANDLE DesktopServiceInputClient::TryConnect() {
  HANDLE pipe = CreateFileW(kInputPipeName, GENERIC_READ | GENERIC_WRITE, 0,
                            nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED,
                            nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    const DWORD err = GetLastError();
    if (err == ERROR_PIPE_BUSY &&
        WaitNamedPipeW(kInputPipeName, kConnectBusyWaitMs)) {
      pipe = CreateFileW(kInputPipeName, GENERIC_READ | GENERIC_WRITE, 0,
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
  if (!service_available_) {
    return false;
  }
  if (pipe_ != INVALID_HANDLE_VALUE) {
    return true;
  }

  HANDLE pipe = TryConnect();
  if (pipe != INVALID_HANDLE_VALUE) {
    pipe_ = pipe;
    state_ = ServiceState::kConnected;
    return true;
  }

  RequestProbeLocked();
  return false;
}

bool DesktopServiceInputClient::SendRawLocked(const void* data, uint32_t size) {
  OVERLAPPED overlapped = {};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!overlapped.hEvent) {
    ClosePipeLocked();
    RequestProbeLocked();
    return false;
  }

  DWORD written = 0;
  BOOL ok = WriteFile(pipe_, data, size, &written, &overlapped);
  if (!ok) {
    const DWORD err = GetLastError();
    if (err == ERROR_IO_PENDING) {
      DWORD wait = WaitForSingleObject(overlapped.hEvent, kWriteTimeoutMs);
      if (wait != WAIT_OBJECT_0 ||
          !GetOverlappedResult(pipe_, &overlapped, &written, FALSE)) {
        CancelIo(pipe_);
        CloseHandle(overlapped.hEvent);
        ClosePipeLocked();
        RequestProbeLocked();
        return false;
      }
    } else {
      CloseHandle(overlapped.hEvent);
      ClosePipeLocked();
      RequestProbeLocked();
      return false;
    }
  }

  CloseHandle(overlapped.hEvent);
  if (written != size) {
    ClosePipeLocked();
    RequestProbeLocked();
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
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!overlapped.hEvent) {
    ClosePipeLocked();
    RequestProbeLocked();
    return false;
  }

  DWORD bytes_read = 0;
  BOOL ok = ReadFile(pipe_, data.data(), static_cast<DWORD>(data.size()),
                     &bytes_read, &overlapped);
  if (!ok) {
    const DWORD err = GetLastError();
    if (err == ERROR_IO_PENDING) {
      DWORD wait = WaitForSingleObject(overlapped.hEvent, kControlTimeoutMs);
      if (wait != WAIT_OBJECT_0 ||
          !GetOverlappedResult(pipe_, &overlapped, &bytes_read, FALSE)) {
        CancelIo(pipe_);
        CloseHandle(overlapped.hEvent);
        ClosePipeLocked();
        RequestProbeLocked();
        return false;
      }
    } else {
      CloseHandle(overlapped.hEvent);
      ClosePipeLocked();
      RequestProbeLocked();
      return false;
    }
  }

  CloseHandle(overlapped.hEvent);
  if (bytes_read == 0) {
    ClosePipeLocked();
    RequestProbeLocked();
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
  return SendRawLocked(buffer, sizeof(buffer));
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
  return SendRawLocked(buffer, sizeof(buffer));
}

void DesktopServiceInputClient::ClosePipeLocked() {
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
  if (state_ == ServiceState::kConnected) {
    state_ = ServiceState::kDisconnected;
  }
}

}  // namespace hardware_simulator
