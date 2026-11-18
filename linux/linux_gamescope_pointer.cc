#include "linux_gamescope_pointer.h"

#include <gdk/gdkx.h>
#include <X11/Xatom.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <charconv>
#include <cmath>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace {

using linux_gamescope_pointer::ScaleConfig;
using linux_gamescope_pointer::Scaler;
using linux_gamescope_pointer::map_axis;
using linux_gamescope_pointer::select_scaler;
using linux_gamescope_pointer::window_scale;

std::optional<int> display_number(std::string_view name) {
  if (name.empty() || name.front() != ':') return std::nullopt;
  name.remove_prefix(1);
  if (name.size() > 2 && name.substr(name.size() - 2) == ".0") {
    name.remove_suffix(2);
  }
  int number;
  const auto end = name.data() + name.size();
  const auto result = std::from_chars(name.data(), end, number);
  if (result.ec != std::errc{} || result.ptr != end || number < 0) {
    return std::nullopt;
  }
  return number;
}

struct RootProperty {
  explicit RootProperty(Display* display, const char* name) {
    const Atom atom = XInternAtom(display, name, True);
    if (atom == None) return;
    unsigned char* raw = nullptr;
    unsigned long remaining = 0;
    if (XGetWindowProperty(display, DefaultRootWindow(display), atom, 0, 16,
                           False, XA_CARDINAL, &type, &format, &count,
                           &remaining, &raw) == Success && remaining == 0) {
      data.reset(raw);
    } else if (raw != nullptr) {
      XFree(raw);
    }
  }

  const unsigned long* cardinals() const {
    return type == XA_CARDINAL && format == 32
               ? reinterpret_cast<const unsigned long*>(data.get())
               : nullptr;
  }

  Atom type = None;
  int format = 0;
  unsigned long count = 0;
  std::unique_ptr<unsigned char, decltype(&XFree)> data{nullptr, XFree};
};

std::optional<unsigned long> read_cardinal(Display* display, const char* name) {
  const RootProperty property(display, name);
  const auto* values = property.cardinals();
  if (values == nullptr || property.count != 1) return std::nullopt;
  return values[0] & 0xffffffffUL;
}

std::optional<int> read_focus_display(Display* display, const char* name) {
  const RootProperty property(display, name);
  const auto* values = property.cardinals();
  if (values == nullptr) return std::nullopt;
  // Gamescope 以 32 位 CARDINAL 写入显示名，名称位于低位字节中。
  std::string display_name;
  for (unsigned long i = 0; i < property.count; ++i) {
    for (int shift = 0; shift < 32; shift += 8) {
      const auto byte = static_cast<char>((values[i] >> shift) & 0xff);
      if (byte == '\0') return display_number(display_name);
      display_name.push_back(byte);
    }
  }
  return std::nullopt;
}

std::optional<unsigned long> server_id(Display* display) {
  return read_cardinal(display, "GAMESCOPE_XWAYLAND_SERVER_ID");
}

GdkDisplay* open_display(int number) {
  const std::string name = ":" + std::to_string(number);
  auto* display = gdk_display_open(name.c_str());
  if (display != nullptr && !GDK_IS_X11_DISPLAY(display)) {
    gdk_display_close(display);
    return nullptr;
  }
  return display;
}

ScaleConfig read_scale_config(Display* display) {
  ScaleConfig config;
  // Gamescope 创建 XWayland 的监听 socket。XWayland 根窗口只报告输出尺寸，
  // 嵌套分辨率和自动缩放上限来自创建该 socket 的合成器启动参数。
  struct ucred peer{};
  socklen_t size = sizeof(peer);
  if (getsockopt(ConnectionNumber(display), SOL_SOCKET, SO_PEERCRED, &peer,
                 &size) != 0 || peer.pid <= 0 || peer.uid != getuid()) {
    return config;
  }
  const std::string path = "/proc/" + std::to_string(peer.pid) + "/cmdline";
  g_autofree gchar* raw = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(path.c_str(), &raw, &length, nullptr)) return config;
  std::string_view args(raw, length);
  const auto executable = args.substr(0, args.find('\0'));
  const auto basename = executable.substr(executable.find_last_of('/') + 1);
  if (basename != "gamescope" && basename != "gamescope-wl") {
    return config;
  }

  const auto next_argument = [&args]() {
    const auto argument = args.substr(0, args.find('\0'));
    args.remove_prefix(std::min(argument.size() + 1, args.size()));
    return argument;
  };
  next_argument();  // argv[0]
  bool steam = false;
  int server_count = 1;
  while (!args.empty()) {
    const auto argument = next_argument();
    if (argument == "--") break;
    const auto split = argument.find('=');
    const auto key = argument.substr(0, split);
    const auto value = [&]() {
      return split == std::string_view::npos ? next_argument()
                                           : argument.substr(split + 1);
    };
    const auto integer = [&](std::string_view number, int& destination) {
      if (number.empty()) return;
      int result;
      const auto end = number.data() + number.size();
      const auto conversion = std::from_chars(number.data(), end, result);
      if (conversion.ec == std::errc{} && conversion.ptr == end &&
          result > 0 && result <= 32767) {
        destination = result;
      }
    };
    if (key == "-w" || key == "--nested-width") {
      integer(value(), config.nested_width);
    } else if (key == "-h" || key == "--nested-height") {
      integer(value(), config.nested_height);
    } else if (key == "--xwayland-count") {
      integer(value(), server_count);
    } else if (key == "-e" || key == "--steam") {
      steam = true;
    } else if (key == "--max-scale") {
      const std::string number(value());
      char* end = nullptr;
      const double scale = g_ascii_strtod(number.c_str(), &end);
      if (end == number.c_str() + number.size() && scale > 0 &&
          std::isfinite(scale)) {
        config.max_auto_scale = scale;
      }
    }
  }
  config.resize_nested_height = steam && server_count > 1;
  return config;
}

}  // namespace

