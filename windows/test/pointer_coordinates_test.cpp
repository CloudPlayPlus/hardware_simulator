#include "../pointer_coordinates.h"

#include <limits>
#include <stdexcept>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

using hardware_simulator::NormalizedPointOnMonitor;
using hardware_simulator::PointRelativeToVirtualDesktop;

void CheckPoint(RECT monitor, POINT origin, double x, double y,
                POINT expected_screen, POINT expected_injection) {
  const auto screen = NormalizedPointOnMonitor(monitor, x, y);
  CHECK(screen.has_value());
  CHECK(screen->x == expected_screen.x && screen->y == expected_screen.y);
  const auto injection = PointRelativeToVirtualDesktop(*screen, origin);
  CHECK(injection.x == expected_injection.x);
  CHECK(injection.y == expected_injection.y);
  // 注入转换不改变焦点检测使用的原始屏幕点。
  CHECK(screen->x == expected_screen.x && screen->y == expected_screen.y);
}

int main() {
  // 左侧/上方副屏：注入以虚拟桌面左上角为原点，不能直接发送负屏幕坐标。
  CheckPoint({-1920, 0, 0, 1080}, {-1920, 0}, 0.5, 0.5,
             {-960, 540}, {960, 540});
  CheckPoint({0, -1080, 1920, 0}, {0, -1080}, 0.5, 0.5,
             {960, -540}, {960, 540});
  // 右侧、下方与单屏的虚拟原点为零，保持原行为。
  CheckPoint({1920, 0, 3840, 1080}, {0, 0}, 0.5, 0.5,
             {2880, 540}, {2880, 540});
  CheckPoint({0, 1080, 1920, 2160}, {0, 0}, 0.5, 0.5,
             {960, 1620}, {960, 1620});
  CheckPoint({0, 0, 1920, 1080}, {0, 0}, 0.5, 0.5,
             {960, 540}, {960, 540});
  // 存在负原点时，主屏与右侧屏也必须扣除原点；覆盖异分辨率布局及四角。
  const RECT monitor{0, 0, 2560, 1440};
  const POINT origin{-1920, -1080};
  CheckPoint(monitor, origin, 0, 0, {0, 0}, {1920, 1080});
  CheckPoint(monitor, origin, 1, 0, {2559, 0}, {4479, 1080});
  CheckPoint(monitor, origin, 0, 1, {0, 1439}, {1920, 2519});
  CheckPoint(monitor, origin, 1, 1, {2559, 1439}, {4479, 2519});
  CheckPoint(monitor, origin, -0.1, 1.1, {0, 1439}, {1920, 2519});
  CHECK(!NormalizedPointOnMonitor(monitor,
      std::numeric_limits<double>::quiet_NaN(), 0));
  CHECK(!NormalizedPointOnMonitor(monitor, 0,
      std::numeric_limits<double>::infinity()));
  CHECK(!NormalizedPointOnMonitor({0, 0, 0, 1080}, 0.5, 0.5));
  return 0;
}
