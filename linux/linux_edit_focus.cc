#include "linux_edit_focus.h"
#include <gio/gio.h>
#ifdef CPP_HAVE_ATSPI
#include <atspi/atspi-constants.h>
#include <gdk/gdkx.h>
#include <algorithm>
#include <string>
#endif
#ifdef CPP_LOG_AVAILABLE
#include <cpp_log/cpp_log.h>
#else
#define CPPLOG_WARN(...) ((void)0)
#endif

#ifdef CPP_HAVE_ATSPI
namespace {
constexpr char kRegistry[] = "org.a11y.atspi.Registry";
constexpr char kRegistryPath[] = "/org/a11y/atspi/registry";
constexpr char kDesktopPath[] = "/org/a11y/atspi/accessible/root";
constexpr char kAccessible[] = "org.a11y.atspi.Accessible";
constexpr char kFocusEvent[] = "object:state-changed:focused";
constexpr int kQueryTimeoutMs = 100;
constexpr int kStartupTimeoutMs = 500;

struct Accessible {
  std::string sender;
  std::string path;

  explicit operator bool() const { return !sender.empty(); }
};

GDBusConnection* open_bus(const gchar* address, GError** error) {
  // 只处理连接完成和取消，避免在 Flutter 主线程重入其他桌面事件。
  g_autoptr(GMainContext) context = g_main_context_new();
  g_autoptr(GMainLoop) loop = g_main_loop_new(context, FALSE);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  g_autoptr(GSource) timeout = g_timeout_source_new(kStartupTimeoutMs);
  g_source_set_callback(timeout, [](gpointer data) -> gboolean {
    g_cancellable_cancel(G_CANCELLABLE(data));
    return G_SOURCE_REMOVE;
  }, cancel, nullptr);
  g_source_attach(timeout, context);

  struct Result {
    GMainLoop* loop;
    GDBusConnection* connection;
    GError** error;
  } result{loop, nullptr, error};
  g_main_context_push_thread_default(context);
  g_dbus_connection_new_for_address(address,
      static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                                       G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
      nullptr, cancel, [](GObject*, GAsyncResult* async, gpointer data) {
        auto& result = *static_cast<Result*>(data);
        result.connection = g_dbus_connection_new_for_address_finish(async, result.error);
        g_main_loop_quit(result.loop);
      }, &result);
  g_main_loop_run(loop);
  g_main_context_pop_thread_default(context);
  g_source_destroy(timeout);
  return result.connection;
}

gchar* accessibility_address(GError** error) {
  const auto* address = g_getenv("AT_SPI_BUS_ADDRESS");
  if (address && *address) return g_strdup(address);

  auto* display = gdk_display_get_default();
  if (display && GDK_IS_X11_DISPLAY(display) && !g_getenv("WAYLAND_DISPLAY")) {
    auto* root = gdk_screen_get_root_window(gdk_display_get_default_screen(display));
    g_autofree guchar* data = nullptr;
    gint format = 0, length = 0;
    if (root && gdk_property_get(root, gdk_atom_intern_static_string("AT_SPI_BUS"),
            GDK_SELECTION_TYPE_STRING, 0, 4096, FALSE, nullptr, &format, &length,
            &data) && format == 8 && length > 0 && data[0]) {
      return g_strndup(reinterpret_cast<const char*>(data), length);
    }
  }

  g_autoptr(GDBusConnection) session = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, error);
  if (!session) return nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(session,
      "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", nullptr,
      G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, kStartupTimeoutMs, nullptr, error);
  gchar* result = nullptr;
  if (reply) g_variant_get(reply, "(s)", &result);
  return result;
}

bool has_state(const guint32* states, gsize count, AtspiStateType state) {
  const auto word = static_cast<gsize>(state) / 32;
  return word < count && (states[word] & (guint32{1} << (state % 32))) != 0;
}
}  // namespace
#endif

struct LinuxEditFocus::State {
  guint pending = 0;
#ifdef CPP_HAVE_ATSPI
  GDBusConnection* bus = nullptr;
  guint subscription = 0;
  Accessible focused;

