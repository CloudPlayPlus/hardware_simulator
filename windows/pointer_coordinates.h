#ifndef HARDWARE_SIMULATOR_POINTER_COORDINATES_H_
#define HARDWARE_SIMULATOR_POINTER_COORDINATES_H_

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <optional>

namespace hardware_simulator {

// 屏内比例映射为屏幕物理坐标，保留位于主屏左侧/上方时的负坐标。
inline std::optional<POINT> NormalizedPointOnMonitor(
    const RECT& monitor_rect,
    double x_percent,
    double y_percent) {
  if (!std::isfinite(x_percent) || !std::isfinite(y_percent) ||
      monitor_rect.right <= monitor_rect.left ||
      monitor_rect.bottom <= monitor_rect.top) {
    return std::nullopt;
  }
  const double clamped_x = (std::clamp)(x_percent, 0.0, 1.0);
  const double clamped_y = (std::clamp)(y_percent, 0.0, 1.0);
  const LONG width = monitor_rect.right - monitor_rect.left;
  const LONG height = monitor_rect.bottom - monitor_rect.top;
  return POINT{
      monitor_rect.left +
          static_cast<LONG>(std::lround(clamped_x * (width - 1))),
      monitor_rect.top +
          static_cast<LONG>(std::lround(clamped_y * (height - 1)))};
}

// 鼠标、触摸和笔共用虚拟桌面原点；仅鼠标随后归一化到 0..65535。
// 焦点命中检测仍使用转换前的屏幕物理坐标。
inline POINT PointRelativeToVirtualDesktop(POINT point, POINT virtual_origin) {
  return POINT{point.x - virtual_origin.x, point.y - virtual_origin.y};
}

}  // namespace hardware_simulator

#endif  // HARDWARE_SIMULATOR_POINTER_COORDINATES_H_
