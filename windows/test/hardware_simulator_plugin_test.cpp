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