  GVariant* query(const Accessible& node, const char* interface,
      const char* method, GVariant* args, const GVariantType* reply_type,
      gint64 deadline, GError** error = nullptr) const {
    const auto remaining_us = deadline - g_get_monotonic_time();
    // 即使超出查询预算，也要释放未发送的 floating GVariant。
    g_autoptr(GVariant) parameters = args ? g_variant_ref_sink(args) : nullptr;
    if (remaining_us <= 0 || g_dbus_connection_is_closed(bus)) return nullptr;
    const int timeout = std::min<gint64>(kQueryTimeoutMs, (remaining_us + 999) / 1000);
    return g_dbus_connection_call_sync(bus, node.sender.c_str(), node.path.c_str(),
        interface, method, parameters, reply_type, G_DBUS_CALL_FLAGS_NO_AUTO_START,
        timeout, nullptr, error);
  }

  bool editable_focus(const Accessible& node, gint64 deadline) const {
    g_autoptr(GVariant) reply = query(node, kAccessible, "GetState", nullptr,
        G_VARIANT_TYPE("(au)"), deadline);
    if (!reply) return false;
    g_autoptr(GVariant) bits = g_variant_get_child_value(reply, 0);
    gsize count = 0;
    const auto* states = static_cast<const guint32*>(
        g_variant_get_fixed_array(bits, &count, sizeof(guint32)));
    return has_state(states, count, ATSPI_STATE_FOCUSED) &&
           has_state(states, count, ATSPI_STATE_EDITABLE) &&
           has_state(states, count, ATSPI_STATE_ENABLED) &&
           !has_state(states, count, ATSPI_STATE_DEFUNCT);
  }

  bool contains(const Accessible& node, gint64 deadline, bool allow_no_component) const {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) reply = query(node, "org.a11y.atspi.Component", "Contains",
        g_variant_new("(iiu)", x, y, ATSPI_COORD_TYPE_SCREEN),
        G_VARIANT_TYPE("(b)"), deadline, &error);
    if (!reply) {
      return allow_no_component &&
          (g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD) ||
           g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_INTERFACE));
    }
    gboolean inside = FALSE;
    g_variant_get(reply, "(b)", &inside);
    return inside;
  }

  Accessible find_focus(const Accessible& node, int depth, int& remaining,
      gint64 deadline) const {
    if (!g_dbus_is_name(node.sender.c_str()) || node.path == "/org/a11y/atspi/null" || depth > 32 ||
        remaining-- <= 0 || g_get_monotonic_time() >= deadline) return {};
    const bool editable = editable_focus(node, deadline);
    // 从窗口层开始剪枝。结构节点可以没有 Component 接口。
    if ((depth >= 2 || editable) && !contains(node, deadline, !editable)) return {};
    if (editable) return node;

    g_autoptr(GVariant) reply = query(node, kAccessible, "GetChildren", nullptr,
        G_VARIANT_TYPE("(a(so))"), deadline);
    if (!reply) return {};
    g_autoptr(GVariant) children = g_variant_get_child_value(reply, 0);
    GVariantIter iter;
    g_variant_iter_init(&iter, children);
    const gchar* sender;
    const gchar* path;
    while (remaining > 0 && g_get_monotonic_time() < deadline &&
           g_variant_iter_next(&iter, "(&s&o)", &sender, &path)) {
      auto result = find_focus({sender, path}, depth + 1, remaining, deadline);
      if (result) return result;
    }
    return {};
  }

  static void event(GDBusConnection*, const gchar* sender, const gchar* path,
      const gchar*, const gchar*, GVariant* args, gpointer data) {
    auto* state = static_cast<State*>(data);
    // GTK 和 Qt 的事件尾部字段有版本差异，焦点标志始终是第二个字段。
    if (!sender || !path || g_variant_n_children(args) < 2) return;
    g_autoptr(GVariant) flag = g_variant_get_child_value(args, 1);
    if (!g_variant_is_of_type(flag, G_VARIANT_TYPE_INT32) &&
        !g_variant_is_of_type(flag, G_VARIANT_TYPE_UINT32)) return;
    const bool gained = g_variant_is_of_type(flag, G_VARIANT_TYPE_INT32)
        ? g_variant_get_int32(flag) != 0 : g_variant_get_uint32(flag) != 0;
    if (gained) {
      state->focused = {sender, path};
    } else if (state->focused.sender == sender && state->focused.path == path) {
      state->focused = {};
    }
  }
