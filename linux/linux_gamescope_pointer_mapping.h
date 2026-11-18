#pragma once

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>

namespace linux_gamescope_pointer {

enum class Scaler : unsigned long { kAuto, kInteger, kFit, kFill, kStretch };

struct ScaleConfig {
  int nested_width = 0;
  int nested_height = 0;
  double max_auto_scale = std::numeric_limits<double>::infinity();
  bool resize_nested_height = false;
};

struct Scale {
  double x;
  double y;
};

inline Scaler select_scaler(std::optional<unsigned long> modern,
                            unsigned long legacy) {
  if (modern && *modern <= static_cast<unsigned long>(Scaler::kStretch)) {
    return static_cast<Scaler>(*modern);
  }
  return legacy == 2 ? Scaler::kInteger : Scaler::kAuto;
}

inline Scale window_scale(const ScaleConfig& config, Scaler scaler,
                          int output_width, int output_height,
                          int window_width, int window_height) {
  int nested_width = config.nested_width;
  int nested_height = config.nested_height;
  if (nested_width == 0) {
    nested_width = nested_height == 0 ? output_width
                                      : std::max(1, static_cast<int>(
                                            nested_height * (16.0 / 9)));
  }
  if (nested_height == 0 || config.resize_nested_height) {
    nested_height = std::max(1, static_cast<int>(
        static_cast<double>(nested_width) * output_height / output_width));
  }
  const double output_x = static_cast<double>(output_width) / nested_width;
  const double output_y = static_cast<double>(output_height) / nested_height;
  const double window_x = static_cast<double>(nested_width) / window_width;
  const double window_y = static_cast<double>(nested_height) / window_height;
  if (scaler == Scaler::kStretch) {
    return {window_x * output_x, window_y * output_y};
  }
  double scale = scaler == Scaler::kFill ? std::max(window_x, window_y)
                                         : std::min(window_x, window_y);
  if (scaler == Scaler::kAuto) scale = std::min(scale, config.max_auto_scale);
  scale *= std::min(output_x, output_y);
  if (scaler == Scaler::kInteger && scale > 1.0) scale = std::floor(scale);
  return {scale, scale};
}

inline int map_axis(double position, int output, int window, double scale,
                    double zoom = 1.0, int cursor = 0) {
  scale *= zoom;
  double inset = (output - window * scale) / 2;
  // 放大镜以当前光标为锚点平移画面；与 Gamescope 使用相同的整数窗口中心。
  if (zoom != 1.0) inset += (window / 2 - cursor) * scale;
  const double local = (std::clamp(position, 0.0, 1.0) * output - inset) / scale;
  return static_cast<int>(std::lround(std::clamp(local, 0.0, window - 1.0)));
}

}  // namespace linux_gamescope_pointer
