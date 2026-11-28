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
std::vector<DISPLAYCONFIG_PATH_INFO> available_paths;
bool ignore_apply = false;
bool fail_temporary = false;
bool reject_supplied_target = false;

LONG WINAPI TestBufferSizes(UINT32 flags, UINT32* paths, UINT32* modes) {
    *paths = static_cast<UINT32>((flags == QDC_DATABASE_CURRENT ? saved_paths :
        (flags & QDC_ALL_PATHS) ? available_paths : current_paths).size());
    *modes = static_cast<UINT32>((flags == QDC_DATABASE_CURRENT ? saved_modes : active_modes).size());
    return ERROR_SUCCESS;
}
LONG WINAPI TestQuery(UINT32 flags, UINT32* paths, DISPLAYCONFIG_PATH_INFO* path_data,
    UINT32* modes, DISPLAYCONFIG_MODE_INFO* mode_data, DISPLAYCONFIG_TOPOLOGY_ID* topology) {
    const auto& source_paths = flags == QDC_DATABASE_CURRENT ? saved_paths :
        (flags & QDC_ALL_PATHS) ? available_paths : current_paths;
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
    if (header->type == DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME) {
        auto* name = reinterpret_cast<DISPLAYCONFIG_TARGET_DEVICE_NAME*>(header);
        wcscpy_s(name->monitorDevicePath, header->adapterId.LowPart == 23 && header->id == 14
            ? L"\\\\?\\display#psccdd0#5&0&uId256#{abc}"
            : L"\\\\?\\display#physical#5&0&UID256#{abc}");
        return ERROR_SUCCESS;
    }
    return ERROR_NOT_SUPPORTED;
}
LONG WINAPI TestApply(UINT32 count, DISPLAYCONFIG_PATH_INFO* paths,
    UINT32 mode_count, DISPLAYCONFIG_MODE_INFO* modes, UINT32 flags) {
    if (flags & SDC_VALIDATE) return ERROR_SUCCESS;
    if (ignore_apply) return ERROR_SUCCESS;
    if (apply_result != ERROR_SUCCESS) return apply_result;
    if (reject_supplied_target) {
        UINT32 active = 0; const DISPLAYCONFIG_PATH_INFO* target = nullptr;
        for (UINT32 i = 0; i < count; ++i) if (paths[i].flags & DISPLAYCONFIG_PATH_ACTIVE) { ++active; target = &paths[i]; }
        if (active == 1 && target->targetInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID)
            return ERROR_GEN_FAILURE;
    }
    if (fail_temporary && !(flags & SDC_SAVE_TO_DATABASE)) return ERROR_GEN_FAILURE;
    CHECK(flags & SDC_APPLY);
    current_paths.assign(paths, paths + count);
    active_modes.clear();
    if (mode_count) active_modes.assign(modes, modes + mode_count);
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
        // 目标时序被驱动拒绝时，保留源尺寸重选目标时序；原备份必须完整恢复。
        DISPLAYCONFIG_MODE_INFO target_mode{};
        target_mode.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_TARGET;
        current_paths[1].targetInfo.modeInfoIdx = static_cast<UINT32>(active_modes.size());
        active_modes.push_back(target_mode);
        saved_paths = current_paths; saved_modes = active_modes;
        reject_supplied_target = true;
        CHECK(VirtualDisplayControl::SetPrimaryDisplayOnly(42));
        CHECK(current_paths.size() == 1 && active_modes.size() == 1);
        CHECK(current_paths[0].sourceInfo.id == 1 && current_paths[0].sourceInfo.modeInfoIdx == 0);
        CHECK(current_paths[0].targetInfo.modeInfoIdx == DISPLAYCONFIG_PATH_MODE_IDX_INVALID);
        CHECK(active_modes[0].sourceMode.position.x == 0);
        CHECK(VirtualDisplayControl::RestoreDisplayConfiguration());
        CHECK(current_paths.size() == 2 && active_modes.size() == 3);
        CHECK(current_paths[1].targetInfo.modeInfoIdx == 2);
        reject_supplied_target = false;
        // 同一个源、同号 target（不同适配器），即使实体屏排第一也只选本次 VDD。
        exclusive_created_uid = 0;
        VirtualDisplay::DisplayInfo inserted{};
        inserted.is_virtual = true;
        inserted.active = true;
        inserted.raw_screen_id = 0;
        inserted.device_name = R"(\\.\DISPLAY1)";
        VirtualDisplayControl::displays_.push_back(std::make_unique<VirtualDisplay>(
            VirtualDisplay::DisplayConfig(1920, 1080), inserted, 0));
        current_paths[0].targetInfo.id = current_paths[1].targetInfo.id = 14;
        current_paths[1].targetInfo.adapterId.LowPart = 23;
        current_paths[0].sourceInfo.id = current_paths[1].sourceInfo.id = 0;
        for (auto& p : current_paths) p.targetInfo.targetAvailable = TRUE;
        saved_paths = available_paths = current_paths;
        pre_insert_paths = {current_paths.front()};
        pre_insert_modes = active_modes;
        CHECK(VirtualDisplayControl::SetPrimaryDisplayOnly(0));
        CHECK(current_paths.size() == 1 && current_paths[0].targetInfo.adapterId.LowPart == 23);
        CHECK(VirtualDisplayControl::VerifyExclusiveTarget(0));
        CHECK(VirtualDisplayControl::RestoreDisplayConfiguration());
        CHECK(current_paths.size() == 1 && current_paths[0].targetInfo.adapterId.LowPart == 0);
        CHECK(saved_paths.size() == 2);
        // 目标只存在于全部候选路径中。驱动返回成功但活动布局未改变时必须失败并可恢复。
        available_paths[1].flags = 0;
        ignore_apply = true;
        CHECK(!VirtualDisplayControl::SetPrimaryDisplayOnly(0));
        ignore_apply = false;
        CHECK(VirtualDisplayControl::RestoreDisplayConfiguration());
        CHECK(VirtualDisplayControl::SetPrimaryDisplayOnly(0));
        CHECK(VirtualDisplayControl::VerifyExclusiveTarget(0));
        CHECK(VirtualDisplayControl::RestoreDisplayConfiguration());
        VirtualDisplayControl::displays_.clear();
    }
};

int main() {
    try { VirtualDisplayControlTestPeer::Run(); }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
    std::cout << "exclusive fullscreen exit and restore passed\n";
}
