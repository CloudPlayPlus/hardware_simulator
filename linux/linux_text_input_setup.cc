#include "linux_text_input_setup.h"

namespace linux_text_input_setup {
GSettings* open_settings() {
  auto* source = g_settings_schema_source_get_default();
  if (!source) return nullptr;
  auto* schema = g_settings_schema_source_lookup(source,
      "org.gnome.settings-daemon.plugins.xsettings", TRUE);
  if (!schema) return nullptr;
  auto* settings = g_settings_schema_has_key(schema, "overrides")
      ? g_settings_new_full(schema, nullptr, nullptr) : nullptr;
  g_settings_schema_unref(schema);
  return settings;
}
bool supported_desktop() {
  const char* desktop = g_getenv("XDG_CURRENT_DESKTOP");
  if (!desktop) return false;
  g_auto(GStrv) names = g_strsplit(desktop, ":", -1);
  for (int i = 0; names[i]; ++i)
    if (g_ascii_strcasecmp(names[i], "GNOME") == 0) return true;
  return false;
}
bool competing_input_method() {
  for (const auto* name : {"GTK_IM_MODULE", "QT_IM_MODULE", "XMODIFIERS"}) {
    const auto* value = g_getenv(name);
    if (value && std::string(value).find("fcitx") != std::string::npos) return true;
  }
  return false;
}
std::string current(GSettings* settings) {
  g_autoptr(GVariant) overrides = g_settings_get_value(settings, "overrides");
  g_autoptr(GVariant) value = g_variant_lookup_value(overrides, "Gtk/IMModule", nullptr);
  if (!value) return "";
  g_autofree char* printed = g_variant_print(value, TRUE);
  return printed;
}
bool replace(GSettings* settings, const std::string& expected,
             const std::string& value) {
  if (!g_settings_is_writable(settings, "overrides") || current(settings) != expected)
    return false;
  g_autoptr(GVariant) parsed = nullptr;
  if (!value.empty()) {
    parsed = g_variant_parse(nullptr, value.c_str(), nullptr, nullptr, nullptr);
    if (!parsed) return false;
  }
  g_autoptr(GVariant) overrides = g_settings_get_value(settings, "overrides");
  GVariantDict dict;
  g_variant_dict_init(&dict, overrides);
  if (parsed) g_variant_dict_insert_value(&dict, "Gtk/IMModule", parsed);
  else g_variant_dict_remove(&dict, "Gtk/IMModule");
  g_autoptr(GVariant) updated = g_variant_ref_sink(g_variant_dict_end(&dict));
  const bool ok = g_settings_set_value(settings, "overrides", updated);
  g_settings_sync();
  return ok && current(settings) == value;
}
}
