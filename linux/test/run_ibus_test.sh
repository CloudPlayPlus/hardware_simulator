#!/bin/bash
# 新 session bus、独立 IBus socket、无 DISPLAY，不向真实桌面注入。
set -euo pipefail
if [[ "${1:-}" != --isolated ]]; then
  test_runner="$(dirname "${BASH_SOURCE[0]}")/run_isolated_dbus_test.py"
  exec python3 "$test_runner" -- bash "${BASH_SOURCE[0]}" --isolated "${1:?pass the integration test executable}"
fi
shift
export IBUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/ibus" CPP_ISOLATED_IBUS_TEST=1
export GIO_USE_VFS=local
ibus-daemon --single --address="$IBUS_ADDRESS" --cache=none >"$XDG_RUNTIME_DIR/ibus.log" 2>&1 &
ibus_pid=$!
trap 'kill "$ibus_pid" 2>/dev/null || true; wait "$ibus_pid" 2>/dev/null || true' EXIT
for i in $(seq 1 50); do [ -S "$XDG_RUNTIME_DIR/ibus" ] && break; sleep 0.1; done
"$1"
