#pragma once

#include <windows.h>
#include <optional>

struct CursorPositionSnapshot {
    POINT position;
    RECT monitor;
    float x_percent;
    float y_percent;
};

// UAC 切换期间 API 可能失败且不写输出；缺失快照不能被编码为屏幕边缘。
inline std::optional<CursorPositionSnapshot> ReadCursorPositionSnapshot(
    decltype(&GetCursorPos) read_position = &GetCursorPos,
    decltype(&MonitorFromPoint) find_monitor = &MonitorFromPoint,
    decltype(&GetMonitorInfoW) read_monitor = &GetMonitorInfoW) {
    POINT position{};
    if (!read_position(&position)) return std::nullopt;
    const auto monitor = find_monitor(position, MONITOR_DEFAULTTONEAREST);
    if (monitor == nullptr) return std::nullopt;
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (!read_monitor(monitor, &info)) return std::nullopt;
    const auto& rect = info.rcMonitor;
    const auto width = rect.right - rect.left;
    const auto height = rect.bottom - rect.top;
    if (width <= 0 || height <= 0) return std::nullopt;
    return CursorPositionSnapshot{
        position, rect,
        static_cast<float>(position.x - rect.left) / width,
        static_cast<float>(position.y - rect.top) / height};
}
