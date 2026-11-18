#include "linux_gamepads.h"

#include <algorithm>
#include <sstream>

namespace {

struct XboxSnapshot {
  int buttons = 0;
  int left_trigger = 0;
  int right_trigger = 0;
  int left_x = 0;
  int left_y = 0;
  int right_x = 0;
  int right_y = 0;
};

bool valid_axis(int value) {
  return value >= -32768 && value <= 32767;
}

void apply_snapshot(inputtino::XboxOneJoypad& controller, const XboxSnapshot& state) {
  // inputtino 反转 Y 轴。XInput 最小值取反超出 evdev 轴上限，先钳到 -32767。
  controller.set_stick(inputtino::Joypad::LS, state.left_x, std::max(-32767, state.left_y));
  controller.set_stick(inputtino::Joypad::RS, state.right_x, std::max(-32767, state.right_y));
  controller.set_triggers(state.left_trigger, state.right_trigger);
  // inputtino 的按钮位与 XInput 一致，包含 HOME / Guide (0x0400)。
  controller.set_pressed_buttons(state.buttons);
}

}  // namespace

LinuxGamepads::~LinuxGamepads() {
  for (auto& controller : controllers_) {
    if (controller) apply_snapshot(*controller, {});
  }
}

inputtino::XboxOneJoypad* LinuxGamepads::get(int id) {
  if (id < 1 || static_cast<size_t>(id) > controllers_.size()) return nullptr;
  return controllers_[id - 1].get();
}

int LinuxGamepads::create() {
  const auto slot = std::find(controllers_.begin(), controllers_.end(), nullptr);
  if (slot == controllers_.end()) return -1;

  auto controller = inputtino::XboxOneJoypad::create({
      .name = "CloudPlayPlus Xbox One Controller",
      .vendor_id = 0x045E,
      .product_id = 0x02EA,
      .version = 0x0408,
  });
  if (!controller) return -1;
  *slot = std::make_unique<inputtino::XboxOneJoypad>(std::move(*controller));
  return static_cast<int>(slot - controllers_.begin()) + 1;
}

bool LinuxGamepads::remove(int id) {
  auto* controller = get(id);
  if (controller == nullptr) return false;
  apply_snapshot(*controller, {});
  controllers_[id - 1].reset();
  return true;
}

bool LinuxGamepads::apply(int id, std::string_view action) {
  auto* controller = get(id);
  if (controller == nullptr) return false;
  XboxSnapshot state;
  std::istringstream input{std::string(action)};
  if (!(input >> state.buttons >> state.left_trigger >> state.right_trigger >>
        state.left_x >> state.left_y >> state.right_x >> state.right_y)) {
    return false;
  }
  input >> std::ws;
  if (!input.eof() || state.buttons < 0 || state.buttons > 0xffff ||
      state.left_trigger < 0 || state.left_trigger > 255 ||
      state.right_trigger < 0 || state.right_trigger > 255 ||
      !valid_axis(state.left_x) || !valid_axis(state.left_y) ||
      !valid_axis(state.right_x) || !valid_axis(state.right_y)) {
    return false;
  }
  apply_snapshot(*controller, state);
  return true;
}
