// Fallback NO-OP cpp_log client — a compile-time stand-in, NOT a copy of the
// adapter. It is used only when the real shared adapter
// (cpp_log/client/cpp_log_client.h) is absent from the include path, i.e. a
// standalone build of this plugin without cpp_log. windows/CMakeLists.txt
// selects this directory (and defines CPP_LOG_CLIENT_ENABLED=0) in that case.
//
// It provides the exact CPPLOG_* / CPPLOG_STREAM_* macro surface as no-ops so
// every plugin source compiles unchanged, with nothing to link (no runtime
// resolver, no Emit, no .cc). The real adapter with the GetProcAddress bridge
// lives in cpp_log and is referenced, never copied; this stub only stands in
// when cpp_log is not there.
#ifndef CPP_LOG_CLIENT_H_
#define CPP_LOG_CLIENT_H_

#include <ostream>

namespace cpplog_client {

// Discards everything streamed into it. Mirrors the real LogStream's operand
// surface (values + stream manipulators) so `CPPLOG_STREAM_*(tag) << a << b;`
// still parses and costs nothing.
class NullStream {
 public:
  template <typename T>
  NullStream& operator<<(const T&) {
    return *this;
  }
  NullStream& operator<<(std::ostream& (*)(std::ostream&)) { return *this; }
  NullStream& operator<<(std::ios_base& (*)(std::ios_base&)) { return *this; }
};

}  // namespace cpplog_client

// printf-style: arguments are not evaluated (matches the disabled real macros).
#define CPPLOG(level, tag, ...) ((void)0)
#define CPPLOG_TRACE(tag, ...) ((void)0)
#define CPPLOG_DEBUG(tag, ...) ((void)0)
#define CPPLOG_INFO(tag, ...) ((void)0)
#define CPPLOG_WARN(tag, ...) ((void)0)
#define CPPLOG_ERROR(tag, ...) ((void)0)

// stream-style: yields a sink that swallows the << chain.
#define CPPLOG_STREAM(level, tag) ::cpplog_client::NullStream()
#define CPPLOG_STREAM_TRACE(tag) ::cpplog_client::NullStream()
#define CPPLOG_STREAM_DEBUG(tag) ::cpplog_client::NullStream()
#define CPPLOG_STREAM_INFO(tag) ::cpplog_client::NullStream()
#define CPPLOG_STREAM_WARN(tag) ::cpplog_client::NullStream()
#define CPPLOG_STREAM_ERROR(tag) ::cpplog_client::NullStream()

#endif  // CPP_LOG_CLIENT_H_
