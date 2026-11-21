#include "../service_command_result.h"

#include <stdexcept>
#include <string>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

int wmain(int argc, wchar_t** argv) {
  if (argc == 2) return std::stoi(argv[1]);
  wchar_t executable[MAX_PATH]{};
  CHECK(GetModuleFileNameW(nullptr, executable, MAX_PATH) != 0);
  for (const DWORD expected : {0ul, 7ul}) {
    std::wstring command = L"\"" + std::wstring(executable) + L"\" " + std::to_wstring(expected);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    CHECK(CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process));
    CloseHandle(process.hThread);
    DWORD error = 999;
    CHECK(WaitForServiceCommand(process.hProcess, &error) == (expected == 0));
    CHECK(error == expected);
    // 完成函数负责释放 ShellExecuteEx 返回的进程句柄。
    DWORD flags = 0;
    CHECK(!GetHandleInformation(process.hProcess, &flags));
  }
  DWORD error = 0;
  CHECK(!WaitForServiceCommand(nullptr, &error));
  CHECK(error == ERROR_INVALID_HANDLE);
  return 0;
}
