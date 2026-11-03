#include "linux_pointer_capture.h"
#include <gdk/gdkx.h>
#include <gdk/gdkwayland.h>
#include <X11/extensions/XInput2.h>
#include <wayland-client.h>
#include "pointer-constraints-client.h"
#include "relative-pointer-client.h"
#include <cmath>
#include <utility>
#include <map>
#ifdef CPP_LOG_AVAILABLE
#include <cpp_log/cpp_log.h>
#else
#define CPPLOG_INFO(...) ((void)0)
#endif

struct LinuxPointerCapture::Impl {
  GtkWidget* view;
  GtkWidget* top = nullptr;
  State state;
  Motion motion;
  int64_t generation = 0;
  bool requested = false;
  bool active = false;
  guint timeout = 0;
  gulong focus_handler = 0, unmap_handler = 0, destroy_handler = 0;
  GdkWindow* window = nullptr;
  GdkCursor* saved_cursor = nullptr;
  Display* raw_display = nullptr;
  guint raw_source = 0;
  int xi_opcode = 0;
  std::map<int, bool> relative_devices;
  bool grabbed = false;
  bool cursor_hidden = false;
  wl_registry* registry = nullptr;
  zwp_pointer_constraints_v1* constraints = nullptr;
  zwp_relative_pointer_manager_v1* relative_manager = nullptr;
  zwp_locked_pointer_v1* locked = nullptr;
  zwp_relative_pointer_v1* relative = nullptr;
  uint32_t constraints_name = 0, relative_name = 0;

