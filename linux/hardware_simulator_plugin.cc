#include "linux_text_input_setup.h"
#include "include/hardware_simulator/hardware_simulator_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <inputtino/input.hpp>
#include <sys/utsname.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "hardware_simulator_plugin_private.h"
#include "linux_edit_focus.h"
#include "linux_keyboard.h"
#include "linux_mouse.h"
#include "linux_pointer_capture.h"
#include "linux_text_input.h"
#include <dlfcn.h>

#define HARDWARE_SIMULATOR_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), hardware_simulator_plugin_get_type(), \
                              HardwareSimulatorPlugin))

struct _HardwareSimulatorPlugin {
  GObject parent_instance;
  LinuxEditFocus* edit_focus;
  LinuxPointerCapture* pointer_capture;
  uint64_t relative_sender;
  bool (*send_relative)(uint64_t, double, double);
  FlMethodChannel* channel;
};

G_DEFINE_TYPE(HardwareSimulatorPlugin, hardware_simulator_plugin, g_object_get_type())

namespace {

struct MonitorBounds {
  int x;
  int y;
  int width;
  int height;
};

enum class MouseMode {
  kRelative,
  kAbsolute,
};

std::mutex g_input_mutex;
std::mutex g_mouse_mutex;
LinuxKeyboard g_keyboard;
std::map<inputtino::Mouse::MOUSE_BUTTON, MouseMode> g_pressed_mouse_buttons;
std::unique_ptr<LinuxMouse> g_mouse;
std::string g_mouse_error;
MouseMode g_current_mouse_mode = MouseMode::kRelative;
int g_last_abs_x = 0;
int g_last_abs_y = 0;
int g_last_abs_width = 1;
int g_last_abs_height = 1;
// About 100 conventional wheel notches at 120 units per notch.
constexpr double kMaxLinuxWheelDistance = 12000.0;

FlMethodResponse* success_null() {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

FlMethodResponse* success_bool(bool value) {
  g_autoptr(FlValue) result = fl_value_new_bool(value);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

FlMethodResponse* success_int(int value) {
  g_autoptr(FlValue) result = fl_value_new_int(value);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

FlMethodResponse* bad_args(const char* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(
      "BAD_ARGS", message, nullptr));
}

FlMethodResponse* unsupported(const char* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(
      "UNSUPPORTED", message, nullptr));
}

FlMethodResponse* linux_display_error() {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(
      "DISPLAY_UNAVAILABLE",
      "Linux hardware simulation requires an X11 DISPLAY for monitor geometry.",
      nullptr));
}

FlMethodResponse* linux_mouse_error() {
  std::string message =
      "Linux mouse simulation requires permission to create uinput devices. "
      "Install linux/udev/rules.d/60-cloudplayplus-hardware-simulator.rules "
      "or grant the current user access to /dev/uinput.";
  if (!g_mouse_error.empty()) {
    message += " inputtino error: ";
    message += g_mouse_error;
  }
  return FL_METHOD_RESPONSE(fl_method_error_response_new(
      "UINPUT_UNAVAILABLE", message.c_str(), nullptr));
}

class XDisplay {
 public:
  XDisplay() : display_(XOpenDisplay(nullptr)) {}
  ~XDisplay() {
    if (display_ != nullptr) {
      XCloseDisplay(display_);
    }
  }

  XDisplay(const XDisplay&) = delete;
  XDisplay& operator=(const XDisplay&) = delete;

  Display* get() const { return display_; }

 private:
  Display* display_;
};

double get_double_arg(FlValue* args, const char* key, bool* ok) {
  if (args == nullptr) {
    *ok = false;
    return 0.0;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr) {
    *ok = false;
    return 0.0;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return fl_value_get_float(value);
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(value));
  }
  *ok = false;
  return 0.0;
}

