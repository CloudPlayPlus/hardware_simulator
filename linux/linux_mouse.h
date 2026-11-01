#pragma once
#include <inputtino/input.hpp>

// 保留 inputtino 的移动 / 按钮行为，在插件中补全滚轮余量。
class LinuxMouse : public inputtino::Mouse {
 public:
  explicit LinuxMouse(inputtino::Mouse&& mouse) : inputtino::Mouse(std::move(mouse)) {}
  void vertical_scroll(int distance);
  void horizontal_scroll(int distance);
 private:
  void scroll(int distance, bool vertical);
  int remainder_[2][2] = {};
};
