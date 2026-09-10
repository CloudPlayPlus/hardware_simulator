#pragma once

#include <cstdint>
#include <limits>
#include <map>
#include <mutex>
#include <optional>

struct RumbleCallbackData {
  uintptr_t window;
  unsigned int message;
  int token;
  int controller_id;
};

// ViGEm unregister does not join callbacks. An opaque, never-reused cookie
// avoids passing pointers to mutable or freed registration metadata.
class RumbleCallbackRegistry {
public:
  uintptr_t Register(RumbleCallbackData data) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (next_ == (std::numeric_limits<uintptr_t>::max)())
      return 0;
    const auto cookie = ++next_;
    entries_.emplace(cookie, data);
    return cookie;
  }

  std::optional<RumbleCallbackData> Lookup(uintptr_t cookie) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto entry = entries_.find(cookie);
    if (entry == entries_.end())
      return std::nullopt;
    return entry->second;
  }

  void Remove(uintptr_t cookie) {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.erase(cookie);
  }

private:
  std::mutex mutex_;
  uintptr_t next_ = 0;
  std::map<uintptr_t, RumbleCallbackData> entries_;
};
