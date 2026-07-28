#include <flutter_linux/flutter_linux.h>

#include "include/hardware_simulator/hardware_simulator_plugin.h"

// This file exposes some plugin internals for unit testing. See
// https://github.com/flutter/flutter/issues/88724 for current limitations
// in the unit-testable API.

// Handles the getPlatformVersion method call.
FlMethodResponse *get_platform_version();

// Converts a canonical logical scroll delta to Linux wheel units. Set invert
// for the vertical REL_WHEEL axis (+ is wheel-up/page-up); horizontal
// REL_HWHEEL already matches the logical +right direction.
int logical_scroll_to_linux_wheel(double delta, bool invert);
