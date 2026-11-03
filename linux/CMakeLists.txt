# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "hardware_simulator")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "hardware_simulator_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "hardware_simulator_plugin.cc"
  "linux_mouse.cc"
  "linux_pointer_capture.cc"
  "linux_edit_focus.cc"
  "linux_text_input.cc"
  "linux_text_input_setup.cc"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

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

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

pkg_check_modules(LIBEVDEV QUIET IMPORTED_TARGET libevdev)
if(LIBEVDEV_FOUND)
  set(LIBEVDEV_CUSTOM_INCLUDE_DIR "${LIBEVDEV_INCLUDE_DIRS}")
  set(LIBEVDEV_CUSTOM_LIBRARY PkgConfig::LIBEVDEV)
else()
  include(ExternalProject)
  set(LIBEVDEV_VERSION 1.13.2)
  ExternalProject_Add(libevdev
    URL https://www.freedesktop.org/software/libevdev/libevdev-${LIBEVDEV_VERSION}.tar.xz
    PREFIX libevdev-${LIBEVDEV_VERSION}
    BUILD_IN_SOURCE 1
    BUILD_BYPRODUCTS <SOURCE_DIR>/libevdev/.libs/libevdev.a
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env CFLAGS=-fPIC <SOURCE_DIR>/configure --prefix=<INSTALL_DIR>
    BUILD_COMMAND make
    INSTALL_COMMAND "")
  ExternalProject_Get_Property(libevdev SOURCE_DIR)
  set(LIBEVDEV_CUSTOM_INCLUDE_DIR "${SOURCE_DIR}")
  set(LIBEVDEV_CUSTOM_LIBRARY "${SOURCE_DIR}/libevdev/.libs/libevdev.a")
endif()

set(BUILD_SHARED_LIBS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(USE_UHID OFF)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/inputtino"
  "${CMAKE_CURRENT_BINARY_DIR}/inputtino")
set_target_properties(libinputtino PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(NOT LIBEVDEV_FOUND)
  add_dependencies(libinputtino libevdev)
  add_dependencies(${PLUGIN_NAME} libevdev)
endif()
target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_17)
target_link_libraries(${PLUGIN_NAME} PRIVATE inputtino::libinputtino)

# 可选依赖：无 IBus 构建不声明原生文本能力，普通 uinput 不受影响。
pkg_check_modules(IBUS QUIET IMPORTED_TARGET ibus-1.0)
if(IBUS_FOUND)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE CPP_HAVE_IBUS)
  target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::IBUS)
endif()

pkg_check_modules(ATSPI QUIET IMPORTED_TARGET atspi-2)
if(ATSPI_FOUND)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE CPP_HAVE_ATSPI)
  target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::ATSPI)
endif()

pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11 xrandr)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::X11)

# 使用发行版协议 XML 生成客户端绑定，与 GTK 共用 Wayland 连接。
enable_language(C)
pkg_check_modules(POINTER REQUIRED IMPORTED_TARGET xi wayland-client)
pkg_check_modules(WAYLAND_PROTOCOLS REQUIRED wayland-protocols)
pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
find_program(WAYLAND_SCANNER wayland-scanner)
if(NOT WAYLAND_SCANNER)
  message(FATAL_ERROR "wayland-scanner is required for Linux pointer capture")
endif()
foreach(protocol pointer-constraints relative-pointer)
  set(xml "${WAYLAND_PROTOCOLS_DIR}/unstable/${protocol}/${protocol}-unstable-v1.xml")
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${protocol}-client.h"
    COMMAND ${WAYLAND_SCANNER} client-header ${xml} "${CMAKE_CURRENT_BINARY_DIR}/${protocol}-client.h"
    DEPENDS ${xml})
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${protocol}-protocol.c"
    COMMAND ${WAYLAND_SCANNER} private-code ${xml} "${CMAKE_CURRENT_BINARY_DIR}/${protocol}-protocol.c"
    DEPENDS ${xml})
  list(APPEND POINTER_PROTOCOL_SOURCES "${CMAKE_CURRENT_BINARY_DIR}/${protocol}-client.h"
    "${CMAKE_CURRENT_BINARY_DIR}/${protocol}-protocol.c")
endforeach()
target_sources(${PLUGIN_NAME} PRIVATE ${POINTER_PROTOCOL_SOURCES})
target_include_directories(${PLUGIN_NAME} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::POINTER)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(hardware_simulator_bundled_libraries
  ""
  PARENT_SCOPE
)

# === Tests ===
# These unit tests can be run from a terminal after building the example.

# Only enable test builds when building the example (which sets this variable)
# so that plugin clients aren't building the tests.
if (${include_${PROJECT_NAME}_tests})
if(${CMAKE_VERSION} VERSION_LESS "3.11.0")
message("Unit tests require CMake 3.11.0 or later")
else()
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