  Impl(GtkWidget* v, State s, Motion m)
      : view(v), state(std::move(s)), motion(std::move(m)) {
    g_object_add_weak_pointer(G_OBJECT(view), reinterpret_cast<gpointer*>(&view));
  }
  ~Impl() {
    release("disposed");
    if (top) {
      g_signal_handler_disconnect(top, focus_handler);
      g_signal_handler_disconnect(top, unmap_handler);
      g_signal_handler_disconnect(top, destroy_handler);
      g_object_remove_weak_pointer(G_OBJECT(top), reinterpret_cast<gpointer*>(&top));
    }
    if (relative_manager) zwp_relative_pointer_manager_v1_destroy(relative_manager);
    if (constraints) zwp_pointer_constraints_v1_destroy(constraints);
    if (registry) wl_registry_destroy(registry);
    if (view) g_object_remove_weak_pointer(G_OBJECT(view), reinterpret_cast<gpointer*>(&view));
  }
  void hide() {
    if (cursor_hidden) return;
    cursor_hidden = true;
    saved_cursor = gdk_window_get_cursor(window);
    if (saved_cursor) g_object_ref(saved_cursor);
    GdkCursor* blank = gdk_cursor_new_for_display(gdk_window_get_display(window), GDK_BLANK_CURSOR);
    gdk_window_set_cursor(window, blank);
    g_object_unref(blank);
  }
  void confirm() {
    if (!requested || active) return;
    active = true;
    hide();
    CPPLOG_INFO("POINTER_CAPTURE", "locked generation=%lld", static_cast<long long>(generation));
    if (timeout) { g_source_remove(timeout); timeout = 0; }
    state(generation, true, "locked");
  }
  void release(const char* reason) {
    const bool notify = requested;
    requested = active = false;
    relative_devices.clear();
    if (timeout) { g_source_remove(timeout); timeout = 0; }
    if (locked) { zwp_locked_pointer_v1_destroy(locked); locked = nullptr; }
    if (relative) { zwp_relative_pointer_v1_destroy(relative); relative = nullptr; }
    if (grabbed && window) {
      XUngrabPointer(GDK_DISPLAY_XDISPLAY(gdk_window_get_display(window)), CurrentTime);
      gdk_display_flush(gdk_window_get_display(window));
      grabbed = false;
    }
    if (raw_source) { g_source_remove(raw_source); raw_source = 0; }
    if (raw_display) { XCloseDisplay(raw_display); raw_display = nullptr; }
    if (window) {
      if (cursor_hidden && !gdk_window_is_destroyed(window)) gdk_window_set_cursor(window, saved_cursor);
      cursor_hidden = false;
      g_clear_object(&saved_cursor);
      g_clear_object(&window);
    }
    if (notify) {
      CPPLOG_INFO("POINTER_CAPTURE", "released generation=%lld reason=%s", static_cast<long long>(generation), reason);
      state(generation, false, reason);
    }
  }
  static void global(void* data, wl_registry* r, uint32_t name, const char* interface, uint32_t) {
    auto* s = static_cast<Impl*>(data);
    if (g_str_equal(interface, zwp_pointer_constraints_v1_interface.name)) {
      s->constraints = static_cast<zwp_pointer_constraints_v1*>(wl_registry_bind(r, name, &zwp_pointer_constraints_v1_interface, 1));
      s->constraints_name = name;
    } else if (g_str_equal(interface, zwp_relative_pointer_manager_v1_interface.name)) {
      s->relative_manager = static_cast<zwp_relative_pointer_manager_v1*>(wl_registry_bind(r, name, &zwp_relative_pointer_manager_v1_interface, 1));
      s->relative_name = name;
    }
  }
  static void removed(void* data, wl_registry*, uint32_t name) {
    auto* s = static_cast<Impl*>(data);
    if (name == s->constraints_name || name == s->relative_name) {
      s->release("unsupported");
      if (name == s->constraints_name && s->constraints) {
        zwp_pointer_constraints_v1_destroy(s->constraints); s->constraints = nullptr;
      }
      if (name == s->relative_name && s->relative_manager) {
        zwp_relative_pointer_manager_v1_destroy(s->relative_manager); s->relative_manager = nullptr;
      }
    }
  }
  bool supported() {
    if (!view) return false;
    auto* display = gtk_widget_get_display(view);
    if (GDK_IS_X11_DISPLAY(display)) {
      int opcode, event, error, major = 2, minor = 1;
      // GTK 已协商 XI2 版本，不能在其连接上重新请求较低版本。
      auto* d = XOpenDisplay(gdk_display_get_name(display));
      if (!d) return false;
      const bool available = XQueryExtension(d, "XInputExtension", &opcode, &event, &error) &&
          XIQueryVersion(d, &major, &minor) == Success && (major > 2 || (major == 2 && minor >= 1));
      XCloseDisplay(d);
      return available;
    }
    if (!GDK_IS_WAYLAND_DISPLAY(display)) return false;
    if (!registry) {
      auto* d = gdk_wayland_display_get_wl_display(display);
      registry = wl_display_get_registry(d);
      static const wl_registry_listener listener = {global, removed};
      wl_registry_add_listener(registry, &listener, this);
      // 初始化时同步获取 registry；后续协议事件由 GTK 的现有连接分发。
      if (wl_display_roundtrip(d) < 0) return false;
    }
    return constraints && relative_manager;
  }
  void watch_window() {
    if (top) return;
    top = gtk_widget_get_toplevel(view);
    g_object_add_weak_pointer(G_OBJECT(top), reinterpret_cast<gpointer*>(&top));
    focus_handler = g_signal_connect(top, "focus-out-event", G_CALLBACK(+[](GtkWidget*, GdkEventFocus*, gpointer p) -> gboolean {
      static_cast<Impl*>(p)->release("focus-lost"); return FALSE;
    }), this);
    unmap_handler = g_signal_connect(top, "unmap", G_CALLBACK(+[](GtkWidget*, gpointer p) {
      static_cast<Impl*>(p)->release("unmapped");
    }), this);
    destroy_handler = g_signal_connect(top, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer p) {
      static_cast<Impl*>(p)->release("destroyed");
    }), this);
  }
  bool relative_device(int source) {
    const auto found = relative_devices.find(source);
    if (found != relative_devices.end()) return found->second;
    int count = 0;
    auto* devices = XIQueryDevice(raw_display, source, &count);
    bool x = false, y = false;
    for (int d = 0; devices && d < count; ++d) {
      for (int c = 0; c < devices[d].num_classes; ++c) {
        auto* cls = devices[d].classes[c];
        if (cls->type != XIValuatorClass) continue;
        auto* axis = reinterpret_cast<XIValuatorClassInfo*>(cls);
        if (axis->mode != XIModeRelative) continue;
        x |= axis->number == 0;
        y |= axis->number == 1;
      }
    }
    if (devices) XIFreeDeviceInfo(devices);
    return relative_devices[source] = x && y;
  }
  static gboolean read_raw(GIOChannel*, GIOCondition condition, gpointer data) {
    auto* s = static_cast<Impl*>(data);
    if (condition & (G_IO_ERR | G_IO_HUP)) {
      s->raw_source = 0; s->release("connection-lost"); return G_SOURCE_REMOVE;
    }
    while (s->raw_display && XPending(s->raw_display)) {
      XEvent event;
      XNextEvent(s->raw_display, &event);
      if (event.type != GenericEvent || event.xcookie.extension != s->xi_opcode ||
          !XGetEventData(s->raw_display, &event.xcookie)) continue;
      if (event.xcookie.evtype == XI_RawMotion && s->active) {
        auto* raw = static_cast<XIRawEvent*>(event.xcookie.data);
        // 平板的绝对轴不能当作鼠标 delta 注入。
        if (!s->relative_device(raw->sourceid)) {
          XFreeEventData(s->raw_display, &event.xcookie); continue;
        }
        const double* values = raw->raw_values;
        double dx = 0, dy = 0;
        for (int i = 0; i < raw->valuators.mask_len * 8; ++i) {
          if (!XIMaskIsSet(raw->valuators.mask, i)) continue;
          if (i == 0) dx = *values;
          if (i == 1) dy = *values;
          ++values;
        }
        if (std::isfinite(dx) && std::isfinite(dy) && (dx || dy)) s->motion(s->generation, dx, dy);
      }
      XFreeEventData(s->raw_display, &event.xcookie);
    }
    return G_SOURCE_CONTINUE;
  }
  std::string lock(int64_t id) {
    release("replaced");
    if (!supported()) return "Pointer capture is not supported by this display server";
    watch_window();
    if (!gtk_widget_get_mapped(view) || !GTK_IS_WINDOW(top) || !gtk_window_is_active(GTK_WINDOW(top)))
      return "Focus the remote window before capturing the mouse";
    auto* w = gtk_widget_get_window(view);
    if (!w) return "Remote window is not realized";
    window = GDK_WINDOW(g_object_ref(w));
    generation = id;
    requested = true;
    auto* display = gdk_window_get_display(window);
    if (GDK_IS_X11_DISPLAY(display)) {
      raw_display = XOpenDisplay(gdk_display_get_name(display));
      int event, error, major = 2, minor = 1;
      if (!raw_display || !XQueryExtension(raw_display, "XInputExtension", &xi_opcode, &event, &error) ||
          XIQueryVersion(raw_display, &major, &minor) != Success) {
        release("failed"); return "XInput2 connection failed";
      }
      unsigned char bits[XIMaskLen(XI_RawMotion)] = {};
      XISetMask(bits, XI_RawMotion);
      XIEventMask mask = {XIAllMasterDevices, sizeof(bits), bits};
      XISelectEvents(raw_display, DefaultRootWindow(raw_display), &mask, 1);
      XFlush(raw_display);
      auto* d = GDK_DISPLAY_XDISPLAY(display);
      const auto xid = GDK_WINDOW_XID(window);
      hide();
      auto* cursor = gdk_window_get_cursor(window);
      const int result = XGrabPointer(d, xid, True,
          PointerMotionMask | ButtonPressMask | ButtonReleaseMask,
          GrabModeAsync, GrabModeAsync, xid, gdk_x11_cursor_get_xcursor(cursor), CurrentTime);
      if (result != GrabSuccess) { release("failed"); return "Another application owns the pointer, or the window is unavailable"; }
      grabbed = true;
      auto* io = g_io_channel_unix_new(ConnectionNumber(raw_display));
      raw_source = g_io_add_watch(io, GIOCondition(G_IO_IN | G_IO_ERR | G_IO_HUP), read_raw, this);
      g_io_channel_unref(io);
      confirm();
    } else {
      auto* seat = gdk_display_get_default_seat(display);
      auto* device = seat ? gdk_seat_get_pointer(seat) : nullptr;
      auto* pointer = device ? gdk_wayland_device_get_wl_pointer(device) : nullptr;
      auto* surface = gdk_wayland_window_get_wl_surface(window);
      if (!pointer || !surface) { release("failed"); return "Wayland pointer or surface is unavailable"; }
      relative = zwp_relative_pointer_manager_v1_get_relative_pointer(relative_manager, pointer);
      static const zwp_relative_pointer_v1_listener motion_listener = {
        +[](void* data, zwp_relative_pointer_v1*, uint32_t, uint32_t, wl_fixed_t, wl_fixed_t, wl_fixed_t dx, wl_fixed_t dy) {
          auto* s = static_cast<Impl*>(data);
          if (s->active) s->motion(s->generation, wl_fixed_to_double(dx), wl_fixed_to_double(dy));
        }
      };
      zwp_relative_pointer_v1_add_listener(relative, &motion_listener, this);
      locked = zwp_pointer_constraints_v1_lock_pointer(constraints, surface, pointer, nullptr,
          ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT);
      static const zwp_locked_pointer_v1_listener lock_listener = {
        +[](void* data, zwp_locked_pointer_v1*) { static_cast<Impl*>(data)->confirm(); },
        +[](void* data, zwp_locked_pointer_v1*) { static_cast<Impl*>(data)->release("system-unlocked"); }
      };
      zwp_locked_pointer_v1_add_listener(locked, &lock_listener, this);
      gdk_display_flush(display);
      timeout = g_timeout_add_seconds(5, +[](gpointer data) -> gboolean {
        auto* s = static_cast<Impl*>(data); s->timeout = 0;
        s->release("timeout"); return G_SOURCE_REMOVE;
      }, this);
    }
    return {};
  }
};
LinuxPointerCapture::LinuxPointerCapture(GtkWidget* view, State state, Motion motion)
    : impl_(new Impl(view, std::move(state), std::move(motion))) {}
LinuxPointerCapture::~LinuxPointerCapture() = default;
bool LinuxPointerCapture::supported() { return impl_->supported(); }
std::string LinuxPointerCapture::lock(int64_t generation) { return impl_->lock(generation); }
void LinuxPointerCapture::unlock(const char* reason) { impl_->release(reason); }

void LinuxPointerCapture::unlock_generation(int64_t generation) {
  if (impl_->generation == generation) impl_->release("released");
}
