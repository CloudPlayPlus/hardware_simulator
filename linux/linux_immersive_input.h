#pragma once
#include <gtk/gtk.h>
#include <memory>

// 仅捕获当前窗口键盘；不改变鼠标捕获，也不合成或重发按键。
class LinuxImmersiveInput {
 public:
  explicit LinuxImmersiveInput(GtkWidget* view);
  ~LinuxImmersiveInput();
  bool set_enabled(bool enabled);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
