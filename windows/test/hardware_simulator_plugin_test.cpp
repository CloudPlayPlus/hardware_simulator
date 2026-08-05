#include <windows.h>
#include <UIAutomation.h>
#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>

#include <memory>
#include <string>
#include <variant>

#include "hardware_simulator_plugin.h"
#include "trackpad_scroll_accumulator.h"
#include "windows_editing_event_monitor.h"
#include "windows_text_input_injector.h"

namespace hardware_simulator {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(HardwareSimulatorPlugin, GetPlatformVersion) {
  HardwareSimulatorPlugin plugin;
  // Save the reply value from the success callback.
  std::string result_string;
  plugin.HandleMethodCall(
      MethodCall("getPlatformVersion", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&result_string](const EncodableValue* result) {
            result_string = std::get<std::string>(*result);
          },
          nullptr, nullptr));

  // Since the exact string varies by host, just ensure that it's a string
  // with the expected format.
  EXPECT_TRUE(result_string.rfind("Windows ", 0) == 0);
}

TEST(PointerCoordinates, PreservesNegativeVirtualDesktopOrigin) {
  const RECT left_monitor = {-1920, 0, 0, 1080};
  const auto left_center =
      NormalizedPointOnMonitor(left_monitor, 0.5, 0.5);

  ASSERT_TRUE(left_center.has_value());
  EXPECT_EQ(left_center->x, -960);
  EXPECT_EQ(left_center->y, 540);

  const RECT upper_monitor = {0, -1200, 1920, 0};
  const auto upper_center =
      NormalizedPointOnMonitor(upper_monitor, 0.5, 0.5);

  ASSERT_TRUE(upper_center.has_value());
  EXPECT_EQ(upper_center->x, 960);
  EXPECT_EQ(upper_center->y, -600);
}

TEST(TrackpadScrollAccumulator, PreservesIntegralInputDistance) {
  TrackpadScrollAccumulator accumulator(12000);

  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 1);
}

TEST(TrackpadScrollAccumulator, CarriesSubunitFramesPerAxis) {
  TrackpadScrollAccumulator horizontal(12000);
  TrackpadScrollAccumulator vertical(12000);

  for (int i = 0; i < 9; ++i) {
    EXPECT_EQ(horizontal.Convert(0.1, false), 0);
  }
  EXPECT_EQ(horizontal.Convert(0.1, false), 1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
}

TEST(WindowsTextInputInjector, BuildsUnicodeKeyPairs) {
  std::vector<INPUT> inputs;

  ASSERT_TRUE(BuildWindowsUnicodeTextInputs("A\xE4\xBD\xA0", &inputs));
  ASSERT_EQ(inputs.size(), 4u);
  EXPECT_EQ(inputs[0].type, INPUT_KEYBOARD);
  EXPECT_EQ(inputs[0].ki.wVk, 0);
  EXPECT_EQ(inputs[0].ki.wScan, L'A');
  EXPECT_EQ(inputs[0].ki.dwFlags, KEYEVENTF_UNICODE);
  EXPECT_EQ(inputs[1].ki.wScan, L'A');
  EXPECT_EQ(inputs[1].ki.dwFlags, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
  EXPECT_EQ(inputs[2].ki.wScan, 0x4F60);
  EXPECT_EQ(inputs[2].ki.dwFlags, KEYEVENTF_UNICODE);
  EXPECT_EQ(inputs[3].ki.wScan, 0x4F60);
  EXPECT_EQ(inputs[3].ki.dwFlags, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
}

TEST(WindowsTextInputInjector, PreservesSurrogatePairs) {
  std::vector<INPUT> inputs;

  ASSERT_TRUE(
      BuildWindowsUnicodeTextInputs("\xF0\x9F\x91\x8B", &inputs));
  ASSERT_EQ(inputs.size(), 4u);
  EXPECT_EQ(inputs[0].ki.wScan, 0xD83D);
  EXPECT_EQ(inputs[1].ki.wScan, 0xD83D);
  EXPECT_EQ(inputs[2].ki.wScan, 0xDC4B);
  EXPECT_EQ(inputs[3].ki.wScan, 0xDC4B);
}

TEST(WindowsTextInputInjector, RejectsInvalidOrUnsafeTextAtomically) {
  std::vector<INPUT> inputs(1);
  const std::vector<INPUT> original = inputs;

  EXPECT_FALSE(BuildWindowsUnicodeTextInputs("", &inputs));
  EXPECT_EQ(inputs.size(), original.size());
  EXPECT_FALSE(BuildWindowsUnicodeTextInputs("line\nfeed", &inputs));
  EXPECT_EQ(inputs.size(), original.size());
  EXPECT_FALSE(BuildWindowsUnicodeTextInputs("\x7F", &inputs));
  EXPECT_EQ(inputs.size(), original.size());
  EXPECT_FALSE(BuildWindowsUnicodeTextInputs("\xC3\x28", &inputs));
  EXPECT_EQ(inputs.size(), original.size());
  EXPECT_FALSE(BuildWindowsUnicodeTextInputs(std::string(4097, 'a'), &inputs));
  EXPECT_EQ(inputs.size(), original.size());
}

TEST(WindowsEditingEventMonitor, ClassifiesEditableControls) {
  EXPECT_TRUE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_EditControlTypeId, false, true, false, false, false, false}));
  EXPECT_TRUE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_ComboBoxControlTypeId, false, true, false, false, false, false}));
  EXPECT_FALSE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_ComboBoxControlTypeId, false, false, false, false, false, false}));
  EXPECT_FALSE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_ButtonControlTypeId, false, false, false, false, false, false}));
}

TEST(WindowsEditingEventMonitor, FiltersDocumentsAndReadOnlyControls) {
  EXPECT_TRUE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_DocumentControlTypeId, true, false, false, true, false, false}));
  EXPECT_TRUE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_DocumentControlTypeId, true, false, false, false, false, true}));
  EXPECT_FALSE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_DocumentControlTypeId, true, false, false, false, false, false}));
  EXPECT_FALSE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_EditControlTypeId, false, true, false, false, true, false}));
  EXPECT_TRUE(IsWindowsTextInputCandidate(WindowsTextInputTraits{
      UIA_DocumentControlTypeId, true, false, false, true, true, false}));
}

}  // namespace test
}  // namespace hardware_simulator
