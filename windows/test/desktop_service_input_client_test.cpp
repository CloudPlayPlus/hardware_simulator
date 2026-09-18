#include "../desktop_service_input_client.h"

#include <chrono>
#include <cstring>
#include <iostream>
#include <future>
#include <stdexcept>

using namespace std::chrono_literals;
#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

namespace hardware_simulator {
class DesktopServiceInputClientTestPeer {
 public:
  static void Run() {
    // 队列积压时合并位移，离散事件和触摸保持边界。
    DesktopServiceInputClient queued;
    queued.input_connected_ = true;
    INPUT move{};
    move.type = INPUT_MOUSE;
    move.mi.dwFlags = MOUSEEVENTF_MOVE;
    move.mi.dx = 2;
    CHECK(queued.SendInputMessage(move));
    CHECK(queued.SendInputMessage(move));
    CHECK(queued.input_queue_.size() == 2);
    int32_t dx = 0;
    memcpy(&dx, queued.input_queue_.front().data() + 12, sizeof(dx));
    CHECK(dx == 2);
    INPUT key{};
    key.type = INPUT_KEYBOARD;
    key.ki.wVk = 'A';
    CHECK(queued.SendInputMessage(key));
    CHECK(queued.SendInputMessage(move));
    CHECK(queued.input_queue_.size() == 4);
    POINTER_TYPE_INFO touch{};
    touch.type = PT_TOUCH;
    touch.touchInfo.pointerInfo.pointerId = 1;
    touch.touchInfo.pointerInfo.pointerFlags = POINTER_FLAG_DOWN;
    CHECK(queued.SendTouchInput(&touch, 1));
    CHECK(queued.SendInputMessage(move));
    CHECK(queued.input_queue_.size() == 6);
    move.mi.dwFlags |= MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    move.mi.dx = 123;
    CHECK(queued.SendInputMessage(move));
    move.mi.dx = 456;
    CHECK(queued.SendInputMessage(move));
    CHECK(queued.input_queue_.size() == 7);
    memcpy(&dx, queued.input_queue_.back().data() + 12, sizeof(dx));
    CHECK(dx == 456);
    move.mi.dwFlags = MOUSEEVENTF_MOVE;
    move.mi.dx = 2;
    CHECK(queued.SendInputMessage(move));
    CHECK(queued.SendInputMessage(move));
    CHECK(queued.input_queue_.size() == 9);

    // 真正的命名管道：服务端停止读取，发送调用仍然快速返回。
    DesktopServiceInputClient client;
    client.pipe_name_ = L"\\\\.\\pipe\\cpp_input_test_" +
                        std::to_wstring(GetCurrentProcessId());
    HANDLE server = CreateNamedPipeW(client.pipe_name_.c_str(),
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        4, 64, 64, 0, nullptr);
    CHECK(server != INVALID_HANDLE_VALUE);
    HANDLE connected = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    OVERLAPPED connect{};
    connect.hEvent = connected;
    CHECK(!ConnectNamedPipe(server, &connect) && GetLastError() == ERROR_IO_PENDING);
    client.SetServiceAvailable(true);
    CHECK(WaitForSingleObject(connected, 2000) == WAIT_OBJECT_0);
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    for (;;) {
      { std::lock_guard<std::mutex> lock(client.mutex_);
        if (client.input_connected_) break; }
      CHECK(std::chrono::steady_clock::now() < deadline);
      std::this_thread::sleep_for(1ms);
    }
    // 配置查询持锁时，输入调用不能跟着等待。
    client.control_mutex_.lock();
    auto independent_input = std::async(std::launch::async, [&] {
      return client.SendInputMessage(key);
    });
    const auto independent_wait = independent_input.wait_for(100ms);
    client.control_mutex_.unlock();
    CHECK(independent_wait == std::future_status::ready);
    CHECK(independent_input.get());
    DWORD handles_before = 0;
    GetProcessHandleCount(GetCurrentProcess(), &handles_before);
    const auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < 1000; ++i) {
      // 不合并的按下/抬起让 64 字节管道饱和。
      key.ki.dwFlags = (i % 2) ? KEYEVENTF_KEYUP : 0;
      client.SendInputMessage(key);
    }
    CHECK(std::chrono::steady_clock::now() - start < 200ms);
    std::cout << "1000 stalled-pipe input calls: "
              << std::chrono::duration<double, std::milli>(
                     std::chrono::steady_clock::now() - start).count()
              << " ms\n";
    DWORD handles_after = 0;
    GetProcessHandleCount(GetCurrentProcess(), &handles_after);
    CHECK(handles_after <= handles_before + 2);
    const auto stop = std::chrono::steady_clock::now();
    client.Close();
    CHECK(std::chrono::steady_clock::now() - stop < 1s);
    CHECK(client.input_queue_.empty());
    CloseHandle(connected);
    DisconnectNamedPipe(server);
    CloseHandle(server);

    // Close 后可重新启用；禁用也必须清理旧队列并允许重新连接。
    server = CreateNamedPipeW(client.pipe_name_.c_str(),
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        4, 4096, 4096, 0, nullptr);
    CHECK(server != INVALID_HANDLE_VALUE);
    client.SetServiceAvailable(true);
    const auto reconnect_deadline = std::chrono::steady_clock::now() + 2s;
    for (;;) {
      { std::lock_guard<std::mutex> lock(client.mutex_);
        if (client.input_connected_) break; }
      CHECK(std::chrono::steady_clock::now() < reconnect_deadline);
      std::this_thread::sleep_for(1ms);
    }
    CHECK(client.SendInputMessage(key));
    // 断管后的首次写失败触发后台重连，不要求再次通知服务状态。
    DisconnectNamedPipe(server);
    CloseHandle(server);
    client.SendInputMessage(key);
    const auto disconnected_deadline = std::chrono::steady_clock::now() + 2s;
    for (;;) {
      { std::lock_guard<std::mutex> lock(client.mutex_);
        if (!client.input_connected_) break; }
      CHECK(std::chrono::steady_clock::now() < disconnected_deadline);
      std::this_thread::sleep_for(1ms);
    }
    server = CreateNamedPipeW(client.pipe_name_.c_str(),
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        4, 4096, 4096, 0, nullptr);
    CHECK(server != INVALID_HANDLE_VALUE);
    const auto automatic_deadline = std::chrono::steady_clock::now() + 2s;
    for (;;) {
      { std::lock_guard<std::mutex> lock(client.mutex_);
        if (client.input_connected_) break; }
      CHECK(std::chrono::steady_clock::now() < automatic_deadline);
      std::this_thread::sleep_for(1ms);
    }
    { std::lock_guard<std::mutex> lock(client.mutex_);
      CHECK(client.input_queue_.empty()); }
    client.SetServiceAvailable(false);
    CHECK(!client.SendInputMessage(key));
    { std::lock_guard<std::mutex> lock(client.mutex_);
      CHECK(client.input_queue_.empty()); }
    client.Close();
    DisconnectNamedPipe(server);
    CloseHandle(server);
  }
};
}  // namespace hardware_simulator

int main() {
  try { hardware_simulator::DesktopServiceInputClientTestPeer::Run(); }
  catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
  std::cout << "input queue and stalled-pipe tests passed\n";
}
