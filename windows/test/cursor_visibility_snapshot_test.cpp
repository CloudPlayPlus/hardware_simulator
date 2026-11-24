#include "../cursor_visibility_snapshot.h"

#include <stdexcept>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

namespace {
bool readable = true;
DWORD flags = 0;
bool mouse_present = true;

BOOL WINAPI ReadCursorInfo(PCURSORINFO info) {
  CHECK(info->cbSize == sizeof(CURSORINFO));
  if (!readable) return FALSE;
  info->flags = flags;
  return TRUE;
}

bool HasMouseDevice() { return mouse_present; }

std::optional<bool> Snapshot() {
  return ReadCursorVisibilitySnapshot(ReadCursorInfo, HasMouseDevice);
}
}  // namespace

int main() {
  // ShowCursor 隐藏与触摸/笔抑制都不能被当作可见。
  CHECK(Snapshot() == false);
  flags = CURSOR_SUPPRESSED;
  CHECK(Snapshot() == false);

  // 断线期间恢复可见，新订阅读取当前状态，不能沿用旧隐藏值。
  flags = CURSOR_SHOWING;
  CHECK(Snapshot() == true);
  readable = false;
  CHECK(!Snapshot().has_value());
  readable = true;
  CHECK(Snapshot() == true);

  // 无鼠标主机恒报 flags=0，必须按可见处理，否则 Viewer 会锁定指针且无光标可见。
  mouse_present = false;
  flags = 0;
  CHECK(Snapshot() == true);
  CHECK(CursorVisibleForViewer(false, HasMouseDevice));
  mouse_present = true;
  CHECK(!CursorVisibleForViewer(false, HasMouseDevice));
}
