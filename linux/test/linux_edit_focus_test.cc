#include "linux_edit_focus.h"
#include <atspi/atspi-constants.h>
#include <gio/gio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <atomic>
#include <cassert>
#include <cstring>
#include <future>
#include <string>
#include <thread>

namespace {
constexpr char kRegistry[] = "org.a11y.atspi.Registry";
constexpr char kRoot[] = "/org/a11y/atspi/accessible/root";
constexpr char kEntry[] = "/org/a11y/atspi/accessible/entry";
constexpr char kInterfaces[] = R"xml(
<node>
  <interface name="org.a11y.atspi.Registry">
    <method name="RegisterEvent">
      <arg type="s" direction="in"/>
    </method>
  </interface>
  <interface name="org.a11y.atspi.Accessible">
    <method name="GetState"><arg type="au" direction="out"/></method>
    <method name="GetChildren"><arg type="a(so)" direction="out"/></method>
    <method name="GetRole"><arg type="u" direction="out"/></method>
  </interface>
  <interface name="org.a11y.atspi.Component">
    <method name="Contains">
      <arg type="i" direction="in"/><arg type="i" direction="in"/>
      <arg type="u" direction="in"/><arg type="b" direction="out"/>
    </method>
  </interface>
</node>)xml";

template <typename Predicate>
void wait_for(Predicate done) {
  const auto deadline = g_get_monotonic_time() + 2000000;
  while (!done() && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, false)) {}
    g_usleep(1000);
  }
  assert(done());
}

// 真正的私有 D-Bus daemon，加上可控的 AT-SPI Registry 和控件。
struct Bus {
  explicit Bus(const std::string& address) {
    const std::string option = "--address=" + address;
    daemon = g_subprocess_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE, nullptr,
        "dbus-daemon", "--session", "--nofork", "--print-address=1", option.c_str(), nullptr);
    assert(daemon);
    g_autoptr(GDataInputStream) output =
        g_data_input_stream_new(g_subprocess_get_stdout_pipe(daemon));
    g_autofree gchar* listening = g_data_input_stream_read_line(output, nullptr, nullptr, nullptr);
    assert(listening);

    context = g_main_context_new();
    loop = g_main_loop_new(context, false);
    std::promise<void> started;
    auto ready = started.get_future();
    worker = std::thread([&] {
      g_main_context_push_thread_default(context);
      connection = g_dbus_connection_new_for_address_sync(address.c_str(),
          static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                                           G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
          nullptr, nullptr, nullptr);
      assert(connection);
      g_autoptr(GVariant) owned = g_dbus_connection_call_sync(connection,
          "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
          "RequestName", g_variant_new("(su)", kRegistry, 0),
          G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
      assert(owned);
      g_autoptr(GDBusNodeInfo) info = g_dbus_node_info_new_for_xml(kInterfaces, nullptr);
      assert(info);
      const GDBusInterfaceVTable handlers = {method, nullptr, nullptr, {}};
      assert(g_dbus_connection_register_object(connection, "/org/a11y/atspi/registry",
          info->interfaces[0], &handlers, this, nullptr, nullptr));
      assert(g_dbus_connection_register_object(connection, kRoot,
          info->interfaces[1], &handlers, this, nullptr, nullptr));
      assert(g_dbus_connection_register_object(connection, kEntry,
          info->interfaces[1], &handlers, this, nullptr, nullptr));
      assert(g_dbus_connection_register_object(connection, kEntry,
          info->interfaces[2], &handlers, this, nullptr, nullptr));
      started.set_value();
      g_main_loop_run(loop);
      g_clear_object(&connection);
      g_main_context_pop_thread_default(context);
    });
    ready.wait();
  }

  ~Bus() {
    g_main_context_invoke(context, [](gpointer data) -> gboolean {
      g_main_loop_quit(static_cast<GMainLoop*>(data));
      return G_SOURCE_REMOVE;
    }, loop);
    worker.join();
    disconnect();
    g_main_loop_unref(loop);
    g_main_context_unref(context);
  }

  void disconnect() {
    if (!daemon) return;
    g_subprocess_force_exit(daemon);
    assert(g_subprocess_wait(daemon, nullptr, nullptr));
    g_clear_object(&daemon);
  }

  void emit_focus(bool gained) {
    assert(g_dbus_connection_emit_signal(connection, nullptr, kEntry,
        "org.a11y.atspi.Event.Object", "StateChanged",
        g_variant_new("(siiv@a{sv})", "focused", gained ? 1 : 0, 0,
            g_variant_new_int32(0), g_variant_new_array(G_VARIANT_TYPE("{sv}"), nullptr, 0)),
        nullptr));
    assert(g_dbus_connection_flush_sync(connection, nullptr, nullptr));
  }

