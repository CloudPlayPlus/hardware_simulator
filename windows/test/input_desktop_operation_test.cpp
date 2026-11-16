#include <windows.h>
#include <functional>
#include <thread>
#include <stdexcept>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

namespace {
const DWORD caller = GetCurrentThreadId();
bool open_ok = true;
bool attach_ok = true;
int opens = 0, closes = 0, calls = 0;
thread_local bool attached = false;
HDESK WINAPI TestOpen(DWORD, BOOL inherit, ACCESS_MASK) {
  CHECK(GetCurrentThreadId() != caller);
  CHECK(!inherit);
  ++opens;
  if (!open_ok) { SetLastError(ERROR_ACCESS_DENIED); return nullptr; }
  return reinterpret_cast<HDESK>(123);
}
BOOL WINAPI TestAttach(HDESK desktop) {
  CHECK(GetCurrentThreadId() != caller);
  CHECK(desktop == reinterpret_cast<HDESK>(123));
  if (!attach_ok) { SetLastError(ERROR_BUSY); return FALSE; }
  attached = true;
  return TRUE;
}
BOOL WINAPI TestClose(HDESK desktop) {
  CHECK(GetCurrentThreadId() == caller);
  CHECK(desktop == reinterpret_cast<HDESK>(123));
  ++closes;
  return TRUE;
}
}
#define OpenInputDesktop TestOpen
#define SetThreadDesktop TestAttach
#define CloseDesktop TestClose
#include "../input_desktop_operation.h"
#undef OpenInputDesktop
#undef SetThreadDesktop
#undef CloseDesktop

int main() {
  CHECK(RunDisplayOperationOnInputDesktop([&] {
    CHECK(GetCurrentThreadId() == caller);
    CHECK(!attached);
    return true;
  }, false));
  CHECK(opens == 0 && closes == 0);

  const auto operation = [&] {
    CHECK(GetCurrentThreadId() != caller);
    CHECK(attached);
    ++calls;
    return true;
  };
  CHECK(RunDisplayOperationOnInputDesktop(operation, true));
  CHECK(calls == 1 && opens == 1 && closes == 1 && !attached);
  CHECK(!RunDisplayOperationOnInputDesktop([] { return false; }, true));
  CHECK(closes == 2);
  open_ok = false;
  CHECK(!RunDisplayOperationOnInputDesktop(operation, true));
  CHECK(calls == 1 && closes == 2);
  open_ok = true;
  attach_ok = false;
  CHECK(!RunDisplayOperationOnInputDesktop(operation, true));
  CHECK(calls == 1 && closes == 3);
  attach_ok = true;
  CHECK(RunDisplayOperationOnInputDesktop(operation, true));
  CHECK(calls == 2 && closes == 4 && !attached);
  return 0;
}
