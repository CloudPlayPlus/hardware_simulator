#include "../cursor_position_snapshot.h"

#include <stdexcept>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

namespace {
bool readable = true;
bool monitor_readable = true;
bool monitor_present = true;
int position_reads = 0;
int monitor_queries = 0;
POINT position{-960, 540};
RECT bounds{-1920, 0, 0, 1080};

BOOL WINAPI ReadPosition(LPPOINT point) {
  ++position_reads;
  // 模拟 UAC：失败时 API 不写输出参数。
  if (!readable) return FALSE;
  *point = position;
  return TRUE;
}

HMONITOR WINAPI FindMonitor(POINT point, DWORD flags) {
  ++monitor_queries;
  CHECK(point.x == position.x && point.y == position.y);
  CHECK(flags == MONITOR_DEFAULTTONEAREST);
  return monitor_present ? reinterpret_cast<HMONITOR>(1) : nullptr;
}

BOOL WINAPI ReadMonitor(HMONITOR, LPMONITORINFO info) {
  if (!monitor_readable) return FALSE;
  info->rcMonitor = bounds;
  return TRUE;
}

auto ReadSnapshot() {
  return ReadCursorPositionSnapshot(ReadPosition, FindMonitor, ReadMonitor);
}
}  // namespace

int main() {
  auto snapshot = ReadSnapshot();
  CHECK(snapshot.has_value());
  CHECK(snapshot->position.x == -960);
  CHECK(snapshot->x_percent == 0.5f && snapshot->y_percent == 0.5f);
  CHECK(position_reads == 1);

  readable = false;
  CHECK(!ReadSnapshot());
  CHECK(monitor_queries == 1);  // 失败后不能再用无效位置查询显示器。
  readable = true;
  monitor_present = false;
  CHECK(!ReadSnapshot());
  monitor_present = true;
  monitor_readable = false;
  CHECK(!ReadSnapshot());
  monitor_readable = true;
  bounds.right = bounds.left;
  CHECK(!ReadSnapshot());
  bounds = {0, 0, 1920, 0};
  CHECK(!ReadSnapshot());

  // 退出安全桌面后可恢复，不会沿用失败时的坐标。
  bounds = {0, -1080, 1920, 0};
  position = {480, -810};
  snapshot = ReadSnapshot();
  CHECK(snapshot.has_value());
  CHECK(snapshot->x_percent == 0.25f && snapshot->y_percent == 0.25f);
  return 0;
}