int get_int_arg(FlValue* args, const char* key, bool* ok) {
  if (args == nullptr) {
    *ok = false;
    return 0;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    *ok = false;
    return 0;
  }
  return static_cast<int>(fl_value_get_int(value));
}

bool get_bool_arg(FlValue* args, const char* key, bool* ok) {
  if (args == nullptr) {
    *ok = false;
    return false;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
    *ok = false;
    return false;
  }
  return fl_value_get_bool(value);
}

std::vector<MonitorBounds> get_monitors(Display* display) {
  std::vector<MonitorBounds> monitors;
  Window root = DefaultRootWindow(display);
  int monitor_count = 0;
  XRRMonitorInfo* xrr_monitors =
      XRRGetMonitors(display, root, True, &monitor_count);
  if (xrr_monitors != nullptr) {
    for (int i = 0; i < monitor_count; ++i) {
      if (xrr_monitors[i].noutput <= 0) {
        continue;
      }
      monitors.push_back({xrr_monitors[i].x, xrr_monitors[i].y,
                          xrr_monitors[i].width, xrr_monitors[i].height});
    }
    XRRFreeMonitors(xrr_monitors);
  }

  if (monitors.empty()) {
    int screen = DefaultScreen(display);
    monitors.push_back({0, 0, DisplayWidth(display, screen),
                        DisplayHeight(display, screen)});
  }
  return monitors;
}

MonitorBounds get_root_bounds(const std::vector<MonitorBounds>& monitors) {
  if (monitors.empty()) {
    return {0, 0, 1, 1};
  }
  int left = monitors.front().x;
  int top = monitors.front().y;
  int right = monitors.front().x + monitors.front().width;
  int bottom = monitors.front().y + monitors.front().height;
  for (const auto& monitor : monitors) {
    left = std::min(left, monitor.x);
    top = std::min(top, monitor.y);
    right = std::max(right, monitor.x + monitor.width);
    bottom = std::max(bottom, monitor.y + monitor.height);
  }
  return {left, top, std::max(1, right - left), std::max(1, bottom - top)};
}

LinuxMouse* get_mouse() {
  std::lock_guard<std::mutex> lock(g_mouse_mutex);
  if (g_mouse) {
    return g_mouse.get();
  }

  auto mouse = inputtino::Mouse::create({
      .name = "CloudPlayPlus Mouse passthrough",
      .vendor_id = 0xBEEF,
      .product_id = 0xDEAD,
      .version = 0x111,
  });
  if (!mouse) {
    g_mouse_error = mouse.getErrorMessage();
    return nullptr;
  }

  g_mouse = std::make_unique<LinuxMouse>(std::move(*mouse));
  g_mouse_error.clear();
  return g_mouse.get();
}

void set_mouse_mode(inputtino::Mouse* mouse, MouseMode mode) {
  if (mode == MouseMode::kAbsolute) {
    mouse->move_abs(g_last_abs_x, g_last_abs_y, g_last_abs_width,
                    g_last_abs_height);
  } else {
    mouse->move(0, 0);
  }
  g_current_mouse_mode = mode;
}

bool mouse_button_to_inputtino(int button_id,
                               inputtino::Mouse::MOUSE_BUTTON* button) {
  switch (button_id) {
    case 1:
      *button = inputtino::Mouse::LEFT;
      return true;
    case 2:
      *button = inputtino::Mouse::MIDDLE;
      return true;
    case 3:
      *button = inputtino::Mouse::RIGHT;
      return true;
    case 4:
      *button = inputtino::Mouse::SIDE;
      return true;
    case 5:
      *button = inputtino::Mouse::EXTRA;
      return true;
    default:
      return false;
  }
}

