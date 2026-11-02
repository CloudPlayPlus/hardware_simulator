#include "linux_edit_focus.h"
#include <glib-object.h>
#ifdef CPP_HAVE_ATSPI
#include <atspi/atspi.h>
#endif

struct LinuxEditFocus::State {
  guint pending = 0;
#ifdef CPP_HAVE_ATSPI
  AtspiEventListener* listener = nullptr;
  AtspiAccessible* focused = nullptr;
  static void event(AtspiEvent* event, void* data) {
    auto* self = static_cast<State*>(data);
    if (event->detail1) {
      g_set_object(&self->focused, event->source);
    } else if (self->focused == event->source) {
      g_clear_object(&self->focused);
    }
    g_boxed_free(ATSPI_TYPE_EVENT, event);
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
  return state_->listener != nullptr;
#else
  return false;
#endif
}
bool LinuxEditFocus::start() {
#ifdef CPP_HAVE_ATSPI
  if (available()) return true;
  if (!atspi_is_initialized() && atspi_init() != 0) return false;
  // 无响应的应用不能长时间阻塞输入通道。
  atspi_set_timeout(100, 100);
  state_->listener = atspi_event_listener_new(State::event, state_.get(), nullptr);
  GError* error = nullptr;
  const bool ok = atspi_event_listener_register(
      state_->listener, "object:state-changed:focused", &error);
  g_clear_error(&error);
  if (!ok) stop();
  return ok;
#else
  return false;
#endif
}
void LinuxEditFocus::stop() {
  if (state_->pending) g_source_remove(state_->pending);
  state_->pending = 0;
  state_->callback = nullptr;
#ifdef CPP_HAVE_ATSPI
  if (state_->listener) {
    atspi_event_listener_deregister(state_->listener,
        "object:state-changed:focused", nullptr);
    g_clear_object(&state_->listener);
  }
  g_clear_object(&state_->focused);
#endif
}
void LinuxEditFocus::inspect(int64_t request, int x, int y, Callback callback) {
  if (!available()) return;
  if (state_->pending) g_source_remove(state_->pending);
  state_->request = request;
  state_->x = x;
  state_->y = y;
  state_->callback = std::move(callback);
  // 等应用处理点击；连续点击只保留最新请求。
  state_->pending = g_timeout_add(80, [](gpointer data) -> gboolean {
    auto* state = static_cast<State*>(data);
    state->pending = 0;
    bool active = false, secure = false;
#ifdef CPP_HAVE_ATSPI
    if (state->focused) {
      auto* target = ATSPI_ACCESSIBLE(g_object_ref(state->focused));
      atspi_accessible_clear_cache(target);
      auto* states = atspi_accessible_get_state_set(target);
      if (states) {
        active = atspi_state_set_contains(states, ATSPI_STATE_FOCUSED) &&
                 atspi_state_set_contains(states, ATSPI_STATE_EDITABLE) &&
                 atspi_state_set_contains(states, ATSPI_STATE_ENABLED) &&
                 !atspi_state_set_contains(states, ATSPI_STATE_DEFUNCT);
        g_object_unref(states);
      }
      GError* error = nullptr;
      if (active) {
        const auto role = atspi_accessible_get_role(target, &error);
        secure = role == ATSPI_ROLE_PASSWORD_TEXT;
        active = !error;
        g_clear_error(&error);
        auto* component = atspi_accessible_get_component_iface(target);
        // 点击必须落在当前编辑控件内，避免旧焦点导致误弹。
        active = active && component && atspi_component_contains(
            component, state->x, state->y, ATSPI_COORD_TYPE_SCREEN, &error);
        if (error) active = false;
        g_clear_error(&error);
        if (component) g_object_unref(component);
      }
      g_object_unref(target);
    }
#endif
    auto callback = std::move(state->callback);
    if (callback) callback(state->request, active, secure);
    return G_SOURCE_REMOVE;
  }, state_.get());
}
