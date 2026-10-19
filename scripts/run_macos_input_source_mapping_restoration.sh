#!/bin/bash
# Executes the local, signed application harness that temporarily arms the
# real Caps Lock -> F20 mapping and proves the normal stream-stop path restores
# it exactly. Invoked by run_macos_input_source_integration.sh.

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
plugin_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
example_macos_dir="$plugin_root/example/macos"
harness_source="$plugin_root/test/macos/input_source_mapping_restoration_harness.swift"
harness_info_plist="$plugin_root/test/macos/InputSourceIntegrationHarnessInfo.plist"
harness_entitlements="$plugin_root/test/macos/InputSourceIntegrationHarness.entitlements"
flutter_root="$(sed -n 's/^FLUTTER_ROOT=//p' \
  "$example_macos_dir/Flutter/ephemeral/Flutter-Generated.xcconfig" | head -n 1)"

require_file() {
  if [[ ! -e "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 66
  fi
}

require_file "$harness_source"
require_file "$harness_info_plist"
require_file "$harness_entitlements"
if [[ -z "$flutter_root" ]]; then
  echo "Flutter root is unavailable; run flutter pub get in example first." >&2
  exit 66
fi

signing_identity="${CLOUDPLAYPLUS_MACOS_TEST_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning | \
    sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
  echo "No Apple Development signing identity found. Refusing to use ad-hoc signing." >&2
  exit 69
fi

run_id="$(date +%Y%m%d-%H%M%S)-$$"
build_root="${CLOUDPLAYPLUS_MACOS_INTEGRATION_BUILD_DIR:-$plugin_root/build/macos-input-source-integration}/restoration-$run_id"
derived_data="$build_root/DerivedData"
pod_products_dir="$example_macos_dir/build/Debug"
app_bundle="$build_root/InputSourceMappingRestorationHarness.app"
before_mapping="$(hidutil property --get UserKeyMapping)"
build_log="$build_root/hardware_simulator.xcodebuild.log"
mkdir -p "$build_root"

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
  exit 1
fi
echo "Built the current hardware_simulator framework (log: $build_log)."

plugin_framework="$pod_products_dir/hardware_simulator/hardware_simulator.framework"
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
  -framework IOKit \
  -Xlinker -rpath \
  -Xlinker '@executable_path/../Frameworks' \
  -o "$app_bundle/Contents/MacOS/InputSourceMappingRestorationHarness"
ditto "$plugin_framework" "$app_bundle/Contents/Frameworks/hardware_simulator.framework"
ditto "$flutter_framework" "$app_bundle/Contents/Frameworks/FlutterMacOS.framework"
codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  "$app_bundle/Contents/Frameworks/hardware_simulator.framework"
codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  "$app_bundle/Contents/Frameworks/FlutterMacOS.framework"
codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  --entitlements "$harness_entitlements" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

set +e
"$app_bundle/Contents/MacOS/InputSourceMappingRestorationHarness"
harness_status=$?
set -e
after_mapping="$(hidutil property --get UserKeyMapping)"
if [[ "$before_mapping" != "$after_mapping" ]]; then
  echo "FAIL: UserKeyMapping differs after the harness process exited." >&2
  echo "Before: $before_mapping" >&2
  echo "After:  $after_mapping" >&2
  exit 1
fi
if [[ "$harness_status" -eq 77 ]]; then
  echo "SKIP: a user-owned Caps Lock mapping was present; it was not changed." >&2
  exit 77
fi
if [[ "$harness_status" -ne 0 ]]; then
  echo "FAIL: mapping restoration harness exited with status $harness_status." >&2
  exit "$harness_status"
fi
echo "PASS: signed local mapping-restoration harness restored the exact UserKeyMapping."