FlMethodResponse* perform_key_event(FlValue* args) {
  bool ok = true;
  int code = get_int_arg(args, "code", &ok);
  bool is_down = get_bool_arg(args, "isDown", &ok);
  if (!ok) {
    return bad_args("Missing or incorrect arguments for KeyPress");
  }

  if (!LinuxKeyboard::keycode(code)) {
    return unsupported("Unsupported Windows virtual-key code.");
  }
  std::lock_guard<std::mutex> lock(g_input_mutex);
  const int result = g_keyboard.send(code, is_down);
  if (result < 0) {
    const std::string message =
        std::string("Linux keyboard requires /dev/uinput access: ") +
        std::strerror(-result);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "UINPUT_UNAVAILABLE", message.c_str(), nullptr));
  }
  return success_null();
}

FlMethodResponse* perform_mouse_move_relative(FlValue* args) {
  bool ok = true;
  double x = get_double_arg(args, "x", &ok);
  double y = get_double_arg(args, "y", &ok);
  (void)get_int_arg(args, "screenId", &ok);
  if (!ok) {
    return bad_args("Missing or incorrect arguments for mouseMoveR");
  }

  auto* mouse = get_mouse();
  if (mouse == nullptr) {
    return linux_mouse_error();
  }
  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    mouse->move(static_cast<int>(std::round(x)),
                static_cast<int>(std::round(y)));
    g_current_mouse_mode = MouseMode::kRelative;
  }
  return success_null();
}

FlMethodResponse* perform_mouse_move_absolute(FlValue* args) {
  bool ok = true;
  double x = get_double_arg(args, "x", &ok);
  double y = get_double_arg(args, "y", &ok);
  int screen_id = get_int_arg(args, "screenId", &ok);
  if (!ok) {
    return bad_args("Missing or incorrect arguments for mouseMoveA");
  }

  auto* mouse = get_mouse();
  if (mouse == nullptr) {
    return linux_mouse_error();
  }

  XDisplay display;
  if (display.get() == nullptr) {
    return linux_display_error();
  }
  auto monitors = get_monitors(display.get());
  if (screen_id < 0 || screen_id >= static_cast<int>(monitors.size())) {
    return bad_args("Invalid screenId for mouseMoveA");
  }
  const auto root = get_root_bounds(monitors);
  const auto& monitor = monitors[screen_id];
  x = std::max(0.0, std::min(1.0, x));
  y = std::max(0.0, std::min(1.0, y));
  int target_x =
      monitor.x - root.x + static_cast<int>(std::round(x * (monitor.width - 1)));
  int target_y =
      monitor.y - root.y + static_cast<int>(std::round(y * (monitor.height - 1)));
  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    mouse->move_abs(target_x, target_y, root.width, root.height);
    g_current_mouse_mode = MouseMode::kAbsolute;
    g_last_abs_x = target_x;
    g_last_abs_y = target_y;
    g_last_abs_width = root.width;
    g_last_abs_height = root.height;
  }
  return success_null();
}

FlMethodResponse* perform_mouse_button(FlValue* args) {
  bool ok = true;
  int button_id = get_int_arg(args, "buttonId", &ok);
  bool is_down = get_bool_arg(args, "isDown", &ok);
  if (!ok) {
    return bad_args("Missing or incorrect arguments for mousePress");
  }
  inputtino::Mouse::MOUSE_BUTTON button;
  if (!mouse_button_to_inputtino(button_id, &button)) {
    return unsupported("Unsupported mouse button id.");
  }

  auto* mouse = get_mouse();
  if (mouse == nullptr) {
    return linux_mouse_error();
  }
  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    if (is_down) {
      g_pressed_mouse_buttons[button] = g_current_mouse_mode;
      mouse->press(button);
    } else {
      auto pressed_button = g_pressed_mouse_buttons.find(button);
      if (pressed_button != g_pressed_mouse_buttons.end()) {
        set_mouse_mode(mouse, pressed_button->second);
        g_pressed_mouse_buttons.erase(pressed_button);
      }
      mouse->release(button);
    }
  }
  return success_null();
}

