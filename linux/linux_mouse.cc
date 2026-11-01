#include "linux_mouse.h"
// 上游内部头同时定义了此文件未使用的静态读取助手。
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include <inputtino/protected_types.hpp>
#pragma GCC diagnostic pop

void LinuxMouse::vertical_scroll(int distance) { scroll(distance, true); }
void LinuxMouse::horizontal_scroll(int distance) { scroll(distance, false); }

void LinuxMouse::scroll(int distance, bool vertical) {
  const int mode = _state->absolute ? 1 : 0;
  auto* device = mode ? _state->mouse_abs.get() : _state->mouse_rel.get();
  if (!device) return;
  auto& remainder = remainder_[mode][vertical ? 0 : 1];
  const auto total = static_cast<long long>(remainder) + distance;
  const int detents = static_cast<int>(total / 120);
  remainder = static_cast<int>(total % 120);
  if (detents != 0) {
    libevdev_uinput_write_event(device, EV_REL,
        vertical ? REL_WHEEL : REL_HWHEEL, detents);
  }
  libevdev_uinput_write_event(device, EV_REL,
      vertical ? REL_WHEEL_HI_RES : REL_HWHEEL_HI_RES, distance);
  libevdev_uinput_write_event(device, EV_SYN, SYN_REPORT, 0);
}