#endif
  int64_t request = 0;
  int x = 0, y = 0;
  Callback callback;
};

LinuxEditFocus::LinuxEditFocus() : state_(new State) {}
LinuxEditFocus::~LinuxEditFocus() { stop(); }

bool LinuxEditFocus::available() const {
#ifdef CPP_HAVE_ATSPI
  return state_->subscription && !g_dbus_connection_is_closed(state_->bus);
#else
  return false;
#endif
}

bool LinuxEditFocus::start() {
#ifdef CPP_HAVE_ATSPI
  if (available()) return true;
  stop();

  // 工具包可能已初始化 libatspi；其全局连接和缓存不能安全用于断线重连。
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* address = accessibility_address(&error);
  if (address && *address) {
    state_->bus = open_bus(address, &error);
  }
  if (state_->bus) {
    g_dbus_connection_set_exit_on_close(state_->bus, FALSE);
    state_->subscription = g_dbus_connection_signal_subscribe(state_->bus, nullptr,
        "org.a11y.atspi.Event.Object", "StateChanged", nullptr, "focused",
        G_DBUS_SIGNAL_FLAGS_NONE, State::event, state_.get(), nullptr);
    g_autoptr(GVariant) registered = g_dbus_connection_call_sync(state_->bus, kRegistry,
        kRegistryPath, kRegistry, "RegisterEvent",
        g_variant_new("(s)", kFocusEvent), G_VARIANT_TYPE_UNIT,
        G_DBUS_CALL_FLAGS_NONE, kStartupTimeoutMs, nullptr, &error);
    if (registered && available()) return true;
  }
  CPPLOG_WARN("LINUX_EDIT_FOCUS", "AT-SPI focus unavailable (domain=%s code=%d)",
      error ? g_quark_to_string(error->domain) : "none", error ? error->code : 0);
  stop();
#endif
  return false;
}

void LinuxEditFocus::stop() {
  if (state_->pending) g_source_remove(state_->pending);
  state_->pending = 0;
  state_->callback = nullptr;
#ifdef CPP_HAVE_ATSPI
  if (state_->bus) {
    if (state_->subscription) {
      g_dbus_connection_signal_unsubscribe(state_->bus, state_->subscription);
      state_->subscription = 0;
    }
    // Registry 按连接清理注册。异步关闭避免总线故障时阻塞远控停止流程。
    if (!g_dbus_connection_is_closed(state_->bus)) {
      g_dbus_connection_close(state_->bus, nullptr, nullptr, nullptr);
    }
    g_clear_object(&state_->bus);
  }
  state_->focused = {};
#endif
}

void LinuxEditFocus::inspect(int64_t request, int x, int y, Callback callback) {
  if (state_->pending) g_source_remove(state_->pending);
  state_->pending = 0;
  if (!available()) {
    state_->callback = nullptr;
    if (callback) callback(request, false, false);
    return;
  }
  state_->request = request;
  state_->x = x;
  state_->y = y;
  state_->callback = std::move(callback);
  // 等应用处理点击；连续点击只保留最新请求。
  state_->pending = g_timeout_add(80, [](gpointer data) -> gboolean {
    auto* self = static_cast<LinuxEditFocus*>(data);
    auto& state = *self->state_;
    state.pending = 0;
    bool active = false, secure = false;
#ifdef CPP_HAVE_ATSPI
    if (self->available()) {
      const gint64 deadline = g_get_monotonic_time() + 250000;
      if (!state.focused) {
        int remaining = 256;
        state.focused = state.find_focus({kRegistry, kDesktopPath}, 0, remaining, deadline);
      }
      if (state.focused && state.editable_focus(state.focused, deadline) &&
          state.contains(state.focused, deadline, false)) {
        g_autoptr(GVariant) reply = state.query(state.focused, kAccessible, "GetRole",
            nullptr, G_VARIANT_TYPE("(u)"), deadline);
        if (reply && self->available()) {
          guint32 role = 0;
          g_variant_get(reply, "(u)", &role);
          active = true;
          secure = role == ATSPI_ROLE_PASSWORD_TEXT;
        }
      }
    }
#endif
    auto callback = std::move(state.callback);
    if (callback) callback(state.request, active, secure);
    return G_SOURCE_REMOVE;
  }, this);
}
