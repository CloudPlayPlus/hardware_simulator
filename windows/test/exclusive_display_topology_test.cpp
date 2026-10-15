// 替换显示 API，执行真实独占/恢复逻辑，不改变测试机的显示配置。
#include "../virtual_display_control.h"
#include <algorithm>
#include <iostream>
#include <stdexcept>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)

namespace {
std::vector<DISPLAYCONFIG_PATH_INFO> current_paths;
std::vector<DISPLAYCONFIG_PATH_INFO> saved_paths;
std::vector<DISPLAYCONFIG_MODE_INFO> active_modes;
std::vector<DISPLAYCONFIG_MODE_INFO> saved_modes;
LONG apply_result = ERROR_SUCCESS;
bool fail_temporary = false;

LONG WINAPI TestBufferSizes(UINT32 flags, UINT32* paths, UINT32* modes) {
    *paths = static_cast<UINT32>((flags == QDC_DATABASE_CURRENT ? saved_paths : current_paths).size());
    *modes = static_cast<UINT32>((flags == QDC_DATABASE_CURRENT ? saved_modes : active_modes).size());
    return ERROR_SUCCESS;
}
LONG WINAPI TestQuery(UINT32 flags, UINT32* paths, DISPLAYCONFIG_PATH_INFO* path_data,
    UINT32* modes, DISPLAYCONFIG_MODE_INFO* mode_data, DISPLAYCONFIG_TOPOLOGY_ID* topology) {
    const auto& source_paths = flags == QDC_DATABASE_CURRENT ? saved_paths : current_paths;
    const auto& source_modes = flags == QDC_DATABASE_CURRENT ? saved_modes : active_modes;
    CHECK((flags == QDC_DATABASE_CURRENT) == (topology != nullptr));
    CHECK(*paths >= source_paths.size() && *modes >= source_modes.size());
    std::copy(source_paths.begin(), source_paths.end(), path_data);
    std::copy(source_modes.begin(), source_modes.end(), mode_data);
    *paths = static_cast<UINT32>(source_paths.size());
    *modes = static_cast<UINT32>(source_modes.size());
    return ERROR_SUCCESS;
}
LONG WINAPI TestDeviceInfo(DISPLAYCONFIG_DEVICE_INFO_HEADER* header) {
    if (header->type == DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME) {
        auto* name = reinterpret_cast<DISPLAYCONFIG_SOURCE_DEVICE_NAME*>(header);
        wcscpy_s(name->viewGdiDeviceName, header->id == 1
            ? L"\\\\.\\DISPLAY2" : L"\\\\.\\DISPLAY1");
        return ERROR_SUCCESS;
    }
    return ERROR_NOT_SUPPORTED;
}
LONG WINAPI TestApply(UINT32 count, DISPLAYCONFIG_PATH_INFO* paths,
    UINT32 mode_count, DISPLAYCONFIG_MODE_INFO* modes, UINT32 flags) {
    if (apply_result != ERROR_SUCCESS) return apply_result;
    if (fail_temporary && !(flags & SDC_SAVE_TO_DATABASE)) return ERROR_GEN_FAILURE;
    CHECK(flags & SDC_APPLY);
    current_paths.assign(paths, paths + count);
    active_modes.assign(modes, modes + mode_count);
    if (flags & SDC_SAVE_TO_DATABASE) {
        saved_paths = current_paths;
        saved_modes = active_modes;
    }
    return ERROR_SUCCESS;
}
void ExitGameFullscreen() {
    current_paths = saved_paths;
    active_modes = saved_modes;
}
bool IsActive(UINT32 source) {
    return std::any_of(current_paths.begin(), current_paths.end(), [source](const auto& path) {
        return path.sourceInfo.id == source && (path.flags & DISPLAYCONFIG_PATH_ACTIVE);
    });
}
}

#define GetDisplayConfigBufferSizes TestBufferSizes
#define QueryDisplayConfig TestQuery
#define DisplayConfigGetDeviceInfo TestDeviceInfo
#define SetDisplayConfig TestApply
#include "../virtual_display_control.cc"
#undef DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE
#undef GetDisplayConfigBufferSizes
#undef QueryDisplayConfig
#undef DisplayConfigGetDeviceInfo
#undef SetDisplayConfig

class VirtualDisplayControlTestPeer {
public:
    static void Run() {
        current_paths.resize(2);
        active_modes.resize(2);
        for (UINT32 i = 0; i < 2; ++i) {
            current_paths[i].flags = DISPLAYCONFIG_PATH_ACTIVE;
            current_paths[i].sourceInfo.id = i;
            current_paths[i].sourceInfo.modeInfoIdx = i;
            active_modes[i].infoType = DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE;
            active_modes[i].sourceMode.position.x = 1920 * i;
        }
        saved_paths = current_paths;
        saved_modes = active_modes;
        VirtualDisplay::DisplayInfo info;
        saved_modes[0].sourceMode.width = 3840;
        active_modes[0].sourceMode.width = 1920; // 游戏正在使用临时模式。
        info.device_name = "\\\\.\\DISPLAY2";
        VirtualDisplayControl::displays_.push_back(std::make_unique<VirtualDisplay>(
            VirtualDisplay::DisplayConfig(1920, 1080), info, 42));

        CHECK(VirtualDisplayControl::SetPrimaryDisplayOnly(42));
        CHECK(!IsActive(0) && IsActive(1));
        CHECK(active_modes[1].sourceMode.position.x == 0);
        ExitGameFullscreen();
        CHECK(!IsActive(0) && IsActive(1)); // 原 bug：保存布局仍启用实体屏。
        CHECK(!VirtualDisplayControl::SetPrimaryDisplayOnly(42));

        apply_result = ERROR_GEN_FAILURE;
        CHECK(!VirtualDisplayControl::RestoreDisplayConfiguration());
        CHECK(VirtualDisplayControl::HasPendingConfiguration());
        ExitGameFullscreen();
        CHECK(!IsActive(0) && IsActive(1));

        apply_result = ERROR_SUCCESS;
        fail_temporary = true;
        CHECK(!VirtualDisplayControl::RestoreDisplayConfiguration());
        CHECK(VirtualDisplayControl::HasPendingConfiguration());
        CHECK(saved_modes[0].sourceMode.width == 3840);
        fail_temporary = false;
        CHECK(VirtualDisplayControl::RestoreDisplayConfiguration());
        CHECK(!VirtualDisplayControl::HasPendingConfiguration());
        CHECK(IsActive(0) && IsActive(1));
        CHECK(active_modes[1].sourceMode.position.x == 1920);
        CHECK(active_modes[0].sourceMode.width == 1920);
        CHECK(saved_modes[0].sourceMode.width == 3840);
        ExitGameFullscreen();
        CHECK(active_modes[0].sourceMode.width == 3840);
        CHECK(IsActive(0) && IsActive(1));
        CHECK(active_modes[1].sourceMode.position.x == 1920);
        CHECK(VirtualDisplayControl::RestoreDisplayConfiguration());
        CHECK(VirtualDisplayControl::SetPrimaryDisplayOnly(42));
        VirtualDisplayControl::Shutdown();
        CHECK(!VirtualDisplayControl::HasPendingConfiguration());
        CHECK(IsActive(0) && IsActive(1));
        VirtualDisplayControl::displays_.clear();
    }
};

int main() {
    try { VirtualDisplayControlTestPeer::Run(); }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
    std::cout << "exclusive fullscreen exit and restore passed\n";
}
