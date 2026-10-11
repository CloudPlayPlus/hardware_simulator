#include "../desktop_service_input_client.h"
#include <future>
#include <cstring>
#include <iostream>
#include <stdexcept>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

namespace hardware_simulator {
class DesktopServiceInputClientTestPeer {
 public:
  static void Run() {
    DesktopServiceInputClient client;
    client.service_available_ = true; // 仅开控制连接，不启动输入线程。
    client.pipe_name_ = L"\\\\.\\pipe\\cpp_display_restore_test_" +
                        std::to_wstring(GetCurrentProcessId());
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(1);
    paths[0].flags = DISPLAYCONFIG_PATH_ACTIVE;
    paths[0].sourceInfo.adapterId.LowPart = 123;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(2);
    LONG status = ERROR_SUCCESS;
    CHECK(!client.RestoreDisplayConfiguration({}, modes, status));
    CHECK(!client.RestoreDisplayConfiguration(paths, {}, status));
    CHECK(!client.RestoreDisplayConfiguration(
        std::vector<DISPLAYCONFIG_PATH_INFO>(100), modes, status));
    // 服务成功/拒绝均必须返回真实 Win32 状态，不能把连接成功当恢复成功。
    for (uint32_t expected : {0u, 5u, 1610u}) {
      HANDLE server = CreateNamedPipeW(client.pipe_name_.c_str(),
          PIPE_ACCESS_DUPLEX, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
          1, 4096, 4096, 0, nullptr);
      CHECK(server != INVALID_HANDLE_VALUE);
      auto response = std::async(std::launch::async, [&] {
        CHECK(ConnectNamedPipe(server, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED);
        uint8_t bytes[4096]{};
        DWORD count = 0;
        CHECK(ReadFile(server, bytes, sizeof(bytes), &count, nullptr));
        uint32_t header[3]{};
        memcpy(header, bytes, sizeof(header));
        CHECK(header[0] == 0x09 && header[2] != 0);
        CHECK(count == 12 + 8 + paths.size() * sizeof(paths[0]) + modes.size() * sizeof(modes[0]));
        CHECK(header[1] == count - 12);
        uint32_t counts[2]{};
        memcpy(counts, bytes + 12, sizeof(counts));
        CHECK(counts[0] == 1 && counts[1] == 2);
        CHECK(memcmp(bytes + 20, paths.data(), sizeof(paths[0])) == 0);
        CHECK(memcmp(bytes + 20 + sizeof(paths[0]), modes.data(), 2 * sizeof(modes[0])) == 0);
        uint32_t reply[] = {0x89, 4, header[2], expected};
        CHECK(WriteFile(server, reply, sizeof(reply), &count, nullptr));
      });
      CHECK(client.RestoreDisplayConfiguration(paths, modes, status));
      CHECK(status == static_cast<LONG>(expected));
      response.get();
      DisconnectNamedPipe(server);
      CloseHandle(server);
    }
    CHECK(!client.RestoreDisplayConfiguration(paths, modes, status));
  }
};
}
int main() {
  try { hardware_simulator::DesktopServiceInputClientTestPeer::Run(); }
  catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
  std::cout << "display restore client pipe contract passed\n";
}
