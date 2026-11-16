#pragma once

#include <windows.h>

// 接管 ShellExecuteEx 返回的句柄；提权成功不代表服务命令成功。
inline bool WaitForServiceCommand(HANDLE process, DWORD* error) {
  DWORD result = ERROR_INVALID_HANDLE;
  if (process) {
    if (WaitForSingleObject(process, INFINITE) != WAIT_OBJECT_0) {
      result = GetLastError();
    } else if (!GetExitCodeProcess(process, &result)) {
      result = GetLastError();
    }
    CloseHandle(process);
  }
  if (error) *error = result;
  return result == ERROR_SUCCESS;
}
