#pragma once

#include <windows.h>
#include <optional>

inline std::optional<bool> ReadCursorVisibilitySnapshot(
    decltype(&GetCursorInfo) read_cursor_info = &GetCursorInfo) {
    CURSORINFO info{};
    info.cbSize = sizeof(info);
    if (!read_cursor_info(&info)) return std::nullopt;
    // flags=0 同样是隐藏，不能只检查触摸/笔输入的 SUPPRESSED 标记。
    return (info.flags & CURSOR_SHOWING) != 0 &&
        (info.flags & CURSOR_SUPPRESSED) == 0;
}
