#pragma once

#include <windows.h>
#include <functional>
#include <thread>
#include <vector>
#include "cpp_log_shim.h"

inline bool IsSystemDisplayProcess() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD bytes = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
  std::vector<unsigned char> storage(bytes);
  const bool system = bytes && GetTokenInformation(token, TokenUser, storage.data(), bytes, &bytes) &&
      IsWellKnownSid(reinterpret_cast<TOKEN_USER*>(storage.data())->User.Sid, WinLocalSystemSid);
  CloseHandle(token);
  return system;
}

// SYSTEM 的隐藏 Flutter 窗口属于 Default；显示设置必须在当前输入桌面执行。
// 独立线程不创建窗口，退出后释放桌面，不改变调用线程或前台桌面。
inline bool RunDisplayOperationOnInputDesktop(const std::function<bool()>& operation,
                                              bool system = IsSystemDisplayProcess()) {
  if (!system) return operation();
  HDESK desktop = nullptr;
  bool success = false;
  try {
    std::thread worker([&] {
      desktop = OpenInputDesktop(0, FALSE, GENERIC_ALL);
      if (!desktop || !SetThreadDesktop(desktop)) {
        CPPLOG_WARN("VDD_MODE", "Cannot attach display worker to input desktop error=%lu", GetLastError());
        return;
      }
      try {
        success = operation();
      } catch (...) {
        CPPLOG_WARN("VDD_MODE", "Display operation failed with an exception");
      }
    });
    worker.join();
  } catch (...) {
    CPPLOG_WARN("VDD_MODE", "Cannot create display operation thread");
  }
  if (desktop) CloseDesktop(desktop);
  return success;
}
