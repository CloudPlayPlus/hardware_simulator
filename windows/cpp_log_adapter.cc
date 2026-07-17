// Runtime bridge from hardware_simulator's CPPLOG macros to cpp_log. See
// cpp_log_adapter.h for the rationale (no link-time coupling; GetProcAddress
// against the bundled cpp_log.dll).

#include "cpp_log_adapter.h"

#include <windows.h>

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <string>

// cpp_log's stable C ABI. Included so the plugin builds against cpp_log's own
// header — the single source of truth for the emit signature. We take only its
// *type* (via decltype, an unevaluated context) and never reference the
// dllimport symbol directly, so no cpp_log.lib is needed at link time; the
// function is resolved dynamically at runtime instead.
#include "cpp_log_c.h"

namespace hwsim_log {
namespace {

// Exact type of the resolved entrypoint, kept in lockstep with cpp_log's header:
//   void cpp_log_emit(int32_t level, const char* tag, const char* msg);
using CppLogEmitFn = decltype(&cpp_log_emit);

// Cached once resolved. Stays null (retrying on each call) until cpp_log.dll is
// available, then pinned for the process lifetime.
std::atomic<CppLogEmitFn> g_emit{nullptr};

CppLogEmitFn ResolveEmit() {
  CppLogEmitFn fn = g_emit.load(std::memory_order_acquire);
  if (fn != nullptr) {
    return fn;
  }
  // cpp_log.dll is bundled next to this plugin DLL in the app directory. Prefer
  // the already-loaded module (opened by Dart's DynamicLibrary.open or a prior
  // resolve here); otherwise LoadLibrary finds it via the app's DLL search path.
  // GetModuleHandleW does not bump the refcount; the one-time LoadLibraryW does,
  // intentionally pinning cpp_log.dll for the process lifetime.
  HMODULE mod = ::GetModuleHandleW(L"cpp_log.dll");
  if (mod == nullptr) {
    mod = ::LoadLibraryW(L"cpp_log.dll");
  }
  if (mod == nullptr) {
    return nullptr;
  }
  fn = reinterpret_cast<CppLogEmitFn>(::GetProcAddress(mod, "cpp_log_emit"));
  if (fn != nullptr) {
    g_emit.store(fn, std::memory_order_release);
  }
  return fn;
}

}  // namespace

void Emit(Level level, const char* tag, const char* fmt, ...) {
  const CppLogEmitFn emit = ResolveEmit();
  if (emit == nullptr) {
    return;  // cpp_log.dll not present → silently no-op.
  }

  // printf-style formatting on a stack buffer, growing to the heap only for the
  // rare oversized record. Mirrors cpplog::Logf so behaviour is consistent.
  char stackbuf[512];
  va_list args;
  va_start(args, fmt);
  const int needed = std::vsnprintf(stackbuf, sizeof(stackbuf), fmt, args);
  va_end(args);
  if (needed < 0) {
    return;
  }

  const int32_t lvl = static_cast<int32_t>(level);
  if (static_cast<size_t>(needed) < sizeof(stackbuf)) {
    emit(lvl, tag, stackbuf);
    return;
  }

  std::string big(static_cast<size_t>(needed) + 1, '\0');
  va_start(args, fmt);
  std::vsnprintf(&big[0], big.size(), fmt, args);
  va_end(args);
  big.resize(static_cast<size_t>(needed));
  emit(lvl, tag, big.c_str());
}

}  // namespace hwsim_log
