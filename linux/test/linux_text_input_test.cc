#include "linux_text_input.h"
#include "hardware_simulator_plugin_private.h"
#include <cassert>
#include <string>

int main() {
  using linux_text_input::valid_text;
  // 真正的 Flutter String 边界：错误使用 list/map length 必须使测试失败。
  g_log_set_always_fatal(G_LOG_LEVEL_CRITICAL);
  const std::string unicode = "你好 😀 👨‍👩‍👧‍👦 é";
  g_autoptr(FlValue) channel_text = fl_value_new_string(unicode.c_str());
  assert(linux_committed_text_value(channel_text) == unicode);
  g_autoptr(FlValue) cancel_text = fl_value_new_string("");
  assert(linux_committed_text_value(cancel_text).empty());
  assert(valid_text("你好 😀 👨‍👩‍👧‍👦 é"));
  assert(valid_text(""));
  assert(valid_text(std::string(4096, 'a')));
  assert(!valid_text(std::string(4097, 'a')));
  assert(!valid_text("hello\nworld"));
  assert(!valid_text(std::string("a\0b", 3)));
  assert(!valid_text("\x7f"));
  assert(!valid_text("\xed\xa0\x80"));
  assert(!valid_text("\xf0\x9f\x98"));
  assert(!valid_text("\xc0\xaf"));
}
