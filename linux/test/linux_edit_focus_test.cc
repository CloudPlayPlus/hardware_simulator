#include "linux_edit_focus.h"
#include <atspi/atspi.h>
#include <cassert>

// 模拟无障碍提供者，覆盖错误、密码、只读及请求取消；不操作真实桌面。
static AtspiEventListener* listener;
static bool registration_ok = false;
static bool editable = true, focused = true, inside = true, role_error = false;
static AtspiRole role = ATSPI_ROLE_ENTRY;
extern "C" {
gboolean __wrap_atspi_is_initialized() { return true; }
void __wrap_atspi_set_timeout(gint, gint) {}
gboolean __wrap_atspi_event_listener_register(AtspiEventListener* value,
    const gchar*, GError**) { listener = value; return registration_ok; }
gboolean __wrap_atspi_event_listener_deregister(AtspiEventListener*,
    const gchar*, GError**) { listener = nullptr; return true; }
void __wrap_atspi_accessible_clear_cache(AtspiAccessible*) {}
AtspiStateSet* __wrap_atspi_accessible_get_state_set(AtspiAccessible*) {
  auto* states = atspi_state_set_new(nullptr);
  atspi_state_set_add(states, ATSPI_STATE_ENABLED);
  if (editable) atspi_state_set_add(states, ATSPI_STATE_EDITABLE);
  if (focused) atspi_state_set_add(states, ATSPI_STATE_FOCUSED);
  return states;
}
AtspiRole __wrap_atspi_accessible_get_role(AtspiAccessible*, GError** error) {
  if (role_error) g_set_error_literal(error, g_quark_from_static_string("test"), 1, "gone");
  return role;
}
AtspiComponent* __wrap_atspi_accessible_get_component_iface(AtspiAccessible* target) {
  return reinterpret_cast<AtspiComponent*>(g_object_ref(target));
}
gboolean __wrap_atspi_component_contains(AtspiComponent*, gint x, gint y,
    AtspiCoordType, GError**) { return inside && x == 10 && y == 20; }
}
static void settle() {
  const auto end = g_get_monotonic_time() + 150000;
  while (g_get_monotonic_time() < end) {
    while (g_main_context_iteration(nullptr, false)) {}
    g_usleep(1000);
  }
}
int main() {
  LinuxEditFocus monitor;
  assert(!monitor.start());
  assert(!monitor.available());
  registration_ok = true;
  assert(monitor.start());
  assert(monitor.start());
  bool unknown_reported = false;
  monitor.inspect(9, 10, 20, [&](int64_t id, bool active, bool) {
    assert(id == 9 && !active);
    unknown_reported = true;
  });
  settle();
  assert(unknown_reported);
  auto* source = ATSPI_ACCESSIBLE(g_object_new(ATSPI_TYPE_ACCESSIBLE, nullptr));
  auto* event = g_new0(AtspiEvent, 1);
  event->type = g_strdup("object:state-changed:focused");
  event->source = ATSPI_ACCESSIBLE(g_object_ref(source));
  event->detail1 = 1;
  listener->callback(event, listener->user_data);
  int calls = 0;
  auto check = [&](bool expected, bool secure) {
    monitor.inspect(42, 10, 20, [&](int64_t id, bool active, bool password) {
      assert(id == 42 && active == expected);
      if (active) assert(password == secure);
      ++calls;
    });
    const int before = calls;
    settle();
    assert(calls == before + 1);
  };
  check(true, false);
  role = ATSPI_ROLE_PASSWORD_TEXT;
  check(true, true);
  editable = false; check(false, false); editable = true;
  focused = false; check(false, false); focused = true;
  inside = false; check(false, false); inside = true;
  role_error = true; check(false, false); role_error = false;
  monitor.inspect(1, 10, 20, [](int64_t, bool, bool) { assert(false); });
  check(true, true);
  monitor.inspect(2, 10, 20, [](int64_t, bool, bool) { assert(false); });
  monitor.stop();
  assert(!monitor.available());
  settle();
  g_object_unref(source);
}