LinuxGamescopePointer::~LinuxGamescopePointer() {
  if (target_ != nullptr) gdk_display_close(target_);
  if (control_ != nullptr) gdk_display_close(control_);
}

bool LinuxGamescopePointer::in_session() {
  for (const char* variable : {"XDG_SESSION_DESKTOP", "XDG_CURRENT_DESKTOP"}) {
    const char* value = g_getenv(variable);
    if (value == nullptr) continue;
    for (std::string_view desktop(value); !desktop.empty();) {
      const auto separator = desktop.find(':');
      if (desktop.substr(0, separator) == "gamescope") return true;
      if (separator == std::string_view::npos) break;
      desktop.remove_prefix(separator + 1);
    }
  }
  return false;
}

bool LinuxGamescopePointer::move(double x, double y) {
  auto* app = gdk_display_get_default();
  if (app == nullptr || !GDK_IS_X11_DISPLAY(app)) return false;
  const auto app_number = display_number(gdk_display_get_name(app));
  if (!app_number) return false;
  Display* app_x11 = gdk_x11_display_get_xdisplay(app);
  const auto app_id = server_id(app_x11);
  if (!app_id || *app_id > static_cast<unsigned long>(*app_number)) return false;
  // SteamOS 按 server ID 顺序分配本地 XWayland 显示，控制属性只在 ID 0。
  const int control_number = *app_number - static_cast<int>(*app_id);
  if (*app_id != 0 && control_ == nullptr) control_ = open_display(control_number);
  auto* control = *app_id == 0 ? app : control_;
  if (control == nullptr) return false;
  Display* control_x11 = gdk_x11_display_get_xdisplay(control);
  if (server_id(control_x11) != 0) return false;

  const auto mouse_display =
      read_focus_display(control_x11, "GAMESCOPE_MOUSE_FOCUS_DISPLAY");
  if (!mouse_display || *mouse_display < control_number) return false;
  GdkDisplay* target = control;
  if (*mouse_display == *app_number) {
    target = app;
  } else if (*mouse_display != control_number) {
    if (target_ != nullptr &&
        display_number(gdk_display_get_name(target_)) != mouse_display) {
      gdk_display_close(target_);
      target_ = nullptr;
    }
    if (target_ == nullptr) target_ = open_display(*mouse_display);
    target = target_;
  }
  if (target == nullptr) return false;
  Display* target_x11 = gdk_x11_display_get_xdisplay(target);
  if (server_id(target_x11) != static_cast<unsigned long>(*mouse_display -
                                                        control_number)) {
    return false;
  }

  XWindowAttributes output{};
  if (!XGetWindowAttributes(control_x11, DefaultRootWindow(control_x11),
                            &output) || output.width <= 0 || output.height <= 0) {
    return false;
  }
  const auto base_display =
      read_focus_display(control_x11, "GAMESCOPE_FOCUS_DISPLAY");
  const auto base_window = read_cardinal(control_x11, "GAMESCOPE_FOCUSED_WINDOW");
  Window root = DefaultRootWindow(target_x11);
  Window window = root;
  if (base_display == mouse_display && base_window && *base_window != None) {
    window = *base_window;
  }

  XWindowAttributes bounds{};
  // 切换游戏时，刚读到的窗口可能已被销毁。
  gdk_x11_display_error_trap_push(target);
  const bool have_bounds = XGetWindowAttributes(target_x11, window, &bounds);
  const int geometry_error = gdk_x11_display_error_trap_pop(target);
  if (geometry_error != 0 || !have_bounds || bounds.map_state != IsViewable ||
      bounds.width <= 0 || bounds.height <= 0) {
    return false;
  }

  if (!scale_config_) scale_config_ = read_scale_config(control_x11);
  const auto modern = read_cardinal(control_x11, "GAMESCOPE_NEW_SCALING_SCALER");
  const auto legacy = modern && *modern <= static_cast<unsigned long>(Scaler::kStretch)
                          ? 0
                          : read_cardinal(control_x11, "GAMESCOPE_SCALING_FILTER").value_or(0);
  const auto scaler = window == root ? Scaler::kFit
                                     : select_scaler(modern, legacy);
  const auto scale = window_scale(*scale_config_, scaler, output.width,
                                  output.height, bounds.width, bounds.height);
  const double overscan = read_cardinal(control_x11, "STEAM_SCREEN_SCALE")
                              .value_or(0xffffffffUL) / 4294967295.0;
  if (overscan <= 0) return false;
  const int target_x = bounds.x + map_axis(x, output.width, bounds.width, scale.x * overscan);
  const int target_y = bounds.y + map_axis(y, output.height, bounds.height, scale.y * overscan);
  XWarpPointer(target_x11, None, root, 0, 0, 0, 0, target_x, target_y);
  // 按键走 uinput，先让 XWayland 处理定位，再处理后续鼠标按键。
  XSync(target_x11, False);
  return true;
}