FlMethodResponse* perform_mouse_scroll(FlValue* args) {
  bool ok = true;
  double dx = get_double_arg(args, "dx", &ok);
  double dy = get_double_arg(args, "dy", &ok);
  if (!ok) {
    return bad_args("Missing or incorrect arguments for mouseScroll");
  }

  auto* mouse = get_mouse();
  if (mouse == nullptr) {
    return linux_mouse_error();
  }

  int vertical_distance = logical_scroll_to_linux_wheel(dy, true);
  int horizontal_distance = logical_scroll_to_linux_wheel(dx, false);
  if (vertical_distance != 0) {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    mouse->vertical_scroll(vertical_distance);
  }
  if (horizontal_distance != 0) {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    mouse->horizontal_scroll(horizontal_distance);
  }
  return success_null();
}

FlMethodResponse* get_monitor_count() {
  XDisplay display;
  if (display.get() == nullptr) {
    return linux_display_error();
  }
  return success_int(static_cast<int>(get_monitors(display.get()).size()));
}

FlMethodResponse* clear_all_pressed_mouse_buttons() {
  std::map<inputtino::Mouse::MOUSE_BUTTON, MouseMode> buttons;
  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    buttons.swap(g_pressed_mouse_buttons);
  }
  if (buttons.empty()) {
    return nullptr;
  }
  auto* mouse = get_mouse();
  if (mouse == nullptr) {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    g_pressed_mouse_buttons.insert(buttons.begin(), buttons.end());
    return linux_mouse_error();
  }
  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    for (const auto& button : buttons) {
      set_mouse_mode(mouse, button.second);
      mouse->release(button.first);
    }
  }
  return nullptr;
}

FlMethodResponse* clear_all_pressed_events() {
  // 一个设备清理失败也必须尝试释放另一个设备。
  auto* mouse_error = clear_all_pressed_mouse_buttons();
  std::lock_guard<std::mutex> lock(g_input_mutex);
  const int result = g_keyboard.clear();
  if (mouse_error) return mouse_error;
  if (result < 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "UINPUT_UNAVAILABLE", std::strerror(-result), nullptr));
  }
  return success_null();
}

}  // namespace

int logical_scroll_to_linux_wheel(double delta, bool invert) {
  if (!std::isfinite(delta)) {
    return 0;
  }
  const double direction = invert ? -1.0 : 1.0;
  const double native_distance = (std::clamp)(
      delta * direction, -kMaxLinuxWheelDistance, kMaxLinuxWheelDistance);
  return static_cast<int>(std::lround(native_distance));
}

