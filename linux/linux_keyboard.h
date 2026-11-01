#pragma once

#include <cerrno>
#include <libevdev/libevdev-uinput.h>
#include <inputtino/keyboard.hpp>
#include <set>

// 复用已随插件分发的 VK 映射；不使用 inputtino 的无锁重复线程。
class LinuxKeyboard {
 public:
  ~LinuxKeyboard() {
    clear();
    if (device_) libevdev_uinput_destroy(device_);
  }
  LinuxKeyboard() = default;
  LinuxKeyboard(const LinuxKeyboard&) = delete;
  LinuxKeyboard& operator=(const LinuxKeyboard&) = delete;

  static int keycode(int vk) {
    if (vk < 0 || vk > 0xff) return 0;
    const auto it = inputtino::keyboard::key_mappings.find(vk);
    return it == inputtino::keyboard::key_mappings.end() ? 0 : it->second.linux_code;
  }

  int initialize() {
    if (device_) return 0;
    auto* dev = libevdev_new();
    if (!dev) return -ENOMEM;
    libevdev_set_name(dev, "CloudPlayPlus Keyboard passthrough");
    libevdev_set_id_bustype(dev, BUS_USB);
    libevdev_set_id_vendor(dev, 0xBEEF);
    libevdev_set_id_product(dev, 0xDEAE);
    libevdev_enable_event_type(dev, EV_KEY);
    libevdev_enable_event_type(dev, EV_REP);
    for (const auto& entry : inputtino::keyboard::key_mappings) {
      libevdev_enable_event_code(dev, EV_KEY, entry.second.linux_code, nullptr);
    }
    const int result = libevdev_uinput_create_from_device(
        dev, LIBEVDEV_UINPUT_OPEN_MANAGED, &device_);
    libevdev_free(dev);
    return result;
  }

  int send(int vk, bool down) {
    const int code = keycode(vk);
    if (!code) return -EINVAL;
    const int init = initialize();
    if (init < 0) return init;
    // 重发包幂等；按住重复由内核 / compositor 处理。
    if (down == (pressed_.count(code) != 0)) {
      return sync_pending_ ? synchronize() : 0;
    }
    const int result = libevdev_uinput_write_event(device_, EV_KEY, code, down ? 1 : 0);
    if (result < 0) return result;
    if (down) pressed_.insert(code);
    else pressed_.erase(code);
    return synchronize();
  }

  int clear() {
    int error = 0;
    for (auto it = pressed_.begin(); it != pressed_.end();) {
      const int result = libevdev_uinput_write_event(device_, EV_KEY, *it, 0);
      if (result < 0) { error = result; ++it; }
      else it = pressed_.erase(it);
    }
    if (device_) {
      const int result = synchronize();
      if (result < 0) error = result;
    }
    return error;
  }

 private:
  // EV_KEY 已写入后，即使 SYN_REPORT 失败也保留按键状态并补发同步。
  int synchronize() {
    const int result = libevdev_uinput_write_event(device_, EV_SYN, SYN_REPORT, 0);
    sync_pending_ = result < 0;
    return result;
  }

  bool sync_pending_ = false;
  libevdev_uinput* device_ = nullptr;
  std::set<int> pressed_;
};
