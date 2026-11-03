#include "linux_immersive_input.h"
#include <gdk/gdkx.h>
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#include "keyboard-shortcuts-inhibit-client.h"
#ifdef CPP_LOG_AVAILABLE
#include <cpp_log/cpp_log.h>
#else
#define CPPLOG_INFO(...) ((void)0)
#endif

struct LinuxImmersiveInput::Impl {
  GtkWidget* view;
  GtkWidget* top = nullptr;
  GdkWindow* window = nullptr;
  gulong focus_handler = 0, unmap_handler = 0, destroy_handler = 0;
  bool grabbed = false;
  bool wanted = false;
  bool preparing = false;
  guint focus_watch = 0;
  wl_registry* registry = nullptr;
  zwp_keyboard_shortcuts_inhibit_manager_v1* manager = nullptr;
  zwp_keyboard_shortcuts_inhibitor_v1* inhibitor = nullptr;
  uint32_t manager_name = 0;

  explicit Impl(GtkWidget* v) : view(v) {
    g_object_add_weak_pointer(G_OBJECT(view), reinterpret_cast<gpointer*>(&view));
  }
  ~Impl() {
    release();
    if (top) {
      g_signal_handler_disconnect(top, focus_handler);
      g_signal_handler_disconnect(top, unmap_handler);
      g_signal_handler_disconnect(top, destroy_handler);
      g_object_remove_weak_pointer(G_OBJECT(top), reinterpret_cast<gpointer*>(&top));
    }
    if (manager) zwp_keyboard_shortcuts_inhibit_manager_v1_destroy(manager);
    if (registry) wl_registry_destroy(registry);
    if (view) g_object_remove_weak_pointer(G_OBJECT(view), reinterpret_cast<gpointer*>(&view));
  }
  static gboolean check_focus(gpointer data) {
    auto* self = static_cast<Impl*>(data);
    auto* display = gdk_window_get_display(self->window);
    Window focused;
    int revert;
    XGetInputFocus(GDK_DISPLAY_XDISPLAY(display), &focused, &revert);
    auto* focus_window = gdk_x11_window_lookup_for_display(display, focused);
    if (focused == GDK_WINDOW_XID(self->window) ||
        (focus_window && gdk_window_get_toplevel(focus_window) == self->window))
      return G_SOURCE_CONTINUE;
    // X11 抓取期间 GTK 不一定发布 is-active；只在持有抓取时兜底检查。
    self->focus_watch = 0;
    self->release();
    return G_SOURCE_REMOVE;
  }
  void release() {
    if (focus_watch) { g_source_remove(focus_watch); focus_watch = 0; }
    if (inhibitor) {
      zwp_keyboard_shortcuts_inhibitor_v1_destroy(inhibitor);
      inhibitor = nullptr;
    }
    if (grabbed && window) {
      XUngrabKeyboard(GDK_DISPLAY_XDISPLAY(gdk_window_get_display(window)), CurrentTime);
      grabbed = false;
    }
    if (window) {
      gdk_display_flush(gdk_window_get_display(window));
      g_clear_object(&window);
      CPPLOG_INFO("IMMERSIVE_INPUT", "keyboard capture released");
    }
  }
  void watch_window() {
    if (top || !view) return;
    auto* candidate = gtk_widget_get_toplevel(view);
    if (!GTK_IS_WINDOW(candidate)) return;
    top = candidate;
    g_object_add_weak_pointer(G_OBJECT(top), reinterpret_cast<gpointer*>(&top));
    focus_handler = g_signal_connect(top, "notify::is-active", G_CALLBACK(+[](
        GObject* object, GParamSpec*, gpointer data) {
      auto* self = static_cast<Impl*>(data);
      if (!gtk_window_is_active(GTK_WINDOW(object))) {
        self->release();
      } else if (self->wanted) {
        // 授权对话框可只改变原生焦点，Dart 不一定收到一次完整的 inactive/resume。
        self->set_enabled(true);
      }
    }), this);
    unmap_handler = g_signal_connect(top, "unmap", G_CALLBACK(+[](GtkWidget*, gpointer data) {
      static_cast<Impl*>(data)->set_enabled(false);
    }), this);
    destroy_handler = g_signal_connect(top, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer data) {
      static_cast<Impl*>(data)->set_enabled(false);
    }), this);
  }
  static void global(void* data, wl_registry* registry, uint32_t name,
                     const char* interface, uint32_t) {
    auto* self = static_cast<Impl*>(data);
    if (g_str_equal(interface, zwp_keyboard_shortcuts_inhibit_manager_v1_interface.name)) {
      self->manager = static_cast<zwp_keyboard_shortcuts_inhibit_manager_v1*>(
          wl_registry_bind(registry, name, &zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1));
      self->manager_name = name;
    }
  }
  static void removed(void* data, wl_registry*, uint32_t name) {
    auto* self = static_cast<Impl*>(data);
    if (name != self->manager_name) return;
    self->release();
    if (self->manager) zwp_keyboard_shortcuts_inhibit_manager_v1_destroy(self->manager);
    self->manager = nullptr;
    self->manager_name = 0;
  }
  bool set_enabled(bool enabled) {
    wanted = enabled;
    if (!enabled) { release(); return true; }
    // Wayland roundtrip 会分派焦点通知，不能重入创建第二个 inhibitor。
    if (preparing) return true;
    preparing = true;
    struct ResetPreparing {
      bool& value;
      ~ResetPreparing() { value = false; }
    } reset_preparing{preparing};
    if (!view) { wanted = false; return false; }
    watch_window();
    if (!top || !gtk_widget_get_mapped(view)) {
      wanted = false;
      release(); return false;
    }
    if (!gtk_window_is_active(GTK_WINDOW(top))) {
      // 请求被接受但尚未抓取；显式 false 始终能取消此等待。
      release(); return true;
    }
    if (window) return true;
    auto* native_window = gtk_widget_get_window(top);
    if (!native_window) { wanted = false; return false; }
    g_autoptr(GdkWindow) w = GDK_WINDOW(g_object_ref(native_window));
    auto* display = gdk_window_get_display(w);
    if (GDK_IS_X11_DISPLAY(display)) {
      // owner_events 保留 GTK/Flutter 的正常键盘路径，不生成 onKeyBlocked。
      if (XGrabKeyboard(GDK_DISPLAY_XDISPLAY(display), GDK_WINDOW_XID(w), True,
                        GrabModeAsync, GrabModeAsync, CurrentTime) != GrabSuccess) { wanted = false; return false; }
      grabbed = true;
    } else if (GDK_IS_WAYLAND_DISPLAY(display)) {
      auto* d = gdk_wayland_display_get_wl_display(display);
      if (!registry) {
        registry = wl_display_get_registry(d);
        static const wl_registry_listener listener = {global, removed};
        wl_registry_add_listener(registry, &listener, this);
        if (wl_display_roundtrip(d) < 0) { wanted = false; return false; }
      }
      auto* seat = gdk_display_get_default_seat(display);
      auto* native_seat = seat ? gdk_wayland_seat_get_wl_seat(seat) : nullptr;
      auto* surface = gdk_wayland_window_get_wl_surface(w);
      // roundtrip 可分派失焦/销毁事件，必须重新检查窗口。
      if (!wanted || !manager || !native_seat || !surface || !top || !view ||
          gdk_window_is_destroyed(w) || !gtk_widget_get_mapped(view)) {
        wanted = false; return false;
      }
      if (!gtk_window_is_active(GTK_WINDOW(top))) return true;
      inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(manager, surface, native_seat);
      static const zwp_keyboard_shortcuts_inhibitor_v1_listener listener = {
        [](void*, zwp_keyboard_shortcuts_inhibitor_v1*) {
          CPPLOG_INFO("IMMERSIVE_INPUT", "Wayland shortcuts inhibited");
        },
        [](void*, zwp_keyboard_shortcuts_inhibitor_v1*) {
          // compositor 保留决定权，不循环重建 inhibitor 强制夺回快捷键。
          CPPLOG_INFO("IMMERSIVE_INPUT", "Wayland shortcuts restored by compositor");
        }
      };
      zwp_keyboard_shortcuts_inhibitor_v1_add_listener(inhibitor, &listener, this);
    } else {
      wanted = false; return false;
    }
    window = GDK_WINDOW(g_object_ref(w));
    if (grabbed) focus_watch = g_timeout_add(50, check_focus, this);
    gdk_display_flush(display);
    CPPLOG_INFO("IMMERSIVE_INPUT", "keyboard capture requested");
    return true;
  }
};
LinuxImmersiveInput::LinuxImmersiveInput(GtkWidget* view) : impl_(new Impl(view)) {}
LinuxImmersiveInput::~LinuxImmersiveInput() = default;
bool LinuxImmersiveInput::set_enabled(bool enabled) { return impl_->set_enabled(enabled); }
