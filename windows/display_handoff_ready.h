#pragma once
#include <windows.h>

// 保留的句柄不代表显示 API 已可用；失败后再次恢复也必须经过这两个步骤。
template <typename Initialize, typename EnumerateAndFind>
DWORD PrepareRecoveredDisplay(Initialize initialize, EnumerateAndFind enumerate_and_find) {
    if (!initialize()) return ERROR_NOT_READY;
    if (!enumerate_and_find()) return ERROR_NOT_FOUND;
    return ERROR_SUCCESS;
}
