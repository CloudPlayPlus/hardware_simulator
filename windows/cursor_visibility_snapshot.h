#pragma once

#include <windows.h>
#include <optional>
#include <vector>

// 主机是否接有鼠标类 Raw Input 设备（含 RDP / Hyper-V 等虚拟鼠标）。
inline bool HostHasMouseDevice() {
    UINT count = 0;
    if (GetRawInputDeviceList(nullptr, &count, sizeof(RAWINPUTDEVICELIST)) != 0) {
        return true;  // 无法判断时保持原有“按 flags 判定”的行为。
    }
    if (count == 0) return false;
    std::vector<RAWINPUTDEVICELIST> devices(count);
    const UINT read = GetRawInputDeviceList(
        devices.data(), &count, sizeof(RAWINPUTDEVICELIST));
    if (read == static_cast<UINT>(-1)) return true;
    for (UINT i = 0; i < read; ++i) {
        if (devices[i].dwType == RIM_TYPEMOUSE) return true;
    }
    return false;
}

// 无鼠标主机（无头机 / 虚拟机 / Server）上 Windows 恒报 flags=0。此时若向
// Viewer 报“隐藏”，Viewer 会进入相对锁定模式，而远端没有可见光标，导致完全
// 无法操作。因此没有鼠标设备时一律按可见处理，由 Viewer 绘制本地光标。
inline bool CursorVisibleForViewer(bool host_reports_visible,
                                   bool (*has_mouse_device)() = &HostHasMouseDevice) {
    return host_reports_visible || !has_mouse_device();
}

inline std::optional<bool> ReadCursorVisibilitySnapshot(
    decltype(&GetCursorInfo) read_cursor_info = &GetCursorInfo,
    bool (*has_mouse_device)() = &HostHasMouseDevice) {
    CURSORINFO info{};
    info.cbSize = sizeof(info);
    if (!read_cursor_info(&info)) return std::nullopt;
    // flags=0 同样是隐藏，不能只检查触摸/笔输入的 SUPPRESSED 标记。
    const bool showing = (info.flags & CURSOR_SHOWING) != 0 &&
        (info.flags & CURSOR_SUPPRESSED) == 0;
    return CursorVisibleForViewer(showing, has_mouse_device);
}
