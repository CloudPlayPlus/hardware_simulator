#!/bin/bash
# 调用方式：dbus-run-session -- bash run_ibus_test.sh /absolute/path/to/test
# 新 session bus、独立 IBus socket、无 DISPLAY，不向真实桌面注入。
set -euo pipefail
test_root=$(mktemp -d)
trap 'kill "$ibus_pid" 2>/dev/null || true; rm -rf "$test_root"' EXIT
export XDG_CACHE_HOME="$test_root/cache" XDG_CONFIG_HOME="$test_root/config"
export IBUS_ADDRESS="unix:path=$test_root/ibus" CPP_ISOLATED_IBUS_TEST=1
export DISPLAY= WAYLAND_DISPLAY=
export GIO_USE_VFS=local
ibus-daemon --single --address="$IBUS_ADDRESS" --cache=none >"$test_root/daemon.log" 2>&1 &
ibus_pid=$!
for i in $(seq 1 50); do [ -S "$test_root/ibus" ] && break; sleep 0.1; done
"${1:?pass the integration test executable}"
