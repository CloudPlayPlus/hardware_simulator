#ifndef HARDWARE_SIMULATOR_WINDOWS_CPP_LOG_SHIM_H_
#define HARDWARE_SIMULATOR_WINDOWS_CPP_LOG_SHIM_H_

#if defined(CPP_LOG_AVAILABLE)
#include <cpp_log/cpp_log.h>
#else
#define CPPLOG_TRACE(tag, ...) ((void)0)
#define CPPLOG_DEBUG(tag, ...) ((void)0)
#define CPPLOG_INFO(tag, ...) ((void)0)
#define CPPLOG_WARN(tag, ...) ((void)0)
#define CPPLOG_ERROR(tag, ...) ((void)0)
#define CPPLOG_CRITICAL(tag, ...) ((void)0)
#endif

#endif  // HARDWARE_SIMULATOR_WINDOWS_CPP_LOG_SHIM_H_