  static void method(GDBusConnection* connection, const gchar*, const gchar* path,
      const gchar*, const gchar* method, GVariant* args,
      GDBusMethodInvocation* call, gpointer data) {
    auto& bus = *static_cast<Bus*>(data);
    GVariant* result = nullptr;
    if (g_str_equal(method, "RegisterEvent")) {
      const gchar* event;
      g_variant_get_child(args, 0, "&s", &event);
      assert(g_str_equal(event, "object:state-changed:focused"));
      ++bus.registrations;
    } else if (g_str_equal(method, "GetState")) {
      guint32 states[2] = {};
      if (g_str_equal(path, kEntry)) {
        if (bus.focused) states[0] |= 1u << ATSPI_STATE_FOCUSED;
        if (bus.editable) states[0] |= 1u << ATSPI_STATE_EDITABLE;
        states[0] |= 1u << ATSPI_STATE_ENABLED;
      }
      result = g_variant_new("(@au)",
          g_variant_new_fixed_array(G_VARIANT_TYPE_UINT32, states, 2, sizeof(guint32)));
    } else if (g_str_equal(method, "GetChildren")) {
      GVariantBuilder children;
      g_variant_builder_init(&children, G_VARIANT_TYPE("a(so)"));
      if (g_str_equal(path, kRoot)) {
        ++bus.tree_queries;
        g_variant_builder_add(&children, "(so)",
            g_dbus_connection_get_unique_name(connection), kEntry);
      }
      result = g_variant_new("(a(so))", &children);
    } else if (g_str_equal(method, "GetRole")) {
      if (bus.role_error) {
        g_dbus_method_invocation_return_dbus_error(call, "org.example.Gone", "gone");
        return;
      }
      result = g_variant_new("(u)", bus.password ? ATSPI_ROLE_PASSWORD_TEXT : ATSPI_ROLE_ENTRY);
    } else if (g_str_equal(method, "Contains")) {
      gint x, y;
      guint coordinates;
      g_variant_get(args, "(iiu)", &x, &y, &coordinates);
      result = g_variant_new("(b)", bus.inside && x == 10 && y == 20 &&
          coordinates == ATSPI_COORD_TYPE_SCREEN);
    } else {
      assert(false);
    }
    g_dbus_method_invocation_return_value(call, result);
  }

  std::atomic<int> registrations{0}, tree_queries{0};
  std::atomic<bool> focused{true}, editable{true}, inside{true}, password{false},
      role_error{false};
  GSubprocess* daemon = nullptr;
  GMainContext* context = nullptr;
  GMainLoop* loop = nullptr;
  GDBusConnection* connection = nullptr;
  std::thread worker;
};

void check(LinuxEditFocus& monitor, bool expected, bool password = false) {
  bool received = false;
  monitor.inspect(42, 10, 20, [&](int64_t id, bool active, bool secure) {
    assert(id == 42 && active == expected && secure == password);
    received = true;
  });
  wait_for([&] { return received; });
}
}  // namespace

int main(int argc, char** argv) {
  if (argc == 2 && g_str_equal(argv[1], "--system-registry")) {
    LinuxEditFocus monitor;
    assert(monitor.start());
    check(monitor, false);
    monitor.stop();
    return 0;
  }
  const char* runtime = g_getenv("XDG_RUNTIME_DIR");
  assert(runtime && g_getenv("DBUS_SESSION_BUS_ADDRESS"));
  // 即便误从桌面直接运行，测试也只能绑定自行创建的私有目录。
  g_autofree gchar* directory = g_build_filename(runtime, "cpp-atspi-bus-XXXXXX", nullptr);
  assert(g_mkdtemp(directory));
  const std::string path = std::string(directory) + "/bus";
  const std::string address = "unix:path=" + path;
  g_setenv("AT_SPI_BUS_ADDRESS", address.c_str(), true);

  LinuxEditFocus monitor;
  // 留下没有监听者的 socket，覆盖实际故障和连续启动。
  sockaddr_un socket_address{};
  socket_address.sun_family = AF_UNIX;
  assert(path.size() < sizeof(socket_address.sun_path));
  std::strcpy(socket_address.sun_path, path.c_str());
  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  assert(fd >= 0);
  assert(bind(fd, reinterpret_cast<sockaddr*>(&socket_address), sizeof(socket_address)) == 0);
  assert(listen(fd, 1) == 0);
  assert(!monitor.start());  // socket 可连接，服务端不回应认证。
  close(fd);
  assert(!monitor.start());
  assert(!monitor.start());
  assert(!monitor.available());
  check(monitor, false);
  assert(unlink(path.c_str()) == 0);

  {
    Bus bus(address);
    assert(monitor.start());
    assert(monitor.start());
    assert(bus.registrations == 1);
    check(monitor, true);
    assert(bus.tree_queries == 1);  // 连接前已有的焦点。

    bus.emit_focus(true);
    bus.password = true;
    check(monitor, true, true);
    assert(bus.tree_queries == 1);
    bus.editable = false; check(monitor, false); bus.editable = true;
    bus.focused = false; check(monitor, false); bus.focused = true;
    bus.inside = false; check(monitor, false); bus.inside = true;
    bus.role_error = true; check(monitor, false); bus.role_error = false;
    monitor.inspect(1, 10, 20, [](int64_t, bool, bool) { assert(false); });
    check(monitor, true, true);

    bool inactive = false;
    monitor.inspect(99, 10, 20, [&](int64_t id, bool active, bool secure) {
      assert(id == 99 && !active && !secure);
      inactive = true;
    });
    bus.disconnect();
    wait_for([&] { return !monitor.available() && inactive; });
    check(monitor, false);
    assert(!monitor.start());
  }

  {
    Bus replacement(address);
    assert(monitor.start());
    assert(replacement.registrations == 1);
    check(monitor, true);
    assert(replacement.tree_queries == 1);  // 旧总线的焦点和密码状态已丢弃。
    monitor.inspect(2, 10, 20, [](int64_t, bool, bool) { assert(false); });
    monitor.stop();
    assert(!monitor.available());
    assert(monitor.start());
    assert(replacement.registrations == 2);
    check(monitor, true);
    monitor.stop();
  }
  unlink(path.c_str());
  assert(rmdir(directory) == 0);
}
