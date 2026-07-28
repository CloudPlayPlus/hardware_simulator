#include <flutter_linux/flutter_linux.h>

#include "include/hardware_simulator/hardware_simulator_plugin.h"

// This file exposes some plugin internals for unit testing. See
// https://github.com/flutter/flutter/issues/88724 for current limitations
// in the unit-testable API.

// Handles the getPlatformVersion method call.
FlMethodResponse *get_platform_version();

// Converts canonical logical vertical scroll (+ is page-down) to Linux
// REL_WHEEL direction (+ is wheel-up/page-up).
int logical_vertical_scroll_to_linux_wheel(double dy);
