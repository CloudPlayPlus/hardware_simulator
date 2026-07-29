#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "hardware_simulator_plugin.h"
#include "trackpad_scroll_accumulator.h"

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

TEST(TrackpadScrollAccumulator, PreservesCumulativeBrowserPixelDistance) {
  TrackpadScrollAccumulator accumulator(1.2, 12000);

  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 1);
  EXPECT_EQ(accumulator.Convert(1, false), 2);
}

TEST(TrackpadScrollAccumulator, CarriesSubunitFramesPerAxis) {
  TrackpadScrollAccumulator horizontal(1.2, 12000);
  TrackpadScrollAccumulator vertical(1.2, 12000);

  for (int i = 0; i < 8; ++i) {
    EXPECT_EQ(horizontal.Convert(0.1, false), 0);
  }
  EXPECT_EQ(horizontal.Convert(0.1, false), 1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -1);
  EXPECT_EQ(vertical.Convert(1, true), -2);
}

}  // namespace test
}  // namespace hardware_simulator
