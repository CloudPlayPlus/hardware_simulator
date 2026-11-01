#pragma once
#include <gio/gio.h>
#include <string>

namespace linux_text_input_setup {
GSettings* open_settings();
bool supported_desktop();
bool competing_input_method();
std::string current(GSettings* settings);
bool replace(GSettings* settings, const std::string& expected,
             const std::string& value);
}
