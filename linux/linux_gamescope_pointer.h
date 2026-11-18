#pragma once

#include <gdk/gdk.h>

#include <optional>

#include "linux_gamescope_pointer_mapping.h"

class LinuxGamescopePointer {
 public:
  LinuxGamescopePointer() = default;
  ~LinuxGamescopePointer();
  LinuxGamescopePointer(const LinuxGamescopePointer&) = delete;
  LinuxGamescopePointer& operator=(const LinuxGamescopePointer&) = delete;

  static bool in_session();
  bool move(double x, double y);

 private:
  GdkDisplay* control_ = nullptr;
  GdkDisplay* target_ = nullptr;
  std::optional<linux_gamescope_pointer::ScaleConfig> scale_config_;
};
