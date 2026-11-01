#include "linux_text_input_setup.h"
#include <cassert>

int main() {
  // 内存 backend，绝不修改开发机的桌面设置。
  g_setenv("GSETTINGS_BACKEND", "memory", TRUE);
  g_setenv("XDG_CURRENT_DESKTOP", "ubuntu:GNOME", TRUE);
  assert(linux_text_input_setup::supported_desktop());
  g_setenv("XDG_CURRENT_DESKTOP", "KDE", TRUE);
  assert(!linux_text_input_setup::supported_desktop());
  g_setenv("GTK_IM_MODULE", "fcitx", TRUE);
  assert(linux_text_input_setup::competing_input_method());
  g_autoptr(GSettings) settings = linux_text_input_setup::open_settings();
  assert(settings);
  using linux_text_input_setup::current;
  using linux_text_input_setup::replace;
  assert(current(settings).empty());
  assert(replace(settings, "", "'ibus'"));
  // 设置在读取后变化时不覆盖。
  assert(!replace(settings, "", "'xim'"));
  assert(current(settings) == "'ibus'");
  // 恢复原值只影响 IMModule，保留用户后来改动的其他键。
  g_settings_set_value(settings, "overrides", g_variant_parse(
      G_VARIANT_TYPE("a{sv}"), "{'Gtk/IMModule': <'ibus'>, 'Gtk/CursorThemeSize': <32>}",
      nullptr, nullptr, nullptr));
  assert(replace(settings, "'ibus'", ""));
  assert(current(settings).empty());
  g_autoptr(GVariant) dict = g_settings_get_value(settings, "overrides");
  gint size = 0;
  assert(g_variant_lookup(dict, "Gtk/CursorThemeSize", "i", &size) && size == 32);
  assert(!replace(settings, "", "invalid variant"));
  assert(current(settings).empty());
}
