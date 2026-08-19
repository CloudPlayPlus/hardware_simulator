#include "include/hardware_simulator/hardware_simulator_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <inputtino/input.hpp>
#include <sys/utsname.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xrandr.h>
#include <X11/keysym.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "hardware_simulator_plugin_private.h"

#define HARDWARE_SIMULATOR_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), hardware_simulator_plugin_get_type(), \
                              HardwareSimulatorPlugin))

struct _HardwareSimulatorPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(HardwareSimulatorPlugin, hardware_simulator_plugin, g_object_get_type())

namespace {

struct MonitorBounds {
  int x;
  int y;
  int width;
  int height;
  std::string platform_display_id;
  int64_t display_uid = 0;
  bool is_primary = false;
};

enum class MouseMode {
  kRelative,
  kAbsolute,
};

std::mutex g_input_mutex;
std::mutex g_mouse_mutex;
std::set<KeyCode> g_pressed_keys;
std::map<inputtino::Mouse::MOUSE_BUTTON, MouseMode> g_pressed_mouse_buttons;
std::unique_ptr<inputtino::Mouse> g_mouse;
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
      "Linux hardware simulation requires an X11 DISPLAY with XTest support.",
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

  bool supports_xtest() const {
    if (display_ == nullptr) {
      return false;
    }
    int event_base = 0;
    int error_base = 0;
    int major = 0;
    int minor = 0;
    return XTestQueryExtension(display_, &event_base, &error_base, &major,
                               &minor) == True;
  }

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
      char* atom_name = XGetAtomName(display, xrr_monitors[i].name);
      std::string monitor_name = atom_name != nullptr
                                     ? std::string(atom_name)
                                     : "monitor-" + std::to_string(i);
      if (atom_name != nullptr) {
        XFree(atom_name);
      }
      monitors.push_back({xrr_monitors[i].x, xrr_monitors[i].y,
                          xrr_monitors[i].width, xrr_monitors[i].height,
                          monitor_name,
                          static_cast<int64_t>(xrr_monitors[i].name),
                          xrr_monitors[i].primary == True});
    }
    XRRFreeMonitors(xrr_monitors);
  }

  if (monitors.empty()) {
    int screen = DefaultScreen(display);
    monitors.push_back({0, 0, DisplayWidth(display, screen),
                        DisplayHeight(display, screen),
                        "x11-root-" + std::to_string(screen), screen, true});
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

inputtino::Mouse* get_mouse() {
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

  g_mouse = std::make_unique<inputtino::Mouse>(std::move(*mouse));
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

KeySym windows_vk_to_keysym(int vk) {
  if (vk >= 0x41 && vk <= 0x5A) {
    return XK_a + (vk - 0x41);
  }
  if (vk >= 0x30 && vk <= 0x39) {
    return XK_0 + (vk - 0x30);
  }
  if (vk >= 0x70 && vk <= 0x7B) {
    return XK_F1 + (vk - 0x70);
  }
  if (vk >= 0x60 && vk <= 0x69) {
    return XK_KP_0 + (vk - 0x60);
  }

  switch (vk) {
    case 0x08: return XK_BackSpace;
    case 0x09: return XK_Tab;
    case 0x0D: return XK_Return;
    case 0x14: return XK_Caps_Lock;
    case 0x1B: return XK_Escape;
    case 0x20: return XK_space;
    case 0x21: return XK_Page_Up;
    case 0x22: return XK_Page_Down;
    case 0x23: return XK_End;
    case 0x24: return XK_Home;
    case 0x25: return XK_Left;
    case 0x26: return XK_Up;
    case 0x27: return XK_Right;
    case 0x28: return XK_Down;
    case 0x2D: return XK_Insert;
    case 0x2E: return XK_Delete;
    case 0x5B: return XK_Super_L;
    case 0x5C: return XK_Super_R;
    case 0x5D: return XK_Menu;
    case 0x6A: return XK_KP_Multiply;
    case 0x6B: return XK_KP_Add;
    case 0x6D: return XK_KP_Subtract;
    case 0x6E: return XK_KP_Decimal;
    case 0x6F: return XK_KP_Divide;
    case 0xA0: return XK_Shift_L;
    case 0xA1: return XK_Shift_R;
    case 0xA2: return XK_Control_L;
    case 0xA3: return XK_Control_R;
    case 0xA4: return XK_Alt_L;
    case 0xA5: return XK_Alt_R;
    case 0xBA: return XK_semicolon;
    case 0xBB: return XK_equal;
    case 0xBC: return XK_comma;
    case 0xBD: return XK_minus;
    case 0xBE: return XK_period;
    case 0xBF: return XK_slash;
    case 0xC0: return XK_grave;
    case 0xDB: return XK_bracketleft;
    case 0xDC: return XK_backslash;
    case 0xDD: return XK_bracketright;
    case 0xDE: return XK_apostrophe;
    default: return NoSymbol;
  }
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

  XDisplay display;
  if (!display.supports_xtest()) {
    return linux_display_error();
  }
  KeySym keysym = windows_vk_to_keysym(code);
  if (keysym == NoSymbol) {
    return unsupported("Unsupported Windows virtual-key code.");
  }
  KeyCode keycode = XKeysymToKeycode(display.get(), keysym);
  if (keycode == 0) {
    return unsupported("No X11 keycode for requested key.");
  }

  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    if (is_down) {
      g_pressed_keys.insert(keycode);
    } else {
      g_pressed_keys.erase(keycode);
    }
  }
  XTestFakeKeyEvent(display.get(), keycode, is_down ? True : False,
                    CurrentTime);
  XFlush(display.get());
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

FlMethodResponse* get_display_list() {
  XDisplay display;
  if (display.get() == nullptr) {
    return linux_display_error();
  }
  const auto monitors = get_monitors(display.get());
  g_autoptr(FlValue) list = fl_value_new_list();
  for (size_t index = 0; index < monitors.size(); ++index) {
    const auto& monitor = monitors[index];
    const int64_t input_screen_id = static_cast<int64_t>(index);
    g_autoptr(FlValue) item = fl_value_new_map();
    fl_value_set_string_take(item, "index", fl_value_new_int(input_screen_id));
    fl_value_set_string_take(item, "width", fl_value_new_int(monitor.width));
    fl_value_set_string_take(item, "height", fl_value_new_int(monitor.height));
    fl_value_set_string_take(item, "refreshRate", fl_value_new_int(60));
    fl_value_set_string_take(item, "isVirtual", fl_value_new_bool(false));
    fl_value_set_string_take(
        item, "displayName",
        fl_value_new_string(monitor.platform_display_id.c_str()));
    fl_value_set_string_take(
        item, "deviceName",
        fl_value_new_string(monitor.platform_display_id.c_str()));
    fl_value_set_string_take(item, "active", fl_value_new_bool(true));
    fl_value_set_string_take(item, "displayUid",
                             fl_value_new_int(monitor.display_uid));
    fl_value_set_string_take(item, "orientation", fl_value_new_int(0));
    fl_value_set_string_take(item, "left", fl_value_new_int(monitor.x));
    fl_value_set_string_take(item, "top", fl_value_new_int(monitor.y));
    fl_value_set_string_take(item, "right",
                             fl_value_new_int(monitor.x + monitor.width));
    fl_value_set_string_take(item, "bottom",
                             fl_value_new_int(monitor.y + monitor.height));
    fl_value_set_string_take(item, "isPrimary",
                             fl_value_new_bool(monitor.is_primary));
    fl_value_set_string_take(
        item, "platformDisplayId",
        fl_value_new_string(monitor.platform_display_id.c_str()));
    fl_value_set_string_take(item, "inputScreenId",
                             fl_value_new_int(input_screen_id));
    fl_value_append_take(list, fl_value_ref(item));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
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
  if (auto* mouse_error = clear_all_pressed_mouse_buttons()) {
    return mouse_error;
  }

  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    if (g_pressed_keys.empty()) {
      return success_null();
    }
  }

  XDisplay display;
  if (!display.supports_xtest()) {
    return linux_display_error();
  }

  std::set<KeyCode> keys;
  {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    keys.swap(g_pressed_keys);
  }
  for (KeyCode key : keys) {
    XTestFakeKeyEvent(display.get(), key, False, CurrentTime);
  }
  XFlush(display.get());
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
  } else if (strcmp(method, "getMonitorCount") == 0) {
    response = get_monitor_count();
  } else if (strcmp(method, "getAllDisplays") == 0) {
    response = get_monitor_count();
  } else if (strcmp(method, "getDisplayList") == 0) {
    response = get_display_list();
  } else if (strcmp(method, "KeyPress") == 0) {
    response = perform_key_event(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "mouseMoveR") == 0) {
    response = perform_mouse_move_relative(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "mouseMoveA") == 0) {
    response = perform_mouse_move_absolute(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "mousePress") == 0) {
    response = perform_mouse_button(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "mouseScroll") == 0) {
    response = perform_mouse_scroll(fl_method_call_get_args(method_call));
  } else if (strcmp(method, "clearAllPressedEvents") == 0) {
    response = clear_all_pressed_events();
  } else if (strcmp(method, "lockCursor") == 0 ||
             strcmp(method, "unlockCursor") == 0 ||
             strcmp(method, "mouseMoveToWindowPosition") == 0) {
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
  G_OBJECT_CLASS(hardware_simulator_plugin_parent_class)->dispose(object);
}

static void hardware_simulator_plugin_class_init(HardwareSimulatorPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = hardware_simulator_plugin_dispose;
}

static void hardware_simulator_plugin_init(HardwareSimulatorPlugin* self) {}

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
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
