#pragma once

#include <windows.h>
#include <string>

// 已登记的安装只能由完整安装器迁移，不能让“安装服务”悄悄切换目录。
inline DWORD ValidateServiceInstallDirectory(DWORD registry_result,
                                            std::wstring registered,
                                            std::wstring current) {
  if (registry_result == ERROR_FILE_NOT_FOUND) return ERROR_SUCCESS;
  if (registry_result != ERROR_SUCCESS) return registry_result;
  for (auto* directory : {&registered, &current}) {
    for (auto& character : *directory) {
      if (character == L'/') character = L'\\';
    }
    while (!directory->empty() && directory->back() == L'\\') directory->pop_back();
  }
  return !registered.empty() &&
      CompareStringOrdinal(registered.data(), static_cast<int>(registered.size()),
          current.data(), static_cast<int>(current.size()), TRUE) == CSTR_EQUAL
      ? ERROR_SUCCESS : ERROR_BAD_PATHNAME;
}
