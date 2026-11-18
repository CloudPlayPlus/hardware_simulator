#pragma once

#include <array>
#include <memory>
#include <string_view>

#include <inputtino/input.hpp>

class LinuxGamepads {
 public:
  ~LinuxGamepads();
  int create();
  bool remove(int id);
  bool apply(int id, std::string_view action);

 private:
  inputtino::XboxOneJoypad* get(int id);
  std::array<std::unique_ptr<inputtino::XboxOneJoypad>, 4> controllers_;
};
