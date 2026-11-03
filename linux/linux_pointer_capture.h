#pragma once
#include <gtk/gtk.h>
#include <functional>
#include <memory>
#include <string>

// 仅操作当前 GTK 窗口。所有调用和回调均在 GTK 主线程。
class LinuxPointerCapture {
 public:
  using State = std::function<void(int64_t, bool, const char*)>;
  using Motion = std::function<void(int64_t, double, double)>;
  LinuxPointerCapture(GtkWidget* view, State state, Motion motion);
  ~LinuxPointerCapture();
  bool supported();
  std::string lock(int64_t generation);
  void unlock(const char* reason = "released");
  void unlock_generation(int64_t generation);
  void unlock_and_reseed_generation(int64_t generation, double x, double y);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
