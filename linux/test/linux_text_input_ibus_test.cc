#include "linux_text_input.h"
#include <ibus.h>
#include <cassert>
#include <functional>
#include <string>
#include <vector>
#include <iostream>

static void wait_until(std::function<bool()> ready) {
  auto deadline = g_get_monotonic_time() + 10000000;
  while (!ready() && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, false)) {}
    g_usleep(1000);
  }
  assert(ready());
}

int main() {
  // 仅由隔离脚本执行；禁止连接用户真实桌面 IBus。
  assert(g_getenv("CPP_ISOLATED_IBUS_TEST"));
  ibus_init();
  auto* bus = ibus_bus_new();
  assert(ibus_bus_is_connected(bus));
  // IBus 的全局 engine 假焦点没有接收方，不能视为可提交目标。
  assert(ibus_bus_set_global_engine(bus, "xkb:us::eng"));
  bool completed = false, ok = false;
  linux_text_input::available([&](bool result) { ok = result; completed = true; });
  wait_until([&] { return completed; });
  assert(ok);
  completed = false;
  uint64_t dummy_token = 999;
  linux_text_input::prepare([&](uint64_t value) {
    dummy_token = value; completed = true;
  });
  wait_until([&] { return completed; });
  assert(dummy_token == 0);
  auto* context = ibus_bus_create_input_context(bus, "cpp-integration-test");
  assert(context);
  ibus_input_context_set_capabilities(context, IBUS_CAP_FOCUS | IBUS_CAP_PREEDIT_TEXT);
  ibus_input_context_focus_in(context);
  assert(ibus_bus_set_global_engine(bus, "xkb:us::eng"));
  std::vector<std::string> received;
  g_signal_connect(context, "commit-text", G_CALLBACK(+[](IBusInputContext*,
      IBusText* text, gpointer data) {
    static_cast<std::vector<std::string>*>(data)->push_back(ibus_text_get_text(text));
  }), &received);
  g_signal_connect(context, "forward-key-event", G_CALLBACK(+[](IBusInputContext*,
      guint key, guint, guint state, gpointer data) {
    if (key == IBUS_KEY_BackSpace && !(state & IBUS_RELEASE_MASK))
      static_cast<std::vector<std::string>*>(data)->push_back("<backspace>");
  }), &received);
  auto edit = [&](int count, const std::string& text) {
    completed = false;
    uint64_t token = 0;
    linux_text_input::prepare([&](uint64_t value) { token = value; completed = true; });
    wait_until([&] { return completed; });
    assert(token);
    completed = false;
    linux_text_input::finish(token, count, text,
        [&](bool result) { ok = result; completed = true; });
    wait_until([&] { return completed; });
    auto* engine = ibus_bus_get_global_engine(bus);
    assert(engine && std::string(ibus_engine_desc_get_name(engine)) == "xkb:us::eng");
    g_object_unref(engine);
  };
  edit(0, "你好 😀 👨‍👩‍👧‍👦 é");
  assert(ok);
  wait_until([&] { return received.size() == 1; });
  assert(received[0] == "你好 😀 👨‍👩‍👧‍👦 é");
  edit(2, "修订");
  assert(ok);
  wait_until([&] { return received.size() == 4; });
  assert(received[1] == "<backspace>" && received[2] == "<backspace>" && received[3] == "修订");
  edit(1, "bad\ntext");
  assert(!ok && received.size() == 4);
  edit(4097, "invalid deletion count");
  assert(!ok && received.size() == 4);
  edit(0, ""); // 权限撤销后的取消只恢复 engine。
  assert(ok && received.size() == 4);
  uint64_t token = 0;
  completed = false;
  linux_text_input::prepare([&](uint64_t value) { token = value; completed = true; });
  wait_until([&] { return completed; });
  assert(token);
  ibus_input_context_focus_out(context);
  // 等待焦点事件在同一 GLib context 中交付。
  bool settled = false;
  g_timeout_add(50, [](gpointer p) -> gboolean {
    *static_cast<bool*>(p) = true; return G_SOURCE_REMOVE;
  }, &settled);
  wait_until([&] { return settled; });
  completed = false;
  linux_text_input::finish(token, 1, "must not arrive", [&](bool result) {
    ok = result; completed = true;
  });
  wait_until([&] { return completed; });
  assert(!ok && received.size() == 4);
  ibus_input_context_focus_in(context);
  edit(0, "after focus restore");
  assert(ok);
  wait_until([&] { return received.size() == 5; });

  completed = false;
  linux_text_input::prepare([&](uint64_t value) { token = value; completed = true; });
  wait_until([&] { return completed; });
  assert(token);
  assert(ibus_bus_set_global_engine(bus, "xkb:gb::eng"));
  completed = false;
  linux_text_input::finish(token, 1, "must not arrive", [&](bool result) {
    ok = result; completed = true;
  });
  wait_until([&] { return completed; });
  assert(received.size() == 5); // 旧 engine 的信号由 IBus 丢弃；不覆盖新选择。
  auto* selected = ibus_bus_get_global_engine(bus);
  assert(selected && std::string(ibus_engine_desc_get_name(selected)) == "xkb:gb::eng");
  g_object_unref(selected);
  assert(ibus_bus_set_global_engine(bus, "xkb:us::eng"));

  completed = false;
  linux_text_input::prepare([&](uint64_t value) { token = value; completed = true; });
  wait_until([&] { return completed; });
  assert(token);
  settled = false;
  g_timeout_add(1800, [](gpointer p) -> gboolean {
    *static_cast<bool*>(p) = true; return G_SOURCE_REMOVE;
  }, &settled);
  wait_until([&] { return settled; });
  selected = ibus_bus_get_global_engine(bus);
  assert(selected && std::string(ibus_engine_desc_get_name(selected)) == "xkb:us::eng");
  g_object_unref(selected);
  completed = false;
  linux_text_input::finish(token, 1, "expired", [&](bool result) {
    ok = result; completed = true;
  });
  wait_until([&] { return completed; });
  assert(!ok && received.size() == 5);
  std::cout << "Isolated IBus text, replacement, validation and restoration passed\n";
}
