#include "desktop_service_input_client.h"

#include <cstring>

namespace hardware_simulator {
namespace {

constexpr const wchar_t* kInputPipeName =
    L"\\\\.\\pipe\\cloudplayplus_desktop_input";
constexpr uint32_t kMsgKeyInput = 0x02;
constexpr uint32_t kMsgMouseInput = 0x03;
constexpr DWORD kConnectBusyWaitMs = 2;
constexpr DWORD kWriteTimeoutMs = 20;

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
#pragma pack(pop)

static_assert(sizeof(MsgHeader) == 12, "MsgHeader size must match service IPC");
static_assert(sizeof(KeyboardInputPayload) == 8,
              "KeyboardInput size must match service IPC");
static_assert(sizeof(MouseInputPayload) == 16,
              "MouseInput size must match service IPC");

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
