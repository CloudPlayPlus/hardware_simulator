#include "../rumble_callback_registry.h"

#include <future>
#include <thread>

int main() {
  RumbleCallbackRegistry registry;
  const auto old_cookie = registry.Register({1, 2, 17, 1});
  const auto copied_callback = registry.Lookup(old_cookie);
  std::promise<void> reused;
  auto ready = reused.get_future();
  bool late_callback_dropped = false;
  std::thread callback([&] {
    ready.wait();
    late_callback_dropped = !registry.Lookup(old_cookie).has_value();
  });
  registry.Remove(old_cookie);
  const auto new_cookie = registry.Register({1, 2, 18, 1});
  reused.set_value();
  callback.join();
  const auto replacement = registry.Lookup(new_cookie);
  if (!late_callback_dropped || old_cookie == new_cookie || !replacement ||
      replacement->token != 18 || !copied_callback ||
      copied_callback->token != 17) {
    return 1;
  }
  registry.Remove(new_cookie);
  return registry.Lookup(new_cookie).has_value() ? 1 : 0;
}
