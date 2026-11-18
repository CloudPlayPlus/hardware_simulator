#pragma once

#include <gdk/gdk.h>

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
};
