#include "../cursor_visibility_snapshot.h"

#include <stdexcept>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

namespace {
bool readable = true;
DWORD flags = 0;

BOOL WINAPI ReadCursorInfo(PCURSORINFO info) {
  CHECK(info->cbSize == sizeof(CURSORINFO));
  if (!readable) return FALSE;
  info->flags = flags;
  return TRUE;
}
}  // namespace

int main() {
  // ShowCursor 隐藏与触摸/笔抑制都不能被当作可见。
  CHECK(ReadCursorVisibilitySnapshot(ReadCursorInfo) == false);
  flags = CURSOR_SUPPRESSED;
  CHECK(ReadCursorVisibilitySnapshot(ReadCursorInfo) == false);

  // 断线期间恢复可见，新订阅读取当前状态，不能沿用旧隐藏值。
  flags = CURSOR_SHOWING;
  CHECK(ReadCursorVisibilitySnapshot(ReadCursorInfo) == true);
  readable = false;
  CHECK(!ReadCursorVisibilitySnapshot(ReadCursorInfo).has_value());
  readable = true;
  CHECK(ReadCursorVisibilitySnapshot(ReadCursorInfo) == true);
}
