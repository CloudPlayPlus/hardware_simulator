#include "linux_gamescope_pointer_mapping.h"

#include <cassert>

int main() {
  using namespace linux_gamescope_pointer;

  ScaleConfig deck;
  deck.nested_width = 1280;
  deck.nested_height = 800;
  deck.max_auto_scale = 2;
  deck.resize_nested_height = true;
  const auto docked = window_scale(deck, Scaler::kAuto, 3840, 2160, 1280, 720);
  assert(docked.x == 3 && docked.y == 3);
  assert(map_axis(0.25, 3840, 1280, docked.x) == 320);

  const auto capped = window_scale(deck, Scaler::kAuto, 3840, 2160, 480, 270);
  assert(capped.x == 6 && capped.y == 6);

  const auto legacy = select_scaler(std::nullopt, 2);
  assert(legacy == Scaler::kInteger);
  assert(select_scaler(2, 2) == Scaler::kFit);
  assert(select_scaler(std::nullopt, 1) == Scaler::kAuto);
  const auto integer = window_scale(deck, legacy, 1280, 800, 960, 600);
  assert(integer.x == 1 && integer.y == 1);
  assert(map_axis(0.25, 1280, 960, integer.x) == 160);

  const auto undocked = window_scale(deck, Scaler::kAuto, 1280, 800, 1080, 720);
  assert(map_axis(0.25, 1280, 1080, undocked.x) == 252);
  assert(map_axis(0.75, 800, 720, undocked.y) == 540);
  assert(map_axis(0, 1280, 1080, undocked.x) == 0);
  assert(map_axis(1, 1280, 1080, undocked.x) == 1079);
}
