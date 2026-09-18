cmake_minimum_required(VERSION 3.14)
project(hardware_simulator_input_tests LANGUAGES CXX)
enable_testing()

# 可独立运行，不需要 Flutter，也不会向用户桌面注入输入。
add_executable(desktop_service_input_client_test
  desktop_service_input_client_test.cpp
  ../desktop_service_input_client.cpp)
target_compile_features(desktop_service_input_client_test PRIVATE cxx_std_17)
target_compile_definitions(desktop_service_input_client_test PRIVATE UNICODE _UNICODE)
target_compile_options(desktop_service_input_client_test PRIVATE /W4 /WX /utf-8)
target_link_libraries(desktop_service_input_client_test PRIVATE user32)
add_test(NAME desktop_service_input_client COMMAND desktop_service_input_client_test)
