#pragma once
#include <cstdint>
#include <functional>
#include <memory>

// 只观察无障碍状态，不读取输入框文本。
class LinuxEditFocus {
 public:
  using Callback = std::function<void(int64_t, bool, bool)>;
  LinuxEditFocus();
  ~LinuxEditFocus();
  bool start();
  void stop();
  bool available() const;
  void inspect(int64_t request, int x, int y, Callback callback);
 private:
  struct State;
  std::unique_ptr<State> state_;
};