// Called when a method call is received from Flutter.
static void hardware_simulator_plugin_handle_method_call(
    HardwareSimulatorPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    response = get_platform_version();
  } else if (strcmp(method, "startTextInputDecisionCapture") == 0) {
    response = success_bool(self->edit_focus->start());
  } else if (strcmp(method, "stopTextInputDecisionCapture") == 0) {
    self->edit_focus->stop();
    response = success_null();
  } else if (strcmp(method, "isLinuxEditFocusAvailable") == 0) {
    response = success_bool(self->edit_focus->available());
  } else if (strcmp(method, "getMonitorCount") == 0) {
    response = get_monitor_count();
  } else if (strcmp(method, "getLinuxTextInputSetup") == 0) {
    g_autoptr(GSettings) settings = linux_text_input_setup::open_settings();
    const auto value = settings ? linux_text_input_setup::current(settings) : "";
    const bool other = linux_text_input_setup::competing_input_method() ||
        (!value.empty() && value != "'ibus'" && value != "'gtk-im-context-simple'");
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "gnome", fl_value_new_bool(
        linux_text_input_setup::supported_desktop()));
    fl_value_set_string_take(result, "writable", fl_value_new_bool(
        settings && g_settings_is_writable(settings, "overrides")));
    fl_value_set_string_take(result, "otherInputMethod", fl_value_new_bool(other));
    fl_value_set_string_take(result, "override", fl_value_new_string(value.c_str()));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "setLinuxTextInputSetup") == 0) {
    auto* args = fl_method_call_get_args(method_call);
    const bool map = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP;
    auto* expected = map ? fl_value_lookup_string(args, "expected") : nullptr;
    auto* value = map ? fl_value_lookup_string(args, "value") : nullptr;
    g_autoptr(GSettings) settings = linux_text_input_setup::open_settings();
    if (!expected || !value || fl_value_get_type(expected) != FL_VALUE_TYPE_STRING ||
        fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
      response = bad_args("Invalid input method settings.");
    } else {
      response = success_bool(settings && linux_text_input_setup::supported_desktop() &&
          linux_text_input_setup::replace(settings, fl_value_get_string(expected),
                                         fl_value_get_string(value)));
    }
  } else if (strcmp(method, "isLinuxTextInputAvailable") == 0) {
    g_object_ref(method_call);
    linux_text_input::available([method_call](bool available) {
      // 文本可用但编辑键不可用时，不对 Viewer 声明完整输入能力。
      g_autoptr(FlMethodResponse) response = success_bool(
          available && g_keyboard.initialize() == 0);
      fl_method_call_respond(method_call, response, nullptr);
      g_object_unref(method_call);
    });
    return;
  } else if (strcmp(method, "prepareLinuxTextInput") == 0) {
    g_object_ref(method_call);
    linux_text_input::prepare([method_call](uint64_t token) {
      g_autoptr(FlValue) value = fl_value_new_int(token);
      g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
          fl_method_success_response_new(value));
      fl_method_call_respond(method_call, response, nullptr);
      g_object_unref(method_call);
    });
    return;
  } else if (strcmp(method, "finishLinuxTextInput") == 0 ||
             strcmp(method, "performTextInput") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    const bool is_map = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP;
    FlValue* text = is_map ? fl_value_lookup_string(args, "text") : nullptr;
    bool ok = text && fl_value_get_type(text) == FL_VALUE_TYPE_STRING;
    const bool prepared = strcmp(method, "finishLinuxTextInput") == 0;
    int64_t backspaces = 0, token = 0;
    if (prepared) {
      FlValue* count = is_map ? fl_value_lookup_string(args, "backspaces") : nullptr;
      FlValue* id = is_map ? fl_value_lookup_string(args, "token") : nullptr;
      ok = ok && count && id && fl_value_get_type(count) == FL_VALUE_TYPE_INT &&
          fl_value_get_type(id) == FL_VALUE_TYPE_INT;
      if (ok) {
        backspaces = fl_value_get_int(count);
        token = fl_value_get_int(id);
        ok = token > 0;
      }
    }
    const std::string value = ok ? linux_committed_text_value(text) : std::string();
    if (!ok || !linux_text_input::valid_text(value) ||
        backspaces < 0 || backspaces > 4096) {
      response = bad_args("Invalid committed text edit.");
    } else {
      g_object_ref(method_call);
      auto finish = [method_call, backspaces, value](uint64_t token) {
        linux_text_input::finish(token, backspaces, value, [method_call](bool ok) {
          g_autoptr(FlMethodResponse) response = ok ? success_null() :
              FL_METHOD_RESPONSE(fl_method_error_response_new(
                  "TEXT_INPUT_UNAVAILABLE", "IBus text transaction failed.", nullptr));
          fl_method_call_respond(method_call, response, nullptr);
          g_object_unref(method_call);
        });
      };
      if (prepared) finish(token);
      else linux_text_input::available([finish](bool available) {
        if (available) linux_text_input::prepare(finish);
        else finish(0);
      });
      return;
    }
  } else if (strcmp(method, "KeyPress") == 0) {
    response = perform_key_event(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "mouseMoveR") == 0) {
    response = perform_mouse_move_relative(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "mouseMoveA") == 0) {
    response = perform_mouse_move_absolute(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "mousePress") == 0) {
    auto* args = fl_method_call_get_args(method_call);
    response = perform_mouse_button(args);
    bool ok = true;
    const int button = get_int_arg(args, "buttonId", &ok);
    const bool down = get_bool_arg(args, "isDown", &ok);
    auto* request = ok ? fl_value_lookup_string(args, "editFocusRequestId") : nullptr;
    if (ok && button == 1 && !down && request &&
        fl_value_get_type(request) == FL_VALUE_TYPE_INT &&
        FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
      XDisplay display;
      Window root, child;
      int x, y, wx, wy;
      unsigned int mask;
      if (display.get() && XQueryPointer(display.get(),
          DefaultRootWindow(display.get()), &root, &child, &x, &y, &wx, &wy, &mask)) {
        self->edit_focus->inspect(fl_value_get_int(request), x, y,
            [self](int64_t id, bool active, bool secure) {
          if (!self->channel) return;
          g_autoptr(FlValue) message = fl_value_new_map();
          fl_value_set_string_take(message, "active", fl_value_new_bool(active));
          fl_value_set_string_take(message, "secure",
              active ? fl_value_new_bool(secure) : fl_value_new_null());
          fl_value_set_string_take(message, "editFocusRequestId", fl_value_new_int(id));
          fl_method_channel_invoke_method(self->channel, "onTextInputDecision",
              message, nullptr, nullptr, nullptr);
        });
      }
    }
  } else if (strcmp(method, "mouseScroll") == 0) {
    response = perform_mouse_scroll(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "clearAllPressedEvents") == 0) {
    response = clear_all_pressed_events();
  } else if (strcmp(method, "isLinuxPointerCaptureSupported") == 0) {
    response = success_bool(self->pointer_capture && self->pointer_capture->supported());
  } else if (strcmp(method, "lockCursor") == 0) {
    auto* args = fl_method_call_get_args(method_call);
    auto* id = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
        ? fl_value_lookup_string(args, "generation") : nullptr;
    if (!id || fl_value_get_type(id) != FL_VALUE_TYPE_INT || !self->pointer_capture) {
      response = bad_args("Linux capture requires a generation and a view");
    } else {
      auto *sender_value = fl_value_lookup_string(args, "relativeSender");
      const uint64_t sender =
          sender_value && fl_value_get_type(sender_value) == FL_VALUE_TYPE_INT
              ? fl_value_get_int(sender_value)
              : 0;
      auto valid = reinterpret_cast<bool (*)(uint64_t)>(
          dlsym(RTLD_DEFAULT, "cpp_locked_cursor_valid_v1"));
      auto send = reinterpret_cast<bool (*)(uint64_t, double, double)>(
          dlsym(RTLD_DEFAULT, "cpp_locked_cursor_move_v1"));
      if (sender && (!valid || !send || !valid(sender))) {
        // Dart 已切到新 generation；失败也必须释放无法再被旧 id 解锁的捕获。
        self->pointer_capture->unlock("invalid_sender");
        self->relative_sender = 0;
        response = bad_args("Native relative sender is unavailable");
      } else {
        const auto error = self->pointer_capture->lock(fl_value_get_int(id));
        if (error.empty()) {
          self->relative_sender = sender;
          self->send_relative = send;
        }
        response = error.empty()
                       ? success_null()
                       : FL_METHOD_RESPONSE(fl_method_error_response_new(
                             "POINTER_CAPTURE_FAILED", error.c_str(), nullptr));
      }
    }
  } else if (strcmp(method, "unlockCursor") == 0) {
    auto* args = fl_method_call_get_args(method_call);
    auto* id = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
        ? fl_value_lookup_string(args, "generation") : nullptr;
    if (self->pointer_capture && id && fl_value_get_type(id) == FL_VALUE_TYPE_INT)
      self->pointer_capture->unlock_generation(fl_value_get_int(id));
    response = success_null();
  } else if (strcmp(method, "mouseMoveToWindowPosition") == 0) {
    response = success_null();
  } else if (strcmp(method, "isRunningAsSystem") == 0) {
    response = success_bool(true);
  } else if (strcmp(method, "setPrimaryDisplay") == 0) {
    response = success_bool(false);
  } else if (strcmp(method, "touchEvent") == 0 ||
             strcmp(method, "touchMove") == 0 ||
             strcmp(method, "penEvent") == 0 ||
             strcmp(method, "penMove") == 0 ||
             strcmp(method, "penHover") == 0 ||
             strcmp(method, "hookCursorImage") == 0 ||
             strcmp(method, "unhookCursorImage") == 0 ||
             strcmp(method, "hookCursorPosition") == 0 ||
             strcmp(method, "unhookCursorPosition") == 0 ||
             strcmp(method, "addDisplayCountChangedCallback") == 0 ||
             strcmp(method, "removeDisplayCountChangedCallback") == 0) {
    response = success_null();
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void hardware_simulator_plugin_dispose(GObject* object) {
  auto* self = HARDWARE_SIMULATOR_PLUGIN(object);
  delete self->pointer_capture;
  self->pointer_capture = nullptr;
  delete self->edit_focus;
  self->edit_focus = nullptr;
  if (self->channel) g_object_remove_weak_pointer(G_OBJECT(self->channel),
      reinterpret_cast<gpointer*>(&self->channel));
  self->channel = nullptr;
  G_OBJECT_CLASS(hardware_simulator_plugin_parent_class)->dispose(object);
}

static void hardware_simulator_plugin_class_init(HardwareSimulatorPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = hardware_simulator_plugin_dispose;
}

static void hardware_simulator_plugin_init(HardwareSimulatorPlugin* self) {
  self->edit_focus = new LinuxEditFocus();
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  HardwareSimulatorPlugin* plugin = HARDWARE_SIMULATOR_PLUGIN(user_data);
  hardware_simulator_plugin_handle_method_call(plugin, method_call);
}

void hardware_simulator_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  HardwareSimulatorPlugin* plugin = HARDWARE_SIMULATOR_PLUGIN(
      g_object_new(hardware_simulator_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "hardware_simulator",
                            FL_METHOD_CODEC(codec));
  plugin->channel = channel;
  auto* view = fl_plugin_registrar_get_view(registrar);
  if (view)
    plugin->pointer_capture = new LinuxPointerCapture(
        GTK_WIDGET(view),
        [plugin](int64_t generation, bool locked, const char *reason) {
          if (!locked)
            plugin->relative_sender = 0;
          if (!plugin->channel)
            return;
          g_autoptr(FlValue) args = fl_value_new_map();
          fl_value_set_string_take(args, "generation",
                                   fl_value_new_int(generation));
          fl_value_set_string_take(args, "locked", fl_value_new_bool(locked));
          fl_value_set_string_take(args, "reason", fl_value_new_string(reason));
          fl_method_channel_invoke_method(plugin->channel,
                                          "onLinuxPointerCapture", args,
                                          nullptr, nullptr, nullptr);
        },
        [plugin](int64_t generation, double dx, double dy) {
          if (plugin->relative_sender && plugin->send_relative) {
            plugin->send_relative(plugin->relative_sender, dx, dy);
            return; // 无效/关闭也丢弃，不回流 Dart 重发。
          }
          if (!plugin->channel)
            return;
          g_autoptr(FlValue) args = fl_value_new_map();
          fl_value_set_string_take(args, "generation",
                                   fl_value_new_int(generation));
          fl_value_set_string_take(args, "dx", fl_value_new_float(dx));
          fl_value_set_string_take(args, "dy", fl_value_new_float(dy));
          fl_method_channel_invoke_method(plugin->channel,
                                          "onLinuxPointerMotion", args, nullptr,
                                          nullptr, nullptr);
        });
  g_object_add_weak_pointer(G_OBJECT(channel), reinterpret_cast<gpointer*>(&plugin->channel));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
