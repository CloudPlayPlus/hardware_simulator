#include "windows_text_input_injector.h"

#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace hardware_simulator {

bool BuildWindowsUnicodeTextInputs(const std::string& utf8_text,
                                   std::vector<INPUT>* inputs) {
  if (inputs == nullptr || utf8_text.empty() ||
      utf8_text.size() > kMaxTextInputUtf8Bytes ||
      utf8_text.size() > static_cast<size_t>((std::numeric_limits<int>::max)())) {
    return false;
  }

  const int utf8_size = static_cast<int>(utf8_text.size());
  const int utf16_size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_text.data(), utf8_size, nullptr, 0);
  if (utf16_size <= 0) {
    return false;
  }

  std::wstring utf16(static_cast<size_t>(utf16_size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_text.data(),
                          utf8_size, utf16.data(), utf16_size) != utf16_size) {
    return false;
  }

  for (const wchar_t code_unit : utf16) {
    if (code_unit < 0x20 || code_unit == 0x7f) {
      return false;
    }
  }

  std::vector<INPUT> sequence;
  sequence.reserve(utf16.size() * 2);
  for (const wchar_t code_unit : utf16) {
    INPUT down{};
    down.type = INPUT_KEYBOARD;
    down.ki.wVk = 0;
    down.ki.wScan = static_cast<WORD>(code_unit);
    down.ki.dwFlags = KEYEVENTF_UNICODE;
    sequence.push_back(down);

    INPUT up = down;
    up.ki.dwFlags |= KEYEVENTF_KEYUP;
    sequence.push_back(up);
  }

  *inputs = std::move(sequence);
  return true;
}

}  // namespace hardware_simulator
