# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "hardware_simulator")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "hardware_simulator_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "desktop_service_input_client.cpp"
  "desktop_service_input_client.h"
  "hardware_simulator_plugin.cpp"
  "hardware_simulator_plugin.h"
  "cursor_monitor.cc"
  "cursor_monitor.h"
  "cpp_log_shim.h"
  "gamecontroller_manager.cc"
  "gamecontroller_manager.h"
  "notification_window.cc"
  "notification_window.h"
  "trackpad_scroll_accumulator.h"
  "windows_editing_event_monitor.cc"
  "windows_editing_event_monitor.h"
  "virtual_display.cc"
  "virtual_display.h"
  "virtual_display_control.cc"
  "virtual_display_control.h"
  "SmartKeyboardBlocker.cpp"
  "SmartKeyboardBlocker.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/hardware_simulator/hardware_simulator_plugin_c_api.h"
  "hardware_simulator_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Add specific compiler options to ignore warnings from parsec-vdd.h
target_compile_options(${PLUGIN_NAME} PRIVATE
  /wd"4245" /wd"4505" /wd"4828" /utf-8)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
if(TARGET cpp_log_plugin)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE CPP_LOG_AVAILABLE=1)
  target_link_libraries(${PLUGIN_NAME} PRIVATE cpp_log_plugin)
else()
  message(STATUS
    "hardware_simulator: cpp_log target unavailable; native logging disabled")
endif()

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
include_directories(
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vigembus/include"
)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin 
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vigembus/lib/x64/ViGEmClient.lib"
  setupapi
  cfgmgr32
  user32
  ole32
  oleaut32
  uiautomationcore
  wtsapi32)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(hardware_simulator_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vigembus/lib/x64/ViGEmClient.dll"
  PARENT_SCOPE
)

# Optional: Create example executable for testing virtual display functionality
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  add_executable(virtual_display_example
    "virtual_display_example.cc"
    "virtual_display.cc"
    "virtual_display_control.cc"
  )
  
  target_compile_options(virtual_display_example PRIVATE /wd"4245" /wd"4505")
  target_include_directories(virtual_display_example PRIVATE 
    "${CMAKE_CURRENT_SOURCE_DIR}"
  )
  
  # Link necessary libraries for the example
  target_link_libraries(virtual_display_example PRIVATE)
endif()

# Build native unit tests only for the example application, which opts in via
# include_hardware_simulator_tests. Plugin consumers do not fetch or build
# Google Test.
if(include_${PROJECT_NAME}_tests)
  set(TEST_RUNNER "${PROJECT_NAME}_test")
  enable_testing()

  include(FetchContent)
  FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/release-1.11.0.zip
  )
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
  FetchContent_MakeAvailable(googletest)

  add_executable(${TEST_RUNNER}
    "test/hardware_simulator_plugin_test.cpp"
    ${PLUGIN_SOURCES}
  )
  apply_standard_settings(${TEST_RUNNER})
  target_compile_options(${TEST_RUNNER} PRIVATE
    /wd"4245" /wd"4505" /wd"4828" /utf-8)
  target_include_directories(${TEST_RUNNER} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vigembus/include"
  )
  if(TARGET cpp_log_plugin)
    target_compile_definitions(${TEST_RUNNER} PRIVATE CPP_LOG_AVAILABLE=1)
    target_link_libraries(${TEST_RUNNER} PRIVATE cpp_log_plugin)
  endif()
  target_link_libraries(${TEST_RUNNER} PRIVATE
    flutter
    flutter_wrapper_plugin
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vigembus/lib/x64/ViGEmClient.lib"
    setupapi
    cfgmgr32
    user32
    ole32
    oleaut32
    uiautomationcore
    wtsapi32
    gtest_main
    gmock
  )
  add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FLUTTER_LIBRARY}"
      "$<TARGET_FILE_DIR:${TEST_RUNNER}>"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vigembus/lib/x64/ViGEmClient.dll"
      "$<TARGET_FILE_DIR:${TEST_RUNNER}>"
  )

  include(GoogleTest)
  gtest_discover_tests(${TEST_RUNNER})

  # The example opts into tests as part of its normal build. Run the registered
  # cases as well as compiling them so assertion failures fail validation.
  add_custom_target(${TEST_RUNNER}_run ALL
    COMMAND ${CMAKE_CTEST_COMMAND}
      --test-dir "${CMAKE_BINARY_DIR}"
      --build-config "$<CONFIG>"
      --output-on-failure
    DEPENDS ${TEST_RUNNER}
    USES_TERMINAL
  )
endif()
