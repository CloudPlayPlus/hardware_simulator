#include "../display_handoff_ready.h"
#include <stdexcept>
#include <vector>
#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

int main() {
    // 同一个已取得句柄的恢复过程：驱动暂时不可用、枚举尚无目标、最终成功。
    bool initialized = false, visible = false;
    int attempts = 0;
    std::vector<int> managed;
    const auto initialize = [&] { ++attempts; return initialized; };
    const auto enumerate = [&] {
        managed.clear();
        if (visible) managed.push_back(3);
        return !managed.empty();
    };
    CHECK(PrepareRecoveredDisplay(initialize, enumerate) == ERROR_NOT_READY);
    CHECK(managed.empty());
    initialized = true;
    CHECK(PrepareRecoveredDisplay(initialize, enumerate) == ERROR_NOT_FOUND);
    visible = true;
    CHECK(PrepareRecoveredDisplay(initialize, enumerate) == ERROR_SUCCESS);
    CHECK(attempts == 3 && managed == std::vector<int>{3});
    // 已缓存元数据也要再次检查当前枚举，不把失去的屏幕报告为可操作。
    visible = false;
    CHECK(PrepareRecoveredDisplay(initialize, enumerate) == ERROR_NOT_FOUND);
    CHECK(managed.empty());
}
