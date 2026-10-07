#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/cloudplayplus_vd_helper" >&2
  exit 64
fi

helper="$1"
if [[ ! -x "$helper" ]]; then
  echo "Helper is not executable: $helper" >&2
  exit 66
fi

runtime_dir="$(mktemp -d)"
command_fifo="$runtime_dir/commands"
reply_fifo="$runtime_dir/replies"
helper_log="$runtime_dir/helper.log"
helper_pid=""
serial_num=$((200000 + ($$ % 100000)))

cleanup() {
  if [[ -n "$helper_pid" ]]; then
    kill "$helper_pid" 2>/dev/null || true
    wait "$helper_pid" 2>/dev/null || true
  fi
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  rm -r "$runtime_dir"
}
trap cleanup EXIT INT TERM

mkfifo "$command_fifo" "$reply_fifo"
exec 3<>"$command_fifo"
exec 4<>"$reply_fifo"

"$helper" \
  2448 1848 60 "$PPID" "$serial_num" \
  1920 1080 60 \
  2448 1848 60 \
  3840 2160 60 \
  <&3 >&4 2>"$helper_log" &
helper_pid=$!

if ! IFS= read -r -t 10 display_id <&4; then
  echo "Timed out waiting for helper display id" >&2
  sed -n '1,120p' "$helper_log" >&2
  exit 1
fi
if [[ ! "$display_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid helper display id: $display_id" >&2
  exit 1
fi

current_mode() {
  swift -e 'import CoreGraphics
let id = CGDirectDisplayID(UInt32(CommandLine.arguments[1])!)
guard let mode = CGDisplayCopyDisplayMode(id) else { exit(2) }
print("\(mode.width)x\(mode.height)/\(mode.pixelWidth)x\(mode.pixelHeight)")' \
    "$display_id"
}

assert_mode() {
  expected="$1"
  actual="$(current_mode)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected mode $expected, got $actual" >&2
    exit 1
  fi
}

set_mode() {
  width="$1"
  height="$2"
  refresh_rate="$3"
  printf 'SET %s %s %s\n' "$width" "$height" "$refresh_rate" >&3
  if ! IFS= read -r -t 8 response <&4; then
    echo "Timed out waiting for SET response" >&2
    exit 1
  fi
  if [[ "$response" != "OK $display_id" ]]; then
    echo "Unexpected SET response for ${width}x${height}: $response" >&2
    exit 1
  fi
}

# 与插件相同：初始 ID 发布后，通过 SET 完成缩放选择与尺寸核验。
sleep 2
set_mode 2448 1848 60
assert_mode '1224x924/2448x1848'
set_mode 1920 1080 60
assert_mode '960x540/1920x1080'
set_mode 1600 1200 60
assert_mode '800x600/1600x1200'
set_mode 2448 1848 60
assert_mode '1224x924/2448x1848'

# macOS 26 上这两个 2× mode 不可用于桌面；须保留原像素尺寸回退 1×。
set_mode 1848 992 60
assert_mode '1848x992/1848x992'
set_mode 1848 1048 60
assert_mode '1848x1048/1848x1048'
set_mode 1848 1050 60
assert_mode '924x525/1848x1050'
set_mode 1920 1080 60
assert_mode '960x540/1920x1080'
printf 'SET 0 992 60\n' >&3
IFS= read -r -t 8 response <&4
[[ "$response" == "ERR" ]]
assert_mode '960x540/1920x1080'

# 直接创建低高度显示器也必须通过首次 SET，不能仅凭 ID 报成功。
kill "$helper_pid"
wait "$helper_pid"
helper_pid=""
"$helper" 1848 992 60 "$PPID" "$((serial_num + 1))" <&3 >&4 2>"$helper_log" &
helper_pid=$!
IFS= read -r -t 10 display_id <&4
[[ "$display_id" =~ ^[1-9][0-9]*$ ]]
sleep 2
set_mode 1848 992 60
assert_mode '1848x992/1848x992'

echo "PASS: exact backing sizes, HiDPI/1x transitions and low-height creation"
