#!/bin/bash
# Runs explicit, local-only macOS integration coverage for the input-source
# feature. It never creates a remote connection, opens a DataChannel, or talks
# to a backend. It intentionally invokes xcodebuild/Flutter dependency
# resolution against the current checkout, which may update generated example
# lockfiles; restore unrelated lockfile drift before committing. See README.md
# for prerequisites and the evidence each mode provides.

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
plugin_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
example_macos_dir="$plugin_root/example/macos"
harness_source="$plugin_root/test/macos/input_source_real_integration_harness.swift"
harness_info_plist="$plugin_root/test/macos/InputSourceIntegrationHarnessInfo.plist"
harness_entitlements="$plugin_root/test/macos/InputSourceIntegrationHarness.entitlements"
cross_process_target_source="$plugin_root/test/macos/input_source_cross_process_target.swift"
cross_process_injector_source="$plugin_root/test/macos/input_source_cross_process_injector.swift"
cross_process_target_info_plist="$plugin_root/test/macos/InputSourceCrossProcessTargetInfo.plist"
cross_process_injector_info_plist="$plugin_root/test/macos/InputSourceCrossProcessInjectorInfo.plist"

usage() {
  cat <<'EOF'
Usage: ./scripts/run_macos_input_source_integration.sh [--ime|--cross-process-ime|--keyboard-restoration|--all]

  --ime                   Signed AppKit test: plugin selection barrier + real
                          Pinyin commit into an NSTextView. This is the default.
  --cross-process-ime     Signed two-AppKit-process diagnostic: the plugin
                          injects into an NSTextView owned by a separate app.
  --keyboard-restoration  Opt-in live IOHID test: arm Caps->F20, invoke normal
                          stop, and prove the exact UserKeyMapping is restored.
  --all                   Run the passing local IME and mapping-restoration
                          checks in that order; excludes the diagnostic.
EOF
}

mode="ime"
case "${1:-}" in
  ""|--ime)
    ;;
  --keyboard-restoration)
    mode="keyboard-restoration"
    ;;
  --cross-process-ime)
    mode="cross-process-ime"
    ;;
  --all)
    mode="all"
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

