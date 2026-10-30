cmake_minimum_required(VERSION 3.14)
project(hardware_simulator_input_tests LANGUAGES CXX)
enable_testing()

set(CLOUDPLAYPLUS_SERVICE_SOURCE "${CMAKE_CURRENT_LIST_DIR}/../../../../windows/desktop_service"
  CACHE PATH "Companion service checkout for direct input tests")
if(EXISTS "${CLOUDPLAYPLUS_SERVICE_SOURCE}/src/input_dispatcher.cpp")
  add_executable(direct_input_client_test direct_input_client_test.cpp
    ../desktop_service_input_client.cpp
    "${CLOUDPLAYPLUS_SERVICE_SOURCE}/src/input_dispatcher.cpp")
  target_include_directories(direct_input_client_test PRIVATE "${CLOUDPLAYPLUS_SERVICE_SOURCE}/src")
  target_compile_features(direct_input_client_test PRIVATE cxx_std_17)
  target_compile_definitions(direct_input_client_test PRIVATE UNICODE _UNICODE CLOUDPLAYPLUS_DIRECT_INPUT)
  target_compile_options(direct_input_client_test PRIVATE /W4 /WX /utf-8)
  target_link_libraries(direct_input_client_test PRIVATE user32 advapi32)
  add_test(NAME direct_input_client COMMAND direct_input_client_test)
endif()

add_executable(pointer_coordinates_test pointer_coordinates_test.cpp)
target_compile_features(pointer_coordinates_test PRIVATE cxx_std_17)
target_compile_options(pointer_coordinates_test PRIVATE /W4 /WX /utf-8)
add_test(NAME pointer_coordinates COMMAND pointer_coordinates_test)

add_executable(cursor_position_snapshot_test cursor_position_snapshot_test.cpp)
target_compile_features(cursor_position_snapshot_test PRIVATE cxx_std_17)
target_compile_options(cursor_position_snapshot_test PRIVATE /W4 /WX /utf-8)
target_link_libraries(cursor_position_snapshot_test PRIVATE user32)
add_test(NAME cursor_position_snapshot COMMAND cursor_position_snapshot_test)

add_executable(cursor_visibility_snapshot_test cursor_visibility_snapshot_test.cpp)
target_compile_features(cursor_visibility_snapshot_test PRIVATE cxx_std_17)
target_compile_options(cursor_visibility_snapshot_test PRIVATE /W4 /WX /utf-8)
target_link_libraries(cursor_visibility_snapshot_test PRIVATE user32)
add_test(NAME cursor_visibility_snapshot COMMAND cursor_visibility_snapshot_test)

# 可独立运行，不需要 Flutter，也不会向用户桌面注入输入。
add_executable(desktop_service_input_client_test
  desktop_service_input_client_test.cpp
  ../desktop_service_input_client.cpp)
target_compile_features(desktop_service_input_client_test PRIVATE cxx_std_17)
target_compile_definitions(desktop_service_input_client_test PRIVATE UNICODE _UNICODE)
target_compile_options(desktop_service_input_client_test PRIVATE /W4 /WX /utf-8)
target_link_libraries(desktop_service_input_client_test PRIVATE user32)
add_test(NAME desktop_service_input_client COMMAND desktop_service_input_client_test)

add_executable(display_restore_client_test
  display_restore_client_test.cpp ../desktop_service_input_client.cpp)
target_compile_features(display_restore_client_test PRIVATE cxx_std_17)
target_compile_definitions(display_restore_client_test PRIVATE UNICODE _UNICODE)
target_compile_options(display_restore_client_test PRIVATE /W4 /WX /utf-8)
target_link_libraries(display_restore_client_test PRIVATE user32)
add_test(NAME display_restore_client COMMAND display_restore_client_test)
set_tests_properties(display_restore_client PROPERTIES TIMEOUT 20)

add_executable(exclusive_display_topology_test
  exclusive_display_topology_test.cpp ../virtual_display.cc ../desktop_service_input_client.cpp)
target_compile_features(exclusive_display_topology_test PRIVATE cxx_std_17)
target_compile_definitions(exclusive_display_topology_test PRIVATE UNICODE _UNICODE)
target_compile_options(exclusive_display_topology_test PRIVATE /W4 /WX /utf-8 /wd4245 /wd4505 /wd4100)
target_link_libraries(exclusive_display_topology_test PRIVATE user32 advapi32 setupapi cfgmgr32 wtsapi32)
add_test(NAME exclusive_display_topology COMMAND exclusive_display_topology_test)
