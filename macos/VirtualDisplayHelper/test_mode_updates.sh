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

select_mode() {
  width="$1"
  height="$2"
  swift -e 'import CoreGraphics
import Darwin
let id = CGDirectDisplayID(UInt32(CommandLine.arguments[1])!)
let width = Int(CommandLine.arguments[2])!
let height = Int(CommandLine.arguments[3])!
let logicalWidth = width.isMultiple(of: 2) ? width / 2 : width
let logicalHeight = height.isMultiple(of: 2) ? height / 2 : height
let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
      let target = modes.first(where: {
        $0.width == logicalWidth && $0.height == logicalHeight &&
        $0.pixelWidth == width && $0.pixelHeight == height
      }) else { exit(2) }
_ = CGDisplaySetDisplayMode(id, target, nil)
for _ in 0..<20 {
  if let current = CGDisplayCopyDisplayMode(id),
     current.width == logicalWidth && current.height == logicalHeight &&
     current.pixelWidth == width && current.pixelHeight == height { exit(0) }
  usleep(50_000)
}
exit(3)' "$display_id" "$width" "$height"
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
  if ! IFS= read -r -t 5 response <&4; then
    echo "Timed out waiting for SET response" >&2
    exit 1
  fi
  if [[ "$response" != "OK $display_id" && "$response" != "BACKING $display_id" ]]; then
    echo "Unexpected SET response for ${width}x${height}: $response" >&2
    exit 1
  fi
}

# Let WindowServer publish the initial preferred mode.
sleep 2
assert_mode '1224x924/2448x1848'
set_mode 1920 1080 60
select_mode 1920 1080
assert_mode '960x540/1920x1080'
set_mode 1600 1200 60
select_mode 1600 1200
assert_mode '800x600/1600x1200'
set_mode 2448 1848 60
select_mode 2448 1848
assert_mode '1224x924/2448x1848'

echo "PASS: display $display_id kept its id across exact 2x backing-size updates"