require_file() {
  if [[ ! -e "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 66
  fi
}

require_file "$harness_source"
require_file "$harness_info_plist"
require_file "$harness_entitlements"
require_file "$cross_process_target_source"
require_file "$cross_process_injector_source"
require_file "$cross_process_target_info_plist"
require_file "$cross_process_injector_info_plist"
flutter_root="$(sed -n 's/^FLUTTER_ROOT=//p' \
  "$example_macos_dir/Flutter/ephemeral/Flutter-Generated.xcconfig" | head -n 1)"
if [[ -z "$flutter_root" ]]; then
  echo "Flutter root is unavailable; run flutter pub get in example first." >&2
  exit 66
fi

run_id="$(date +%Y%m%d-%H%M%S)-$$"
build_root="${CLOUDPLAYPLUS_MACOS_INTEGRATION_BUILD_DIR:-$plugin_root/build/macos-input-source-integration}/$run_id"
derived_data="$build_root/DerivedData"
pod_products_dir="$example_macos_dir/build/Debug"
app_bundle="$build_root/InputSourceIntegrationHarness.app"
mkdir -p "$build_root"

echo "Local-only macOS input-source integration build: $build_root"

build_plugin_framework() {
  local build_log="$build_root/hardware_simulator.xcodebuild.log"
  if ! (
    cd "$example_macos_dir"
    xcodebuild \
      -project Pods/Pods.xcodeproj \
      -scheme hardware_simulator \
      -configuration Debug \
      -derivedDataPath "$derived_data" \
      MACOSX_DEPLOYMENT_TARGET=12.0 \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=YES \
      ENABLE_TESTABILITY=YES \
      CODE_SIGNING_ALLOWED=NO \
      BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
      build
  ) >"$build_log" 2>&1; then
    echo "Plugin framework build failed; last 120 log lines:" >&2
    tail -n 120 "$build_log" >&2
    return 1
  fi
  echo "Built the current hardware_simulator framework (log: $build_log)."
}

apple_development_identity() {
  if [[ -n "${CLOUDPLAYPLUS_MACOS_TEST_SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "$CLOUDPLAYPLUS_MACOS_TEST_SIGNING_IDENTITY"
    return
  fi
  security find-identity -v -p codesigning | \
    sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | \
    head -n 1
}

run_ime_integration() {
  local signing_identity
  signing_identity="$(apple_development_identity)"
  if [[ -z "$signing_identity" ]]; then
    echo "No Apple Development signing identity found. Refusing to use ad-hoc signing." >&2
    return 69
  fi

  # The example's generated Pods/lock state belongs to normal Flutter builds
  # and may intentionally lag its local package graph. This harness builds
  # only the hardware_simulator Pod target, never the Runner app.
  build_plugin_framework

  local plugin_framework="$pod_products_dir/hardware_simulator/hardware_simulator.framework"
  local flutter_framework
  flutter_framework="$(find \
    "$flutter_root/bin/cache/artifacts/engine" \
    -path '*/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework' \
    -type d -print -quit)"
  require_file "$plugin_framework"
  require_file "$flutter_framework"

  mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Frameworks"
  cp "$harness_info_plist" "$app_bundle/Contents/Info.plist"

  xcrun swiftc \
    -enable-testing \
    "$harness_source" \
    -F "$(dirname "$plugin_framework")" \
    -F "$(dirname "$flutter_framework")" \
    -framework hardware_simulator \
    -framework FlutterMacOS \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks' \
    -o "$app_bundle/Contents/MacOS/InputSourceIntegrationHarness"

  ditto "$plugin_framework" "$app_bundle/Contents/Frameworks/hardware_simulator.framework"
  ditto "$flutter_framework" "$app_bundle/Contents/Frameworks/FlutterMacOS.framework"
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    "$app_bundle/Contents/Frameworks/hardware_simulator.framework"
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    "$app_bundle/Contents/Frameworks/FlutterMacOS.framework"
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    --entitlements "$harness_entitlements" "$app_bundle"
  codesign --verify --deep --strict "$app_bundle"

  echo "Running signed local AppKit IME integration harness (no remote peer)..."
  set +e
  "$app_bundle/Contents/MacOS/InputSourceIntegrationHarness"
  local harness_status=$?
  set -e
  case "$harness_status" in
    0)
      echo "PASS: real Pinyin text commit through the current plugin framework."
      ;;
    77)
      echo "SKIP: the dedicated local IME prerequisite is not present." >&2
      return 77
      ;;
    *)
      echo "FAIL: real IME integration harness exited with status $harness_status." >&2
      return "$harness_status"
      ;;
  esac
}

run_keyboard_restoration_integration() {
  echo "Running opt-in live UserKeyMapping restoration test (no remote peer)..."
  set +e
  "$script_dir/run_macos_input_source_mapping_restoration.sh"
  local restoration_status=$?
  set -e
  if [[ "$restoration_status" -eq 77 ]]; then
    echo "SKIP: restoration precondition is not present on this Mac." >&2
    return 77
  fi
  return "$restoration_status"
}

read_cross_process_field() {
  local state_file="$1"
  local field="$2"
  sed -n "s/.*\"${field}\":\"\([^\"]*\)\".*/\1/p" "$state_file" 2>/dev/null | head -n 1
}

run_cross_process_ime_integration() {
  local signing_identity
  signing_identity="$(apple_development_identity)"
  if [[ -z "$signing_identity" ]]; then
    echo "No Apple Development signing identity found. Refusing to use ad-hoc signing." >&2
    return 69
  fi

  build_plugin_framework

  local plugin_framework="$pod_products_dir/hardware_simulator/hardware_simulator.framework"
  local flutter_framework
  flutter_framework="$(find \
    "$flutter_root/bin/cache/artifacts/engine" \
    -path '*/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework' \
    -type d -print -quit)"
  require_file "$plugin_framework"
  require_file "$flutter_framework"

  local target_app="$build_root/InputSourceCrossProcessTarget.app"
  local injector_app="$build_root/InputSourceCrossProcessInjector.app"
  local target_executable="$target_app/Contents/MacOS/InputSourceCrossProcessTarget"
  local injector_executable="$injector_app/Contents/MacOS/InputSourceCrossProcessInjector"
  local state_file="$build_root/cross-process-target.json"
  local target_pid=""
  local target_process=""

  cleanup_cross_process_target() {
    if [[ -n "$target_process" ]]; then
      kill "$target_process" 2>/dev/null || true
      wait "$target_process" 2>/dev/null || true
    fi
  }
  trap cleanup_cross_process_target RETURN

  mkdir -p "$target_app/Contents/MacOS" "$target_app/Contents/Frameworks"
  mkdir -p "$injector_app/Contents/MacOS" "$injector_app/Contents/Frameworks"
  cp "$cross_process_target_info_plist" "$target_app/Contents/Info.plist"
  cp "$cross_process_injector_info_plist" "$injector_app/Contents/Info.plist"

  xcrun swiftc \
    "$cross_process_target_source" \
    -framework AppKit \
    -framework Carbon \
    -o "$target_executable"
  xcrun swiftc \
    -enable-testing \
    "$cross_process_injector_source" \
    -F "$(dirname "$plugin_framework")" \
    -F "$(dirname "$flutter_framework")" \
    -framework hardware_simulator \
    -framework FlutterMacOS \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks' \
    -o "$injector_executable"

  ditto "$plugin_framework" "$injector_app/Contents/Frameworks/hardware_simulator.framework"
  ditto "$flutter_framework" "$injector_app/Contents/Frameworks/FlutterMacOS.framework"
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    "$target_app"
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    "$injector_app/Contents/Frameworks/hardware_simulator.framework"
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    "$injector_app/Contents/Frameworks/FlutterMacOS.framework"
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    --entitlements "$harness_entitlements" "$injector_app"
  codesign --verify --deep --strict "$target_app"
  codesign --verify --deep --strict "$injector_app"

  echo "Running signed cross-process AppKit IME diagnostic (no remote peer)..."
  "$target_executable" "$state_file" "com.apple.keylayout.ABC" &
  target_process=$!
  for _ in $(seq 1 100); do
    if [[ -f "$state_file" ]] && [[ "$(read_cross_process_field "$state_file" status)" == "ready" ]]; then
      target_pid="$(read_cross_process_field "$state_file" pid)"
      break
    fi
    sleep 0.05
  done
  if [[ -z "$target_pid" ]]; then
    echo "FAIL: cross-process target did not become ready." >&2
    return 1
  fi

  set +e
  "$injector_executable" "$target_pid"
  local injector_status=$?
  set -e
  if [[ "$injector_status" -eq 77 ]]; then
    echo "SKIP: cross-process injector lacks an existing Post Event grant." >&2
    return 77
  fi
  if [[ "$injector_status" -ne 0 ]]; then
    echo "FAIL: cross-process injector exited with status $injector_status." >&2
    return "$injector_status"
  fi

  for _ in $(seq 1 100); do
    if [[ "$(read_cross_process_field "$state_file" text)" == "你好" ]]; then
      echo "PASS: Pinyin committed 你好 into a separate frontmost AppKit process."
      return 0
    fi
    sleep 0.05
  done
  echo "DIAGNOSTIC: separate target did not receive the expected Pinyin commit; state: $(cat "$state_file" 2>/dev/null || true)" >&2
  return 1
}

case "$mode" in
  ime)
    run_ime_integration
    ;;
  cross-process-ime)
    run_cross_process_ime_integration
    ;;
  keyboard-restoration)
    run_keyboard_restoration_integration
    ;;
  all)
    run_ime_integration
    run_keyboard_restoration_integration
    ;;
esac
