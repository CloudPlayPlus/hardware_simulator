#ifndef HARDWARE_SIMULATOR_WINDOWS_CPP_LOG_SHIM_H_
#define HARDWARE_SIMULATOR_WINDOWS_CPP_LOG_SHIM_H_

#if defined(CPP_LOG_AVAILABLE)
#include <cpp_log/cpp_log.h>
#else
#include <cstdarg>
#include <cstdio>

namespace hardware_simulator {
namespace logging {

inline void FallbackLog(const char* level, const char* tag,
                        const char* format, ...) {
  char message[2048] = {};
  va_list args;
  va_start(args, format);
  std::vsnprintf(message, sizeof(message), format, args);
  va_end(args);
  std::fprintf(stderr, "[%s] [%s] %s\n", level,
               tag && *tag ? tag : "NATIVE", message);
}

}  // namespace logging
}  // namespace hardware_simulator

#define CPPLOG_TRACE(tag, ...)                                      \
  ::hardware_simulator::logging::FallbackLog("TRACE", (tag),        \
                                              __VA_ARGS__)
#define CPPLOG_DEBUG(tag, ...)                                      \
  ::hardware_simulator::logging::FallbackLog("DEBUG", (tag),        \
                                              __VA_ARGS__)
#define CPPLOG_INFO(tag, ...)                                      \
  ::hardware_simulator::logging::FallbackLog("INFO", (tag),        \
                                              __VA_ARGS__)
#define CPPLOG_WARN(tag, ...)                                      \
  ::hardware_simulator::logging::FallbackLog("WARN", (tag),        \
                                              __VA_ARGS__)
#define CPPLOG_ERROR(tag, ...)                                     \
  ::hardware_simulator::logging::FallbackLog("ERROR", (tag),       \
                                              __VA_ARGS__)
#define CPPLOG_CRITICAL(tag, ...)                                  \
  ::hardware_simulator::logging::FallbackLog("CRITICAL", (tag),    \
                                              __VA_ARGS__)
#endif

#endif  // HARDWARE_SIMULATOR_WINDOWS_CPP_LOG_SHIM_H_
