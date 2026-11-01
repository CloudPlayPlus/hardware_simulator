#pragma once

#include <cstdint>
#include <functional>
#include <string>

// 所有调用和回调都在 GLib platform context；准备阶段不注入任何文本。
namespace linux_text_input {
using Completion = std::function<void(bool)>;
using Prepared = std::function<void(uint64_t)>;
bool valid_text(const std::string& text);
void available(Completion done);
void prepare(Prepared done);
void finish(uint64_t token, int backspaces, const std::string& text,
            Completion done);
}