# Add the Google Test dependency.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/release-1.11.0.zip
)
# Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
# Disable install commands for gtest so it doesn't end up in the bundle.
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)

FetchContent_MakeAvailable(googletest)

# The plugin's exported API is not very useful for unit testing, so build the
# sources directly into the test binary rather than using the shared library.
add_executable(${TEST_RUNNER}
  test/hardware_simulator_plugin_test.cc
  ${PLUGIN_SOURCES}
  ${POINTER_PROTOCOL_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE flutter)
target_link_libraries(${TEST_RUNNER} PRIVATE PkgConfig::GTK)
target_link_libraries(${TEST_RUNNER} PRIVATE inputtino::libinputtino)
target_link_libraries(${TEST_RUNNER} PRIVATE PkgConfig::X11 PkgConfig::POINTER)
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)

# Enable automatic test discovery.
include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})

endif()  # CMake version check
endif()  # include_${PROJECT_NAME}_tests

# 无桌面副作用的 uinput 边界回归测试。
option(HARDWARE_SIMULATOR_INPUT_TESTS "Build Linux input regression checks" OFF)
if(HARDWARE_SIMULATOR_INPUT_TESTS)
  if(ATSPI_FOUND)
    add_executable(linux_edit_focus_test test/linux_edit_focus_test.cc linux_edit_focus.cc)
    target_include_directories(linux_edit_focus_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_compile_definitions(linux_edit_focus_test PRIVATE CPP_HAVE_ATSPI)
    target_compile_options(linux_edit_focus_test PRIVATE -UNDEBUG)
    target_link_libraries(linux_edit_focus_test PRIVATE PkgConfig::ATSPI PkgConfig::GTK)
    foreach(symbol atspi_get_desktop atspi_accessible_get_child_count
        atspi_accessible_get_child_at_index atspi_is_initialized atspi_set_timeout atspi_event_listener_register
        atspi_event_listener_deregister atspi_accessible_clear_cache
        atspi_accessible_get_state_set atspi_accessible_get_role
        atspi_accessible_get_component_iface atspi_component_contains)
      set_property(TARGET linux_edit_focus_test APPEND_STRING PROPERTY LINK_FLAGS " -Wl,--wrap=${symbol}")
    endforeach()
  endif()
  add_executable(linux_text_input_setup_test test/linux_text_input_setup_test.cc linux_text_input_setup.cc)
  target_include_directories(linux_text_input_setup_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(linux_text_input_setup_test PRIVATE PkgConfig::GTK)
  target_compile_options(linux_text_input_setup_test PRIVATE -UNDEBUG)
  add_executable(linux_text_input_test test/linux_text_input_test.cc linux_text_input.cc)
  target_include_directories(linux_text_input_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(linux_text_input_test PRIVATE flutter PkgConfig::GTK)
  target_compile_options(linux_text_input_test PRIVATE -UNDEBUG)
  if(IBUS_FOUND)
    add_executable(linux_text_input_ibus_test test/linux_text_input_ibus_test.cc linux_text_input.cc)
    target_include_directories(linux_text_input_ibus_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_compile_definitions(linux_text_input_ibus_test PRIVATE CPP_HAVE_IBUS)
    target_compile_options(linux_text_input_ibus_test PRIVATE -UNDEBUG)
    target_link_libraries(linux_text_input_ibus_test PRIVATE PkgConfig::IBUS)
  endif()
  add_executable(linux_input_test test/linux_input_test.cc linux_mouse.cc)
  target_include_directories(linux_input_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(linux_input_test PRIVATE inputtino::libinputtino)
  set_property(TARGET linux_input_test APPEND_STRING PROPERTY LINK_FLAGS
    " -Wl,--wrap=libevdev_uinput_create_from_device -Wl,--wrap=libevdev_uinput_destroy -Wl,--wrap=libevdev_uinput_write_event")
endif()

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../cpp_log/include/cpp_log/cpp_log.h")
  target_compile_definitions(${PLUGIN_NAME} PRIVATE CPP_LOG_AVAILABLE=1)
  target_link_libraries(${PLUGIN_NAME} PRIVATE cpp_log)
endif()

option(HARDWARE_SIMULATOR_POINTER_TESTS "Build isolated Linux pointer capture integration test" OFF)
if(HARDWARE_SIMULATOR_POINTER_TESTS)
  pkg_check_modules(XTST REQUIRED IMPORTED_TARGET xtst)
  add_executable(linux_pointer_capture_test linux_pointer_capture.cc
    test/linux_pointer_capture_test.cc ${POINTER_PROTOCOL_SOURCES})
  target_include_directories(linux_pointer_capture_test PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
  target_compile_features(linux_pointer_capture_test PRIVATE cxx_std_17)
  target_compile_options(linux_pointer_capture_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
  target_link_libraries(linux_pointer_capture_test PRIVATE PkgConfig::GTK PkgConfig::X11
    PkgConfig::POINTER PkgConfig::XTST)
endif()
