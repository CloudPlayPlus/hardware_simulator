// Thin runtime adapter that routes hardware_simulator's native diagnostics into
// the shared cpp_log pipeline (and therefore the same on-disk app.log as
// Dart-origin logs).
//
// The plugin does NOT link against cpp_log. The C entrypoint `cpp_log_emit` is
// resolved at runtime with GetProcAddress against the `cpp_log.dll` that Flutter
// already bundles next to this plugin's DLL in the app directory. That keeps the
// two plugins fully decoupled at link time (no import-lib dependency, no build
// ordering coupling) while still sharing one native logging channel at runtime.
//
// The macro surface deliberately mirrors cpp_log_core.h's CPPLOG / CPPLOG_* so
// call sites read identically to using cpp_log directly. Only the header path
// and backing implementation differ. The wire/on-disk line format is owned by
// cpp_log and byte-for-byte identical to the Dart side:
//   "yyyy-MM-dd HH:mm:ss.mmm [LEVEL] [TAG] message".
#ifndef HARDWARE_SIMULATOR_CPP_LOG_ADAPTER_H_
#define HARDWARE_SIMULATOR_CPP_LOG_ADAPTER_H_

namespace hwsim_log {

// Mirrors cpplog::Level. The numeric values ARE the cpp_log ABI
// (0=trace .. 4=error) and must not be renumbered — they are passed straight
// through to cpp_log_emit.
enum class Level : int {
  kTrace = 0,
  kDebug = 1,
  kInfo = 2,
  kWarn = 3,
  kError = 4,
};

// Formats (printf-style) and forwards one record to cpp_log. The native sink is
// resolved lazily on first use and cached; a no-op if cpp_log.dll is not
// present. Safe to call from any thread (cpp_log's queue is thread-safe) and at
// any time — records emitted before the Dart side installs its port sink are
// retained in cpp_log's ring buffer and flushed once the sink comes up.
void Emit(Level level, const char* tag, const char* fmt, ...);

}  // namespace hwsim_log

// Compile-time gate, mirroring cpp_log_core.h. Define HWSIM_LOG_ENABLED=0 to
// strip all CPPLOG sites in this plugin.
#ifndef HWSIM_LOG_ENABLED
#define HWSIM_LOG_ENABLED 1
#endif

#if HWSIM_LOG_ENABLED
#define CPPLOG(level, tag, ...) ::hwsim_log::Emit((level), (tag), __VA_ARGS__)
#else
#define CPPLOG(level, tag, ...) ((void)0)
#endif

// Per-level shorthands (match cpp_log_core.h).
#define CPPLOG_TRACE(tag, ...) CPPLOG(::hwsim_log::Level::kTrace, (tag), __VA_ARGS__)
#define CPPLOG_DEBUG(tag, ...) CPPLOG(::hwsim_log::Level::kDebug, (tag), __VA_ARGS__)
#define CPPLOG_INFO(tag, ...) CPPLOG(::hwsim_log::Level::kInfo, (tag), __VA_ARGS__)
#define CPPLOG_WARN(tag, ...) CPPLOG(::hwsim_log::Level::kWarn, (tag), __VA_ARGS__)
#define CPPLOG_ERROR(tag, ...) CPPLOG(::hwsim_log::Level::kError, (tag), __VA_ARGS__)

#endif  // HARDWARE_SIMULATOR_CPP_LOG_ADAPTER_H_
