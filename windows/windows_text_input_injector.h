#ifndef HARDWARE_SIMULATOR_WINDOWS_TEXT_INPUT_INJECTOR_H_
#define HARDWARE_SIMULATOR_WINDOWS_TEXT_INPUT_INJECTOR_H_

#include <windows.h>

#include <string>
#include <vector>

namespace hardware_simulator {

constexpr size_t kMaxTextInputUtf8Bytes = 4096;

// Builds the exact INPUT_KEYBOARD sequence used for committed IME text.
// Returns false without producing a partial sequence when UTF-8 is malformed,
// empty, over the protocol limit, or contains C0/DEL control characters.
bool BuildWindowsUnicodeTextInputs(const std::string& utf8_text,
                                   std::vector<INPUT>* inputs);

}  // namespace hardware_simulator

#endif  // HARDWARE_SIMULATOR_WINDOWS_TEXT_INPUT_INJECTOR_H_
