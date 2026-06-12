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
constexpr auto kProbeCooldown = std::chrono::milliseconds(500);

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

bool DesktopServiceInputClient::SendInputMessage(const INPUT& input) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!EnsureConnectedLocked()) {
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
  std::lock_guard<std::mutex> lock(mutex_);
  CloseLocked();
}

bool DesktopServiceInputClient::EnsureConnectedLocked() {
  if (pipe_ != INVALID_HANDLE_VALUE) {
    return true;
  }

  const auto now = std::chrono::steady_clock::now();
  if (now < next_probe_time_) {
    return false;
  }
  next_probe_time_ = now + kProbeCooldown;

  pipe_ = CreateFileW(kInputPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                      OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
  if (pipe_ == INVALID_HANDLE_VALUE) {
    const DWORD err = GetLastError();
    if (err == ERROR_PIPE_BUSY &&
        WaitNamedPipeW(kInputPipeName, kConnectBusyWaitMs)) {
      pipe_ = CreateFileW(kInputPipeName, GENERIC_READ | GENERIC_WRITE, 0,
                          nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED,
                          nullptr);
    }
  }

  if (pipe_ == INVALID_HANDLE_VALUE) {
    return false;
  }

  DWORD mode = PIPE_READMODE_MESSAGE;
  if (!SetNamedPipeHandleState(pipe_, &mode, nullptr, nullptr)) {
    CloseLocked();
    return false;
  }

  stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!stop_event_) {
    CloseLocked();
    return false;
  }

  return true;
}

bool DesktopServiceInputClient::SendRawLocked(const void* data, uint32_t size) {
  OVERLAPPED overlapped = {};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!overlapped.hEvent) {
    CloseLocked();
    return false;
  }

  DWORD written = 0;
  BOOL ok = WriteFile(pipe_, data, size, &written, &overlapped);
  if (!ok) {
    const DWORD err = GetLastError();
    if (err == ERROR_IO_PENDING) {
      HANDLE wait_handles[] = {overlapped.hEvent, stop_event_};
      DWORD wait = WaitForMultipleObjects(2, wait_handles, FALSE,
                                          kWriteTimeoutMs);
      if (wait != WAIT_OBJECT_0 ||
          !GetOverlappedResult(pipe_, &overlapped, &written, FALSE)) {
        CancelIo(pipe_);
        CloseHandle(overlapped.hEvent);
        CloseLocked();
        return false;
      }
    } else {
      CloseHandle(overlapped.hEvent);
      CloseLocked();
      return false;
    }
  }

  CloseHandle(overlapped.hEvent);
  if (written != size) {
    CloseLocked();
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

void DesktopServiceInputClient::CloseLocked() {
  if (stop_event_) {
    SetEvent(stop_event_);
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
}

}  // namespace hardware_simulator
