#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/hardware_simulator/hardware_simulator_plugin.h"
#include "hardware_simulator_plugin_private.h"

// This demonstrates a simple unit test of the C portion of this plugin's
// implementation.
//
// Once you have built the plugin's example app, you can run these tests
// from the command line. For instance, for a plugin called my_plugin
// built for x64 debug, run:
// $ build/linux/x64/debug/plugins/my_plugin/my_plugin_test

namespace hardware_simulator {
namespace test {

TEST(HardwareSimulatorPlugin, GetPlatformVersion) {
  g_autoptr(FlMethodResponse) response = get_platform_version();
  ASSERT_NE(response, nullptr);
  ASSERT_TRUE(FL_IS_METHOD_SUCCESS_RESPONSE(response));
  FlValue* result = fl_method_success_response_get_result(
      FL_METHOD_SUCCESS_RESPONSE(response));
  ASSERT_EQ(fl_value_get_type(result), FL_VALUE_TYPE_STRING);
  // The full string varies, so just validate that it has the right format.
  EXPECT_THAT(fl_value_get_string(result), testing::StartsWith("Linux "));
}

TEST(HardwareSimulatorPlugin, ConvertsLogicalVerticalScrollToLinuxWheel) {
  EXPECT_EQ(logical_vertical_scroll_to_linux_wheel(-80.0), 80);
  EXPECT_EQ(logical_vertical_scroll_to_linux_wheel(80.0), -80);
  EXPECT_EQ(logical_vertical_scroll_to_linux_wheel(0.0), 0);
}

}  // namespace test
}  // namespace hardware_simulator
