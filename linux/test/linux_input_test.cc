#include <cstdlib>
#include <iostream>
#include <vector>
#include <inputtino/input.hpp>
#include "linux_keyboard.h"
#include "linux_mouse.h"
namespace {
struct Event { unsigned type, code; int value; };
std::vector<Event> events;
int created = 0, creation_error = 0, write_error = 0;
#define check(ok) do { \
  if (!(ok)) { \
    std::cerr << "Failed at line " << __LINE__ << ": " << #ok << "\n"; \
    std::abort(); \
  } \
} while (false)
int sum(unsigned code) {
  int total = 0;
  for (const auto& event : events) {
    if (event.type == EV_REL && event.code == code) total += event.value;
  }
  return total;
}
}
// 拦截内核边界，不创建真实设备或向桌面发送输入。
extern "C" int __wrap_libevdev_uinput_create_from_device(const libevdev* dev, int, libevdev_uinput** out) {
  if (creation_error) return creation_error;
  if (libevdev_has_event_code(dev, EV_KEY, KEY_A)) {
    check(libevdev_has_event_type(dev, EV_REP));
    check(libevdev_has_event_code(dev, EV_KEY, KEY_RIGHTCTRL));
  }
  *out = reinterpret_cast<libevdev_uinput*>(static_cast<uintptr_t>(++created));
  return 0;
}
extern "C" void __wrap_libevdev_uinput_destroy(libevdev_uinput*) {}
extern "C" int __wrap_libevdev_uinput_write_event(const libevdev_uinput*, unsigned type, unsigned code, int value) {
  if (write_error) return write_error;
  events.push_back({type, code, value});
  return 0;
}
int main() {
  check(LinuxKeyboard::keycode(0x41) == KEY_A);
  check(LinuxKeyboard::keycode(0xA3) == KEY_RIGHTCTRL);
  check(LinuxKeyboard::keycode(0x7B) == KEY_F12);
  check(LinuxKeyboard::keycode(0x2C) == KEY_SYSRQ);
  check(LinuxKeyboard::keycode(0x90) == KEY_NUMLOCK);
  check(LinuxKeyboard::keycode(0x10041) == 0);
  check(LinuxKeyboard::keycode(-1) == 0);
  {
    LinuxKeyboard keyboard;
    creation_error = -EACCES;
    check(keyboard.send(0x41, true) == -EACCES);
    creation_error = 0;
    check(keyboard.send(0x41, true) == 0);
    check(events.size() == 2 && events[0].code == KEY_A && events[0].value == 1);
    check(keyboard.send(0x41, true) == 0 && events.size() == 2);
    check(keyboard.send(0xA3, true) == 0);
    write_error = -EIO;
    check(keyboard.clear() == -EIO);
    write_error = 0;
    events.clear();
    check(keyboard.clear() == 0 && events.size() == 3);
    check(events[0].value == 0 && events[1].value == 0);
    check(keyboard.send(0x41, false) == 0 && events.size() == 3);
    events.clear();
    check(keyboard.send(0x41, true) == 0);
    check(keyboard.send(0x41, false) == 0);
    check(events.size() == 4 && events[2].code == KEY_A && events[2].value == 0);
    check(keyboard.send(0xA3, true) == 0);
    events.clear();
  }
  check(events.size() == 2 && events[0].code == KEY_RIGHTCTRL && events[0].value == 0);
  auto result = inputtino::Mouse::create();
  check(static_cast<bool>(result));
  LinuxMouse mouse(std::move(*result));
  events.clear();
  mouse.vertical_scroll(80);
  check(sum(REL_WHEEL) == 0 && sum(REL_WHEEL_HI_RES) == 80);
  mouse.vertical_scroll(80);
  mouse.vertical_scroll(80);
  check(sum(REL_WHEEL) == 2 && sum(REL_WHEEL_HI_RES) == 240);
  events.clear();
  mouse.horizontal_scroll(-60);
  mouse.horizontal_scroll(-60);
  check(sum(REL_HWHEEL) == -1 && sum(REL_HWHEEL_HI_RES) == -120);
  mouse.vertical_scroll(60);
  mouse.vertical_scroll(-60);
  check(sum(REL_WHEEL) == 0);
  events.clear();
  mouse.vertical_scroll(60);
  mouse.move_abs(10, 10, 100, 100);
  mouse.vertical_scroll(60);
  check(sum(REL_WHEEL) == 0);
  mouse.vertical_scroll(60);
  check(sum(REL_WHEEL) == 1);
  mouse.move(0, 0);
  mouse.vertical_scroll(60);
  check(sum(REL_WHEEL) == 2);
  std::cout << "Linux keyboard and scroll regression checks passed\n";
}
