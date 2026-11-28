#include "virtual_display_control.h"
#include "desktop_service_input_client.h"
#include "cpp_log_shim.h"
#include "input_desktop_operation.h"
#include "display_handoff_ready.h"
#if defined(CLOUDPLAYPLUS_SERVICE_CONSOLE_RECOVERY)
#include "unattended_runtime.h"
#include "display_handoff.h"
#endif
#include <iostream>
#include <thread>
#include <mutex>
#include <chrono>
#include <algorithm>
#include <cstring>
#include <cctype>
#include <cstdio>

#define INITGUID
#include <windows.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <devpkey.h>    // DEVPKEY_Device_*
#include <winuser.h>    // DisplayConfig APIs
#include <wtsapi32.h>   // WTSQuerySessionInformation (linked via CMake)

// Define missing constants for older Windows SDK versions
#ifndef DISPLAYCONFIG_PATH_PRIMARY_VIEW
#define DISPLAYCONFIG_PATH_PRIMARY_VIEW 0x00000001
#endif

#ifndef DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE
#define DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE 1
#endif

#include <string>
#include <vector>
#include <map>
#include <set>
#include <functional>
#include <algorithm>
#include "virtual_display.h"

bool VirtualDisplayControl::initialized_ = false;
HANDLE VirtualDisplayControl::vdd_handle_ = INVALID_HANDLE_VALUE;
std::vector<std::unique_ptr<VirtualDisplay>> VirtualDisplayControl::displays_;

// Display configuration backup for restore functionality
std::vector<DISPLAYCONFIG_PATH_INFO> VirtualDisplayControl::original_paths_;
std::vector<DISPLAYCONFIG_MODE_INFO> VirtualDisplayControl::original_modes_;
std::vector<DISPLAYCONFIG_PATH_INFO> VirtualDisplayControl::persistent_paths_;
std::vector<DISPLAYCONFIG_MODE_INFO> VirtualDisplayControl::persistent_modes_;
bool VirtualDisplayControl::has_backup_ = false;

namespace {
#if defined(CLOUDPLAYPLUS_SERVICE_CONSOLE_RECOVERY)
cloudplayplus::unattended::DisplayHandoffData handed_display;
bool IsManagedDisplayClient() {
    const auto state = cloudplayplus::unattended::Store().ReadState();
    return state.enabled && state.committed &&
        state.managed == cloudplayplus::unattended::CurrentProcessIdentity();
}
void ReleaseHandedDisplay(int uid) {
    if (!handed_display.present || handed_display.uid != static_cast<UINT32>(uid)) return;
    try {
        cloudplayplus::unattended::ExchangeDisplayHandoff(
            cloudplayplus::unattended::Command::release_display, handed_display);
        handed_display = {};
        CPPLOG_INFO("VDD_HANDOFF", "released service custody uid=%d", uid);
    } catch (const cloudplayplus::unattended::Error& error) {
        CPPLOG_WARN("VDD_HANDOFF", "release custody failed uid=%d error=%lu", uid, error.code);
    }
}
#endif

// 只在本进程创建/领取的独占 UID 上使用目标路径，管理页仍可操作普通显示器。
int exclusive_created_uid = -1;
VirtualDisplay::DisplayConfig exclusive_requested_mode;
std::vector<DISPLAYCONFIG_PATH_INFO> pre_insert_paths;
std::vector<DISPLAYCONFIG_MODE_INFO> pre_insert_modes;

bool QueryLayout(UINT32 flags, std::vector<DISPLAYCONFIG_PATH_INFO>& paths,
                 std::vector<DISPLAYCONFIG_MODE_INFO>& modes, bool allow_empty = false) {
    for (int attempt = 0; attempt < 5; ++attempt) {
        UINT32 path_count = 0, mode_count = 0;
        const LONG sizes = GetDisplayConfigBufferSizes(flags, &path_count, &mode_count);
        if (sizes != ERROR_SUCCESS) {
            CPPLOG_WARN("VDD_MODE", "snapshot sizes flags=%u status=%ld", flags, sizes);
            return false;
        }
        paths.resize(path_count);
        modes.resize(mode_count);
        if (!path_count) return allow_empty;
        DISPLAYCONFIG_TOPOLOGY_ID topology{};
        LONG result = QueryDisplayConfig(flags, &path_count, paths.data(), &mode_count,
            modes.data(), flags == QDC_DATABASE_CURRENT ? &topology : nullptr);
        if (result == ERROR_INSUFFICIENT_BUFFER) continue;
        if (result != ERROR_SUCCESS || (!allow_empty && !path_count)) {
            CPPLOG_WARN("VDD_MODE", "snapshot query flags=%u status=%ld paths=%u modes=%u",
                flags, result, path_count, mode_count);
            return false;
        }
        paths.resize(path_count);
        modes.resize(mode_count);
        return true;
    }
    return false;
}

struct LuidCompare {
    bool operator()(const LUID& a, const LUID& b) const {
        if (a.HighPart != b.HighPart) {
            return a.HighPart < b.HighPart;
        }
        return a.LowPart < b.LowPart;
    }
};

static std::string WideStringToString(const std::wstring& wstr) {
    if (wstr.empty()) return std::string();
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), nullptr, 0, nullptr, nullptr);
    std::string strTo(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), &strTo[0], size_needed, nullptr, nullptr);
    return strTo;
}
static std::wstring StringToWideString(const std::string& str) {
    if (str.empty()) return std::wstring();
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), nullptr, 0);
    std::wstring wstrTo(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), &wstrTo[0], size_needed);
    return wstrTo;
}

static std::vector<std::string> GetDisplayPaths() {
    std::vector<std::string> paths;
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
        L"SYSTEM\\CurrentControlSet\\Services\\monitor\\Enum",
        0, KEY_READ, &hKey) == ERROR_SUCCESS)
    {
        DWORD count = 0, type = 0, size = sizeof(count);
        if (RegQueryValueExW(hKey, L"Count", nullptr, &type,
                             reinterpret_cast<BYTE*>(&count), &size) == ERROR_SUCCESS)
        {
            for (DWORD i = 0; i < count; ++i) {
                wchar_t name[16]; swprintf_s(name, L"%u", i);
                DWORD bufSize = 0;
                if (RegQueryValueExW(hKey, name, nullptr, nullptr, nullptr, &bufSize) == ERROR_SUCCESS) {
                    std::wstring val; val.resize(bufSize / sizeof(wchar_t));
                    if (RegQueryValueExW(hKey, name, nullptr, nullptr,
                                         reinterpret_cast<BYTE*>(&val[0]), &bufSize) == ERROR_SUCCESS)
                    {
                        if (!val.empty() && val.back() == L'\0') val.pop_back();
                        std::string pathStr = WideStringToString(val);
                        paths.push_back(pathStr);
                    }
                }
            }
        }
        RegCloseKey(hKey);
    }
    return paths;
}

static int ParseDisplayAddress(const std::string& path) {
    auto pos = path.find("UID");
    if (pos != std::string::npos) {
   
        std::string uidStr = path.substr(pos + 3); 
        size_t endPos = 0;
        while (endPos < uidStr.length() && std::isdigit(uidStr[endPos])) {
            endPos++;
        }
        if (endPos > 0) {
            try {
                std::string numberStr = uidStr.substr(0, endPos);
                return std::stoi(numberStr);
            } catch(const std::exception& e) {
                std::cout << "ParseDisplayAddress: Error parsing number: " << e.what() << std::endl;
            }
        }
    }
    return 0;
}

static std::string ParseDisplayCode(const std::string& id) {
    std::vector<std::string> tok;
    size_t start = 0;
    while (true) {
        auto pos = id.find('#', start);
        tok.push_back(id.substr(start, pos - start));
        if (pos == std::string::npos) break;
        start = pos + 1;
    }
    return tok.size() >= 2 ? tok[1] : tok[0];
}

static bool GetDeviceInstance(const std::string& deviceId, DEVINST& dev_inst) {
    std::wstring w_device_id = StringToWideString(deviceId);

    CONFIGRET cr = CM_Locate_DevNodeW(
        &dev_inst,
        const_cast<wchar_t*>(w_device_id.c_str()),
        0
    );
    
    return (cr == CR_SUCCESS);
}

static bool GetDeviceLastArrival(DEVINST dev_inst, FILETIME& last_arrival) {
    DEVPROPKEY key = DEVPKEY_Device_LastArrivalDate;
    DEVPROPTYPE propType;
    LONGLONG fileTimeValue;
    ULONG bufferSize = sizeof(LONGLONG);

    CONFIGRET cr = CM_Get_DevNode_PropertyW(
        dev_inst,
        &key,
        &propType,
        reinterpret_cast<PBYTE>(&fileTimeValue),
        &bufferSize,
        0
    );
    
    if (cr == CR_SUCCESS) {
        last_arrival.dwLowDateTime = (DWORD)(fileTimeValue & 0xFFFFFFFF);
        last_arrival.dwHighDateTime = (DWORD)(fileTimeValue >> 32);
        return true;
    }
    
    last_arrival.dwLowDateTime = 0;
    last_arrival.dwHighDateTime = 0;
    return false;
}

static bool GetParentDeviceInstance(DEVINST dev_inst, DEVINST& parent_inst, std::string& parent_id) {
    CONFIGRET cr = CM_Get_Parent(
        &parent_inst,
        dev_inst,
        0
    );
    if (cr != CR_SUCCESS) return false;

    wchar_t idBuffer[MAX_DEVICE_ID_LEN] = {0};
    cr = CM_Get_Device_IDW(
        parent_inst,
        idBuffer,
        MAX_DEVICE_ID_LEN,
        0
    );
    if (cr != CR_SUCCESS) return false;

    std::wstring w_parent_id(idBuffer);
    parent_id = WideStringToString(w_parent_id);
    return true;
}

static bool GetDeviceDescription(DEVINST dev_inst, std::string& description) {
    DEVPROPKEY key = DEVPKEY_Device_DeviceDesc;
    DEVPROPTYPE propType;
    wchar_t buffer[256] = {0};
    ULONG bufferSize = sizeof(buffer);

    CONFIGRET cr = CM_Get_DevNode_PropertyW(
        dev_inst,
        &key,
        &propType,
        reinterpret_cast<PBYTE>(buffer),
        &bufferSize,
        0
    );
    
    if (cr == CR_SUCCESS && propType == DEVPROP_TYPE_STRING) {
        std::wstring wDescription(buffer);
        description = WideStringToString(wDescription);
        return true;
    }
    
    description = "";
    return false;
}

static std::string FileTimeToString(const FILETIME& ft) {
    if (ft.dwLowDateTime == 0 && ft.dwHighDateTime == 0) {
        return "Unknown";
    }
    
    SYSTEMTIME st;
    if (!FileTimeToSystemTime(&ft, &st)) {
        return "Invalid";
    }
    
    char buffer[64];
    sprintf_s(buffer, sizeof(buffer), 
        "%04d-%02d-%02d %02d:%02d:%02d UTC",
        st.wYear, st.wMonth, st.wDay,
        st.wHour, st.wMinute, st.wSecond);
    
    return std::string(buffer);
}

// Helper function to get display target name
static std::wstring GetDisplayTargetName(LUID adapterId, UINT32 targetId) {
    DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = {};
    targetName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
    targetName.header.size = sizeof(targetName);
    targetName.header.adapterId = adapterId;
    targetName.header.id = targetId;

    if (DisplayConfigGetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*)&targetName) != ERROR_SUCCESS) {
        return L"Unknown";
    }
    return std::wstring(targetName.monitorFriendlyDeviceName);
}

}

namespace {

// True if the current session/desktop has at least one active display adapter.
// Note: EnumDisplayDevices reflects the calling process's session context, so this
// is meaningful only when the process runs in the target (console) session — which
// is the Phase 1 assumption (plugin runs in the session-1 GUI process).
static bool HasActiveDisplay() {
    DISPLAY_DEVICEW dd = {};
    dd.cb = sizeof(dd);
    for (DWORD i = 0; EnumDisplayDevicesW(nullptr, i, &dd, 0); ++i) {
        if (dd.StateFlags & DISPLAY_DEVICE_ACTIVE) return true;
    }
    return false;
}

// 只把本进程自己的会话作为切回 Console 的目标；不再枚举“任意断开用户”，
// 避免（尤其是 SYSTEM 实例）把其他用户的会话切到物理显示器。Returns 0 if unknown.
static DWORD OwnSession() {
    DWORD session = 0;
    return ProcessIdToSessionId(GetCurrentProcessId(), &session) ? session : 0;
}

// True if an RDP session is currently active. tscon /dest:console would disconnect
// it, so we must yield when one is present. Primary check: client protocol type ==
// RDP (2); fallback: WinStation name prefix "RDP-".
static bool HasActiveRdpSession() {
    WTS_SESSION_INFOW* sessions = nullptr;
    DWORD count = 0;
    if (!WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, &sessions, &count))
        return false;

    bool found = false;
    for (DWORD i = 0; i < count && !found; ++i) {
        if (sessions[i].State != WTSActive) continue;

        USHORT* pProto = nullptr;
        DWORD bytes = 0;
        if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, sessions[i].SessionId,
                                        WTSClientProtocolType,
                                        reinterpret_cast<LPWSTR*>(&pProto), &bytes)) {
            if (pProto && *pProto == 2) found = true;  // WTS_PROTOCOL_TYPE_RDP
            WTSFreeMemory(pProto);
        }
        if (!found && sessions[i].pWinStationName &&
            wcsncmp(sessions[i].pWinStationName, L"RDP-", 4) == 0) {
            found = true;
        }
    }
    WTSFreeMemory(sessions);
    return found;
}

// Reconnect the given session to the physical console via `tscon`.
static bool RunTscon(DWORD sid) {
#if defined(CLOUDPLAYPLUS_SERVICE_CONSOLE_RECOVERY)
    DWORD caller_session = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &caller_session) || sid != caller_session) {
        CPPLOG_WARN("RDP_RECOVERY", "Console recovery rejected non-caller session=%lu", sid);
        return false;
    }
    try {
        // 服务切回本进程会话后锁屏；远端在串流画面中解锁。
        cloudplayplus::unattended::RestoreOwnConsoleAndLock();
        return true;
    } catch (const cloudplayplus::unattended::Error& failure) {
        CPPLOG_WARN("RDP_RECOVERY", "Service console recovery failed session=%lu error=%lu", sid, failure.code);
        return false;
    }
#else
    static_cast<void>(sid);
    CPPLOG_WARN("RDP_RECOVERY", "Console recovery unavailable without desktop service SDK");
    return false;
#endif
}

}  // namespace

// Ensure the target interactive session is on the console so its VDD display is
// visible. The existing Initialize()/AddDisplay() flow is unchanged; this only
// switches the console when there is no display available AND doing so won't
// disconnect an active RDP session. Root cause: a VDD binds to the console
// session, so a target session that is not on the console has no visible display.
bool VirtualDisplayControl::EnsureConsoleForDisplay() {
    // Serialize: at most one tscon console-switch at a time. WTSConnectSession
    // concurrency is undocumented and the console hosts a single session, so
    // concurrent callers (e.g. two viewers starting at once) block here; the
    // HasActiveDisplay() re-check below then returns early once the in-flight
    // switch has made a display available — no redundant/parallel tscon, and a
    // `true` return still means the console is ready. This runs on a worker
    // thread (see the method-channel handler), so blocking here never freezes
    // the platform thread.
    static std::mutex switch_mutex;
    std::lock_guard<std::mutex> lock(switch_mutex);

    if (HasActiveDisplay()) {
        std::cout << "[VDD] EnsureConsoleForDisplay: display already available" << std::endl;
        return true;
    }

    DWORD target = OwnSession();
    if (target == 0) {
        std::cout << "[VDD] EnsureConsoleForDisplay: no interactive session" << std::endl;
        return false;
    }

    DWORD console = WTSGetActiveConsoleSessionId();
    if (console == target) {
        std::cout << "[VDD] EnsureConsoleForDisplay: target session " << target
                  << " already on console; leaving display to AddDisplay" << std::endl;
        return true;
    }

    if (HasActiveRdpSession()) {
        std::cout << "[VDD] EnsureConsoleForDisplay: active RDP session present, "
                     "yielding (skip tscon)" << std::endl;
        return false;
    }

    std::cout << "[VDD] EnsureConsoleForDisplay: switching session " << target
              << " to console (was " << console << ")" << std::endl;
    return RunTscon(target);
}

bool VirtualDisplayControl::Initialize() {
    if (initialized_) {
        std::cout << "VirtualDisplayControl already initialized" << std::endl;
        return true;
    }

    EnsureConsoleForDisplay();

    parsec_vdd::DeviceStatus status = parsec_vdd::QueryDeviceStatus(&parsec_vdd::VDD_CLASS_GUID, parsec_vdd::VDD_HARDWARE_ID);
    
    //TODOXU:return value to check?
    switch (status) {
        case parsec_vdd::DEVICE_OK:
            break;
        case parsec_vdd::DEVICE_NOT_INSTALLED:
            return false;
        case parsec_vdd::DEVICE_DISABLED:
            return false;
        case parsec_vdd::DEVICE_RESTART_REQUIRED:
            break;
        default:
            CPPLOG_WARN("VDD_RECOVERY", "Parsec initialization rejected device status=%d", status);
            return false;
    }
    
    if (vdd_handle_ == NULL || vdd_handle_ == INVALID_HANDLE_VALUE)
        vdd_handle_ = parsec_vdd::OpenDeviceHandle(&parsec_vdd::VDD_ADAPTER_GUID);
    
    if (vdd_handle_ == NULL || vdd_handle_ == INVALID_HANDLE_VALUE) {
        std::cout << "Error: Failed to open Parsec VDD device handle" << std::endl;
        return false;
    }
    
    int version = parsec_vdd::VddVersion(vdd_handle_);
    if (version >= 0) {
        std::cout << "Parsec VDD initialized successfully, version: " << version << std::endl;
    } else {
        std::cout << "Warning: Failed to get VDD version" << std::endl;
    }
    
    initialized_ = true;
    displays_.clear();
    
    std::thread updater([]() {
        while (initialized_ && vdd_handle_ != INVALID_HANDLE_VALUE) {
            //handle any potential issues with vdd_handle_ here
            parsec_vdd::VddUpdate(vdd_handle_);
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });
    updater.detach();
    return true;
}

void VirtualDisplayControl::Shutdown() {
    // 先恢复，失败保留虚拟屏与备份供重试。
    if (!RestoreDisplayConfiguration()) return;
    if (!initialized_) {
        return;
    }
    
    for (auto& display : displays_) {
        parsec_vdd::VddRemoveDisplay(vdd_handle_, display->GetDisplayUid());
    }
    
    if (vdd_handle_ != INVALID_HANDLE_VALUE) {
        parsec_vdd::CloseDeviceHandle(vdd_handle_);
        vdd_handle_ = INVALID_HANDLE_VALUE;
    }
    
    initialized_ = false;
    exclusive_created_uid = -1;
    pre_insert_paths.clear();
    pre_insert_modes.clear();
    displays_.clear();
}

int VirtualDisplayControl::AddDisplay(bool exclusive, VirtualDisplay::DisplayConfig requested) {
    if (!initialized_ || vdd_handle_ == INVALID_HANDLE_VALUE) {
        std::cout << "Error: VirtualDisplayControl not initialized" << std::endl;
        return -1;
    }

    if (exclusive && (has_backup_ || exclusive_created_uid >= 0 ||
        !RunDisplayOperationOnInputDesktop([] {
            return QueryLayout(QDC_ONLY_ACTIVE_PATHS, pre_insert_paths, pre_insert_modes, true);
        }))) return -1;

    int vdd_index = parsec_vdd::VddAddDisplay(vdd_handle_);
    if (vdd_index >= 0) {
        if (exclusive) {
            exclusive_created_uid = vdd_index;
            exclusive_requested_mode = requested;
            return vdd_index;
        }
        std::cout << "Virtual display added: " << vdd_index << std::endl;
        // The virtual display may take a moment to be enumerated by the OS,
        // especially on headless servers. Retry until it becomes visible.
        int prev_count = static_cast<int>(displays_.size());
        int new_count = prev_count;
        for (int attempt = 0; attempt < 5; ++attempt) {
            if (attempt > 0) {
                Sleep(500);
            }
            new_count = VirtualDisplayControl::GetAllDisplays();
            if (new_count > prev_count) {
                break;
            }
        }
        if (new_count <= prev_count) {
            std::cout << "Warning: added display index=" << vdd_index
                      << " but it was never enumerated" << std::endl;
        }
        return vdd_index;
    } else {
        std::cout << "Error: Failed to add display to VDD" << std::endl;
        return -1;
    }
}

bool VirtualDisplayControl::RemoveDisplay(int display_uid) {
    if (!initialized_ || vdd_handle_ == INVALID_HANDLE_VALUE) {
        std::cout << "Error: VirtualDisplayControl not initialized" << std::endl;
        return false;
    }

    std::cout << "get remove call with id" << display_uid << std::endl;
    
    auto it = std::find_if(displays_.begin(), displays_.end(), 
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display->GetDisplayUid() == display_uid;
        });
    
    const bool owned = display_uid >= 0 && display_uid == exclusive_created_uid;
    if (!owned && (it == displays_.end() || !(*it)->GetDisplayInfo().is_virtual)) return false;
    parsec_vdd::VddRemoveDisplay(vdd_handle_, display_uid);
    if (it != displays_.end()) displays_.erase(it);
    if (owned) {
        exclusive_created_uid = -1;
        pre_insert_paths.clear();
        pre_insert_modes.clear();
    }
#if defined(CLOUDPLAYPLUS_SERVICE_CONSOLE_RECOVERY)
    if (!has_backup_) ReleaseHandedDisplay(display_uid);
#endif
    std::cout << "Virtual display removed: " << display_uid << std::endl;
    return true;
}

int VirtualDisplayControl::GetDisplayCount() {
    return static_cast<int>(displays_.size());
}

std::vector<int> VirtualDisplayControl::GetDisplayList() {
    std::vector<int> ids;
    for (const auto& display : displays_) {
        ids.push_back(display->GetDisplayUid());
    }
    return ids;
}

int VirtualDisplayControl::GetAllDisplays() {

    std::map <std::string, std::unique_ptr<VirtualDisplay>> displayMap;
    auto paths= GetDisplayPaths();

    DISPLAY_DEVICEW ddAdapter{}, ddMonitor{};
    ddAdapter.cb = sizeof(ddAdapter);

    for (int ai = 0; EnumDisplayDevicesW(nullptr, ai, &ddAdapter, 0); ++ai) {

        // std::cout << "__________________________________________---_______________________________" << std::endl;
        // std::cout << "Processing adapter: " << WideStringToString(ddAdapter.DeviceName) << "\n";
        // std::cout << "StateFlags: " << ddAdapter.StateFlags << "\n";
        // std::cout << "DeviceID: " << WideStringToString(ddAdapter.DeviceID) << "\n";



        ddMonitor = {}; ddMonitor.cb = sizeof(ddMonitor);
        for (int mi = 0;
             EnumDisplayDevicesW(ddAdapter.DeviceName, mi, &ddMonitor,
                                 EDD_GET_DEVICE_INTERFACE_NAME);
             ++mi)
        {
            // std::cout << "__________________________________________--display-_______________________________" << std::endl;
            // std::cout << "Processing monitor: " << WideStringToString(ddMonitor.DeviceName) << "\n";
            // std::cout << "StateFlags: " << ddMonitor.StateFlags << "\n";
            // std::cout << "DeviceID: " << WideStringToString(ddMonitor.DeviceID) << "\n";


            if (!(ddMonitor.StateFlags & DISPLAY_DEVICE_ATTACHED))
                continue;

            int path_idx = -1;
            std::string devicePath;
            for (int k = 0; k < (int)paths.size(); ++k) {
                std::string p = paths[k];
                std::replace(p.begin(), p.end(), '\\', '#');
                std::wstring w_device_id(ddMonitor.DeviceID);
                std::string device_id = WideStringToString(w_device_id);
                if (std::search(device_id.begin(), device_id.end(), p.begin(), p.end(),
                        [](unsigned char a, unsigned char b) { return std::toupper(a) == std::toupper(b); }) != device_id.end()) {
                    path_idx = k;
                    devicePath = paths[k];
                    break;
                }
            }
            if (path_idx < 0)
                continue;


            if (!displayMap.count(devicePath)) {

                std::wstring w_device_id(ddMonitor.DeviceID);
                std::string device_id = WideStringToString(w_device_id);

                VirtualDisplay::DisplayInfo d;
                d.display_uid     = ParseDisplayAddress(devicePath);
                d.raw_screen_id   = ai;

                if (_stricmp(ParseDisplayCode(device_id).c_str(), parsec_vdd::VDD_DISPLAY_ID) == 0) {
                    d.is_virtual = true;
                } else {
                    d.is_virtual = false;
                }

                // Match WebRTC's GetScreenList() criterion exactly. A child
                // monitor can report DISPLAY_DEVICE_ACTIVE before its top-level
                // adapter does, which otherwise produces a false "ready".
                d.active = !!(ddAdapter.StateFlags & DISPLAY_DEVICE_ACTIVE);
                std::wstring w_device_name(ddAdapter.DeviceName);
                d.device_name  = WideStringToString(w_device_name);
                d.display_name = ParseDisplayCode(device_id);

                DEVINST dev_inst;
                if (GetDeviceInstance(devicePath, dev_inst)) {
                    GetDeviceLastArrival(dev_inst, d.last_arrival);
                    GetDeviceDescription(dev_inst, d.device_description);
                }else{
                    std::cout << "Failed to get device instance for: " << device_id << "\n";
                }


                DEVMODEW dm = {};
                dm.dmSize = sizeof(dm);
                VirtualDisplay::DisplayConfig config = VirtualDisplay::DisplayConfig();


                VirtualDisplay::Orientation current_orientation_ = VirtualDisplay::Landscape; // Default orientation
                if (EnumDisplaySettingsW(ddAdapter.DeviceName, ENUM_CURRENT_SETTINGS, &dm)) {
                    config.width = dm.dmPelsWidth;
                    config.height = dm.dmPelsHeight;
                    config.refresh_rate = dm.dmDisplayFrequency;
                    current_orientation_ = static_cast<VirtualDisplay::Orientation>(dm.dmDisplayOrientation);
                    
                    std::cout << "Device: " << WideStringToString(ddAdapter.DeviceName) 
                              << ", Raw orientation: " << dm.dmDisplayOrientation 
                              << ", Casted orientation: " << static_cast<int>(current_orientation_)
                              << ", Resolution: " << dm.dmPelsWidth << "x" << dm.dmPelsHeight << std::endl;
                } 

                std::unique_ptr<VirtualDisplay> display = std::make_unique<VirtualDisplay>(config, d);
                if(d.is_virtual) {
                    // Virtual (VDD) uid = VDD hardware index (0..15); used by VddRemoveDisplay.
                    display->SetDisplayUid(d.display_uid - 256);
                } else {
                    // Physical uid: offset by 1024 so it never collides with a VDD index.
                    // (e.g. QXL's target id is UID0, which would otherwise clash with VDD #0.)
                    // NOTE: this does not guarantee uniqueness between two physical displays
                    // whose per-adapter target ids happen to match; revisit with a devicePath-
                    // derived id later.
                    display->SetDisplayUid(d.display_uid + 1024);
                }
                display->SetCurrentOrientation(current_orientation_);
                display->UpdateDisplayBounds();

                displayMap[devicePath] = std::move(display);
               
                // std::cout << "=== This is display  ------------------ ===\n";
                // std::cout << "  Display ID: " << d.display_uid << "\n";
                // std::cout << "  Device Name: " << d.device_name << "\n";
                // std::cout << "  Display Name: " << d.display_name << "\n";
                // std::cout << "  Device Description: " << d.device_description << "\n";
                // std::cout << "  Last Arrival: " << FileTimeToString(d.last_arrival) << "\n";
                // std::cout << "  Active: " << (d.active ? "Yes" : "No") << "\n";

                // std::cout << "  Display Config: " 
                //           << config.width << "x" 
                //           << config.height << "@" 
                //           << config.refresh_rate << "Hz, ";
                // std::cout << "=== End ===\n";
        
            }
        }
    }


    displays_.clear();
    
    std::vector<std::pair<std::string, std::unique_ptr<VirtualDisplay>>> sortedDisplays;
    for (auto& pair : displayMap) {
        sortedDisplays.push_back(std::make_pair(pair.first, std::move(pair.second)));
    }

    std::sort(sortedDisplays.begin(), sortedDisplays.end(), 
        [](const auto& a, const auto& b) {
            const FILETIME& ftA = a.second->GetDisplayInfo().last_arrival;
            const FILETIME& ftB = b.second->GetDisplayInfo().last_arrival;
            

            ULARGE_INTEGER uliA, uliB;
            uliA.LowPart = ftA.dwLowDateTime;
            uliA.HighPart = ftA.dwHighDateTime;
            uliB.LowPart = ftB.dwLowDateTime;
            uliB.HighPart = ftB.dwHighDateTime;
            
            return uliA.QuadPart < uliB.QuadPart;  
        });
    

    for (auto& pair : sortedDisplays) {
        displays_.push_back(std::move(pair.second));
    }
    
    std::cout << "Total displays loaded: " << displays_.size() << " (sorted by arrival time)\n";
    return static_cast<int>(displays_.size());
}

bool VirtualDisplayControl::CheckVddStatus() {
    parsec_vdd::DeviceStatus status = parsec_vdd::QueryDeviceStatus(&parsec_vdd::VDD_CLASS_GUID, parsec_vdd::VDD_HARDWARE_ID);
    return (status == parsec_vdd::DEVICE_OK);
}

bool VirtualDisplayControl::ChangeDisplaySettings(int display_uid, const VirtualDisplay::DisplayConfig& config) {
    auto it = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (it == displays_.end()) {
        std::cout << "Error: Invalid display UID:" << display_uid << std::endl;
        return false;
    }

    auto& display = *it;
    if (!display) {
        std::cout << "Error: Display not found" << std::endl;
        return false;
    }
    
    if (!display->ChangeDisplaySettings(config)) {
        std::cout << "Error: Failed to change display settings" << std::endl;
        return false;
    }

    std::cout << "Display settings changed for UID: " << display_uid << std::endl;
    return true;
}


std::vector<VirtualDisplayControl::DetailedDisplayInfo> VirtualDisplayControl::GetDetailedDisplayList() {
    std::vector<DetailedDisplayInfo> result;
    VirtualDisplayControl::GetAllDisplays();
    
    // First, add all managed virtual displays from displays_ array
    for (size_t i = 0; i < displays_.size(); i++) {
        const auto& display = displays_[i];
        if (display) {
            DetailedDisplayInfo info;
            info.index = static_cast<int>(i);
            
            // Copy config data
            auto config = display->GetConfig();
            info.width = config.width;
            info.height = config.height;
            info.refresh_rate = config.refresh_rate;
            
            // Copy display info data
            auto display_info = display->GetDisplayInfo();
            info.active = display_info.active;
            info.display_uid = display->GetDisplayUid();
            info.raw_screen_id = display_info.raw_screen_id;
            info.device_name = display_info.device_name;
            info.display_name = display_info.display_name;
            info.device_description = display_info.device_description;
            info.last_arrival = display_info.last_arrival;
            
            // Copy coordinate information
            info.left = display_info.left;
            info.top = display_info.top;
            info.right = display_info.right;
            info.bottom = display_info.bottom;
            info.is_primary = display_info.is_primary;
            
            // Set additional fields
            info.is_virtual = display_info.is_virtual;  // These are managed virtual displays
            info.orientation = static_cast<int>(display->GetCurrentOrientation());  // Orientation field

            
            // std::cout << "Display[" << i << "]:" << std::endl;
            // std::cout << "  Resolution: " << info.width << "x" << info.height << "@" << info.refresh_rate << "Hz" << std::endl;
            // std::cout << "  Display UID: " << info.display_uid << std::endl;
            // std::cout << "  Device Name: " << info.device_name << std::endl;
            // std::cout << "  Display Name: " << info.display_name << std::endl;
            // std::cout << "  Active: " << (info.active ? "Yes" : "No") << std::endl;
            // std::cout << "  Is Virtual: " << (info.is_virtual ? "Yes" : "No") << std::endl;
            
            result.push_back(info);
        } else {
            std::cout << "Display[" << i << "]: null pointer" << std::endl;
        }
    }

    std::cout << "Returning " << result.size() << " displays" << std::endl;
    return result;
}

std::vector<VirtualDisplay::DisplayConfig> VirtualDisplayControl::GetDisplayConfigs(int display_uid) {
    auto it = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (it == displays_.end()) {
        std::cout << "Display not found for UID: " << display_uid << std::endl;
        return {};
    }

    auto& display = *it;
    if (!display) {
        std::cout << "Display pointer is null" << std::endl;
        return {};
    }

    return display->GetDisplayConfigList();
}

std::vector<VirtualDisplay::DisplayConfig> VirtualDisplayControl::GetCustomDisplayConfigs() {
    std::vector<VirtualDisplay::DisplayConfig> configs;
    
    HKEY vdd_key;
    LONG result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, 
                                L"SOFTWARE\\Parsec\\vdd", 
                                0, 
                                KEY_READ, 
                                &vdd_key);
    
    if (result != ERROR_SUCCESS) {
        std::cout << "Failed to open Parsec VDD registry key" << std::endl;
        return configs;
    }
    
    for (int i = 0; i < 5; i++) {
        std::wstring subkey_name = std::to_wstring(i);
        HKEY index_key;
        
        result = RegOpenKeyExW(vdd_key, 
                               subkey_name.c_str(), 
                               0, 
                               KEY_READ, 
                               &index_key);
        
        if (result == ERROR_SUCCESS) {
            DWORD width, height, hz;
            DWORD data_size = sizeof(DWORD);
            
            LONG width_result = RegQueryValueExW(index_key, L"width", nullptr, nullptr, 
                                                 reinterpret_cast<BYTE*>(&width), &data_size);
            data_size = sizeof(DWORD);
            LONG height_result = RegQueryValueExW(index_key, L"height", nullptr, nullptr, 
                                                  reinterpret_cast<BYTE*>(&height), &data_size);
            data_size = sizeof(DWORD);
            LONG hz_result = RegQueryValueExW(index_key, L"hz", nullptr, nullptr, 
                                              reinterpret_cast<BYTE*>(&hz), &data_size);
            
            if (width_result == ERROR_SUCCESS && height_result == ERROR_SUCCESS && hz_result == ERROR_SUCCESS) {
                VirtualDisplay::DisplayConfig config;
                config.width = static_cast<int>(width);
                config.height = static_cast<int>(height);
                config.refresh_rate = static_cast<int>(hz);
                configs.push_back(config);
            }
            
            RegCloseKey(index_key);
        }
    }
    
    RegCloseKey(vdd_key);
    std::cout << "Retrieved " << configs.size() << " custom display configs from registry" << std::endl;
    return configs;
}

bool VirtualDisplayControl::SetCustomDisplayConfigs(const std::vector<VirtualDisplay::DisplayConfig>& configs) {
    HKEY vdd_key;
    LONG result = RegCreateKeyExW(HKEY_LOCAL_MACHINE, 
                                  L"SOFTWARE\\Parsec\\vdd", 
                                  0, 
                                  nullptr, 
                                  REG_OPTION_NON_VOLATILE, 
                                  KEY_WRITE, 
                                  nullptr, 
                                  &vdd_key, 
                                  nullptr);
    
    if (result != ERROR_SUCCESS) {
        std::cout << "Failed to create/open Parsec VDD registry key. Admin rights required." << std::endl;
        return false;
    }
    
    for (int i = 0; i < 5; i++) {
        std::wstring subkey_name = std::to_wstring(i);
        
        if (i >= static_cast<int>(configs.size())) {
            result = RegDeleteKeyW(vdd_key, subkey_name.c_str());
            if (result == ERROR_SUCCESS) {
                std::cout << "Deleted registry subkey: " << i << std::endl;
            }
        } else {
            HKEY index_key;
            result = RegCreateKeyExW(vdd_key, 
                                     subkey_name.c_str(), 
                                     0, 
                                     nullptr, 
                                     REG_OPTION_NON_VOLATILE, 
                                     KEY_WRITE, 
                                     nullptr, 
                                     &index_key, 
                                     nullptr);
            
            if (result == ERROR_SUCCESS) {
                const auto& config = configs[i];
                DWORD width = static_cast<DWORD>(config.width);
                DWORD height = static_cast<DWORD>(config.height);
                DWORD hz = static_cast<DWORD>(config.refresh_rate);
                
                RegSetValueExW(index_key, L"width", 0, REG_DWORD, 
                               reinterpret_cast<const BYTE*>(&width), sizeof(DWORD));
                RegSetValueExW(index_key, L"height", 0, REG_DWORD, 
                               reinterpret_cast<const BYTE*>(&height), sizeof(DWORD));
                RegSetValueExW(index_key, L"hz", 0, REG_DWORD, 
                               reinterpret_cast<const BYTE*>(&hz), sizeof(DWORD));
                
                std::cout << "Set custom display config " << i << ": " 
                          << config.width << "x" << config.height << "@" << config.refresh_rate << "Hz" << std::endl;
                
                RegCloseKey(index_key);
            } else {
                std::cout << "Failed to create registry subkey: " << i << std::endl;
                RegCloseKey(vdd_key);
                return false;
            }
        }
    }
    
    RegCloseKey(vdd_key);
    std::cout << "Successfully set " << configs.size() << " custom display configs" << std::endl;
    return true;
}

bool VirtualDisplayControl::SetDisplayOrientation(int display_uid, VirtualDisplay::Orientation orientation) {
    auto it = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (it == displays_.end()) {
        std::cout << "Error: Invalid display UID:" << display_uid << std::endl;
        return false;
    }

    auto& display = *it;

    return display->SetOrientation(orientation);
}

VirtualDisplay::Orientation VirtualDisplayControl::GetDisplayOrientation(int display_uid) {
    auto it = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (it == displays_.end()) {
        std::cout << "Error: Invalid display UID:" << display_uid << std::endl;
        return VirtualDisplay::Landscape; // Default orientation
    }

    auto& display = *it;

    return display->GetCurrentOrientation();
}

bool VirtualDisplayControl::SetMultiDisplayMode(MultiDisplayMode mode, int primary_display_id) {
    return RunDisplayOperationOnInputDesktop([&] {
    // Force the requested topology through to the display driver. In
    // particular, a newly-created VDD target may not yet be part of the last
    // persisted extended topology even though SetDisplayConfig can otherwise
    // return success without changing the active desktop paths.
    UINT32 flags = SDC_APPLY | SDC_NO_OPTIMIZATION;
    
    switch (mode) {
        case MultiDisplayMode::Extend:
            flags |= SDC_TOPOLOGY_EXTEND | SDC_PATH_PERSIST_IF_REQUIRED;
            break;
            
        case MultiDisplayMode::Duplicate:
            flags |= SDC_TOPOLOGY_CLONE;
            break;
            
        case MultiDisplayMode::PrimaryOnly:
            flags |= SDC_TOPOLOGY_INTERNAL;
            break;
            
        case MultiDisplayMode::SecondaryOnly:
            flags |= SDC_TOPOLOGY_EXTERNAL;
            break;
            
        default:
            std::cout << "Unknown multi-display mode: " << static_cast<int>(mode) << std::endl;
            return false;
    }
    
    LONG result = SetDisplayConfig(0, nullptr, 0, nullptr, flags);
    CPPLOG_INFO("VDD_MODE", "topology mode=%d status=%ld", static_cast<int>(mode), result);
    if (result == ERROR_SUCCESS) {
        std::cout << "Successfully set multi-display mode: " << static_cast<int>(mode) << std::endl;
        return true;
    } else {
        std::cout << "Failed to set multi-display mode: " << result << std::endl;
        return false;
    }
    });
}

VirtualDisplayControl::MultiDisplayMode VirtualDisplayControl::GetCurrentMultiDisplayMode() {
    std::cout << "=== GetCurrentMultiDisplayMode called ===" << std::endl;
    
    UINT32 path_count = 0;
    UINT32 mode_count = 0;
    
    LONG result = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count);
    if (result != ERROR_SUCCESS) {
        std::cout << "Failed to get display config buffer sizes: " << result << std::endl;
        return MultiDisplayMode::Unknown;
    }
    
    std::cout << "Buffer sizes - paths: " << path_count << ", modes: " << mode_count << std::endl;
    
    if (path_count == 0) {
        std::cout << "No display paths found" << std::endl;
        return MultiDisplayMode::Unknown;
    }
    
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
    
    result = QueryDisplayConfig(
        QDC_ONLY_ACTIVE_PATHS,
        &path_count, paths.data(),
        &mode_count, modes.data(),
        nullptr
    );
    
    std::cout << "QueryDisplayConfig result: " << result << std::endl;
    
    if (result != ERROR_SUCCESS) {
        std::cout << "Failed to query display config: " << result << std::endl;
        return MultiDisplayMode::Unknown;
    }
    
    std::map<std::string, int> unique_sources;
    int active_paths = 0;
    
    for (const auto& path : paths) {
        if (path.flags & DISPLAYCONFIG_PATH_ACTIVE) {
            active_paths++;
            std::string source_key = std::to_string(path.sourceInfo.adapterId.HighPart) + 
                                   "_" + std::to_string(path.sourceInfo.adapterId.LowPart) + 
                                   "_" + std::to_string(path.sourceInfo.id);
            unique_sources[source_key]++;
            std::cout << "Active path: adapter=" << path.sourceInfo.adapterId.HighPart 
                      << ":" << path.sourceInfo.adapterId.LowPart 
                      << ", sourceId=" << path.sourceInfo.id << std::endl;
        }
    }
    
    std::cout << "Active paths: " << active_paths << ", Unique sources: " << unique_sources.size() << std::endl;
    
    if (active_paths <= 1) {
        std::cout << "Returning: PrimaryOnly (single display)" << std::endl;
        return MultiDisplayMode::PrimaryOnly;
    }
    
    if (unique_sources.size() == 1 && active_paths > 1) {
        std::cout << "Returning: Duplicate (one source, multiple targets)" << std::endl;
        return MultiDisplayMode::Duplicate;
    }
    
    if (unique_sources.size() > 1 && unique_sources.size() == static_cast<size_t>(active_paths)) {
        std::cout << "Returning: Extend (one-to-one multiple displays)" << std::endl;
        return MultiDisplayMode::Extend;
    }
    
    std::cout << "Returning: SecondaryOnly (complex configuration)" << std::endl;
    return MultiDisplayMode::SecondaryOnly;
}

namespace {
// 同一个 target 可以经由多个 source 到达。UID 是 Parsec 设备实例地址减去 256，
// CCD targetId 本身是适配器内的编号，不可直接当作 Parsec UID。
bool IsParsecTarget(const DISPLAYCONFIG_PATH_TARGET_INFO& target, int uid) {
    DISPLAYCONFIG_TARGET_DEVICE_NAME name{};
    name.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(name), target.adapterId, target.id};
    if (DisplayConfigGetDeviceInfo(&name.header) != ERROR_SUCCESS) return false;
    const std::wstring path(name.monitorDevicePath);
    const std::wstring prefix = L"\\\\?\\DISPLAY#PSCCDD0#";
    if (_wcsnicmp(path.c_str(), prefix.c_str(), prefix.size()) != 0) return false;
    const auto end = path.find(L'#', prefix.size());
    if (end == std::wstring::npos) return false;
    const std::wstring address = L"&UID" + std::to_wstring(256 + uid);
    return end >= address.size() &&
        _wcsnicmp(path.c_str() + end - address.size(), address.c_str(), address.size()) == 0;
}

bool SameTarget(const DISPLAYCONFIG_PATH_TARGET_INFO& a, const DISPLAYCONFIG_PATH_TARGET_INFO& b) {
    return a.id == b.id && a.adapterId.HighPart == b.adapterId.HighPart &&
        a.adapterId.LowPart == b.adapterId.LowPart;
}

// source 的编号在重配后可能改变，但每个活动目标的位置/尺寸和复制关系应恢复。
bool RestoredActiveLayout(const std::vector<DISPLAYCONFIG_PATH_INFO>& expected,
                          const std::vector<DISPLAYCONFIG_MODE_INFO>& expected_modes) {
    std::vector<DISPLAYCONFIG_PATH_INFO> actual;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    if (!QueryLayout(QDC_ONLY_ACTIVE_PATHS, actual, modes) || expected.size() != actual.size()) return false;
    for (const auto& path : expected) {
        const auto match = std::find_if(actual.begin(), actual.end(), [&](const auto& p) {
            return SameTarget(p.targetInfo, path.targetInfo);
        });
        if (match == actual.end()) return false;
        const auto index = path.sourceInfo.modeInfoIdx;
        if (index >= expected_modes.size()) continue;
        if (match->sourceInfo.modeInfoIdx >= modes.size()) return false;
        const auto& before = expected_modes[index].sourceMode;
        const auto& after = modes[match->sourceInfo.modeInfoIdx].sourceMode;
        if (before.width != after.width || before.height != after.height ||
            before.position.x != after.position.x || before.position.y != after.position.y) return false;
    }
    return true;
}

bool IsOnlyTarget(int uid, const std::wstring& expected_source = {}) {
    std::vector<DISPLAYCONFIG_PATH_INFO> active;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    if (!QueryLayout(QDC_ONLY_ACTIVE_PATHS | QDC_VIRTUAL_MODE_AWARE, active, modes) ||
        active.size() != 1 || !IsParsecTarget(active.front().targetInfo, uid)) return false;
    if (expected_source.empty()) return true;
    DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
    const auto& info = active.front().sourceInfo;
    source.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source), info.adapterId, info.id};
    return DisplayConfigGetDeviceInfo(&source.header) == ERROR_SUCCESS &&
        _wcsicmp(source.viewGdiDeviceName, expected_source.c_str()) == 0;
}

// 已有会话服务接收传统 CCD 索引及显式源模式。由驱动选择目标时序。
LONG ApplyExclusiveModeViaService(DISPLAYCONFIG_PATH_INFO path,
                                  const VirtualDisplay::DisplayConfig& requested) {
    if (requested.width <= 0 || requested.height <= 0 || requested.refresh_rate <= 0)
        return ERROR_INVALID_PARAMETER;
    path.flags = DISPLAYCONFIG_PATH_ACTIVE;
    path.sourceInfo.modeInfoIdx = 0;
    path.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
    path.targetInfo.refreshRate = {static_cast<UINT32>(requested.refresh_rate), 1};
    // Parsec 输出为逐行。指定刷新率时配未指定扫描顺序，CCD 会返回错误 87。
    path.targetInfo.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    DISPLAYCONFIG_MODE_INFO mode{};
    mode.infoType = static_cast<DISPLAYCONFIG_MODE_INFO_TYPE>(DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE);
    mode.adapterId = path.sourceInfo.adapterId;
    mode.id = path.sourceInfo.id;
    mode.sourceMode.width = static_cast<UINT32>(requested.width);
    mode.sourceMode.height = static_cast<UINT32>(requested.height);
    mode.sourceMode.pixelFormat = DISPLAYCONFIG_PIXELFORMAT_32BPP;
    LONG status = ERROR_GEN_FAILURE;
    if (!hardware_simulator::DesktopServiceInputClient::Instance().RestoreDisplayConfiguration(
            {path}, {mode}, status, true)) return ERROR_SERVICE_NOT_ACTIVE;
    return status;
}

bool ActivateExclusiveTarget(int uid, const std::function<bool()>& save_layout) {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    for (int attempt = 0; attempt < 12; ++attempt) {
        if (attempt) Sleep(200);
        if (!QueryLayout(QDC_ALL_PATHS | QDC_VIRTUAL_MODE_AWARE, paths, modes)) continue;
        std::vector<DISPLAYCONFIG_PATH_INFO> candidates;
        for (const auto& path : paths) {
            if (!path.targetInfo.targetAvailable || !IsParsecTarget(path.targetInfo, uid)) continue;
            if (!candidates.empty() && !SameTarget(candidates.front().targetInfo, path.targetInfo)) {
                CPPLOG_WARN("VDD_MODE", "ambiguous exclusive target uid=%d", uid);
                return false;
            }
            candidates.push_back(path);
        }
        if (candidates.empty()) continue;
        std::stable_partition(candidates.begin(), candidates.end(), [](const auto& p) {
            return (p.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0;
        });
        for (auto path : candidates) {
            path.flags = DISPLAYCONFIG_PATH_ACTIVE | (path.flags & DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE);
            const bool virtual_mode = (path.flags & DISPLAYCONFIG_PATH_SUPPORT_VIRTUAL_MODE) != 0;
            path.sourceInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
            // 未提供源模式时，用独立组标识这个唯一的输出。两个索引都无效会触发错误 87。
            if (virtual_mode) path.sourceInfo.cloneGroupId = 0;
            path.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
            path.targetInfo.refreshRate = {};
            path.targetInfo.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_UNSPECIFIED;
            const UINT32 flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES |
                (virtual_mode ? SDC_VIRTUAL_MODE_AWARE : 0);
            const char* stage = "validate";
            LONG result = SetDisplayConfig(1, &path, 0, nullptr, SDC_VALIDATE | flags);
            if (result == ERROR_SUCCESS) {
                if (!save_layout()) break; // 热插拔期间数据库可能尚未就绪。
                stage = "apply";
                result = SetDisplayConfig(1, &path, 0, nullptr, SDC_APPLY | SDC_SAVE_TO_DATABASE | flags);
            }
            if (result == ERROR_ACCESS_DENIED) {
                if (!save_layout()) break;
                stage = "service-apply";
                result = ApplyExclusiveModeViaService(path, exclusive_requested_mode);
            }
            CPPLOG_INFO("VDD_MODE", "exclusive target uid=%d adapter=%lx:%lx target=%u source=%u virtualMode=%d stage=%s status=%ld",
                uid, path.targetInfo.adapterId.HighPart, path.targetInfo.adapterId.LowPart,
                path.targetInfo.id, path.sourceInfo.id, virtual_mode, stage, result);
            (void)stage; // CPP_LOG_AVAILABLE 关闭时日志宏不读取参数。
            if (result == ERROR_ACCESS_DENIED || result == ERROR_SERVICE_NOT_ACTIVE) return false;
            if (result != ERROR_SUCCESS) continue;
            for (int settle = 0; settle < 10; ++settle) {
                if (IsOnlyTarget(uid)) return true;
                Sleep(100);
            }
            CPPLOG_WARN("VDD_MODE", "exclusive target readback mismatch uid=%d", uid);
            return false;
        }
    }
    CPPLOG_WARN("VDD_MODE", "no usable exclusive path uid=%d", uid);
    return false;
}
}

bool VirtualDisplayControl::VerifyExclusiveTarget(int uid) {
    if (uid < 0) return false;
    std::wstring expected_source;
    for (const auto& display : displays_) {
        const auto& info = display->GetDisplayInfo();
        if (display->GetDisplayUid() == uid && info.is_virtual && info.active &&
            info.raw_screen_id >= 0 && !info.device_name.empty()) {
            if (!expected_source.empty()) return false;
            expected_source = StringToWideString(info.device_name);
        }
    }
    return !expected_source.empty() && RunDisplayOperationOnInputDesktop([&] {
        return IsOnlyTarget(uid, expected_source);
    });
}

bool VirtualDisplayControl::SetPrimaryDisplayOnly(int display_uid) {
    return RunDisplayOperationOnInputDesktop([&] {
    std::cout << "SetPrimaryDisplayOnly called with display_uid: " << display_uid << std::endl;
    
    // Check if there's already a pending configuration that hasn't been restored
    if (has_backup_) {
        std::cerr << "Error: A display configuration is already set and not restored. Please call RestoreDisplayConfiguration() first." << std::endl;
        return false;
    }
    
    if (display_uid >= 0 && display_uid == exclusive_created_uid) {
        return ActivateExclusiveTarget(display_uid, [] {
            if (has_backup_) return true;
            if (!SaveDisplayConfiguration()) return false;
            if (!pre_insert_paths.empty()) {
                original_paths_ = std::move(pre_insert_paths);
                original_modes_ = std::move(pre_insert_modes);
            }
            return true;
        });
    }

    // Save current configuration
    if (!SaveDisplayConfiguration()) {
        std::cerr << "Failed to save current display configuration" << std::endl;
        return false;
    }
    
    UINT32 numPathArrayElements = 0;
    UINT32 numModeInfoArrayElements = 0;
    LONG result = ERROR_SUCCESS;

    // Get required buffer sizes
    result = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &numPathArrayElements, &numModeInfoArrayElements);
    if (result != ERROR_SUCCESS) {
        std::cerr << "GetDisplayConfigBufferSizes failed: " << result << std::endl;
        return false;
    }

    // Allocate buffers
    std::vector<DISPLAYCONFIG_PATH_INFO> pathArray(numPathArrayElements);
    std::vector<DISPLAYCONFIG_MODE_INFO> modeInfoArray(numModeInfoArrayElements);

    // Query current display configuration
    result = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, 
                               &numPathArrayElements, pathArray.data(), 
                               &numModeInfoArrayElements, modeInfoArray.data(), 
                               nullptr);
    if (result != ERROR_SUCCESS) {
        std::cerr << "QueryDisplayConfig failed: " << result << std::endl;
        return false;
    }

    // Find the target display by matching with our display list
    auto displayIt = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (displayIt == displays_.end()) {
        std::cerr << "Display with UID " << display_uid << " not found in managed displays" << std::endl;
        return false;
    }

    // Get the device name of the target display
    std::string targetDeviceName = (*displayIt)->GetDisplayInfo().device_name;
    std::wstring wTargetDeviceName = StringToWideString(targetDeviceName);
    
    int targetPathIndex = -1;
    
    // Try to match by device name
    for (UINT32 i = 0; i < numPathArrayElements; ++i) {
        if (pathArray[i].flags & DISPLAYCONFIG_PATH_ACTIVE) {
            // Get the device name for this path
            DISPLAYCONFIG_SOURCE_DEVICE_NAME sourceName = {};
            sourceName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            sourceName.header.size = sizeof(sourceName);
            sourceName.header.adapterId = pathArray[i].sourceInfo.adapterId;
            sourceName.header.id = pathArray[i].sourceInfo.id;

            if (DisplayConfigGetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*)&sourceName) == ERROR_SUCCESS) {
                std::wstring wSourceDeviceName(sourceName.viewGdiDeviceName);
                std::string sourceDeviceName = WideStringToString(wSourceDeviceName);
                
                if (sourceDeviceName == targetDeviceName) {
                    targetPathIndex = i;
                    std::wcout << L"Found target display by device name: " << GetDisplayTargetName(pathArray[i].targetInfo.adapterId, pathArray[i].targetInfo.id) << std::endl;
                    break;
                }
            }
        }
    }
    
    if (targetPathIndex == -1) {
        std::cerr << "No active display found to set as primary" << std::endl;
        CPPLOG_WARN("VDD_MODE", "exclusive target not found uid=%d device=%s", display_uid, targetDeviceName.c_str());
        return false;
    }

    // Create new configuration with only the target display active
    for (UINT32 i = 0; i < numPathArrayElements; ++i) {
        if (i == static_cast<UINT32>(targetPathIndex)) {
            // Set this display as primary and active
            pathArray[i].flags = DISPLAYCONFIG_PATH_ACTIVE | DISPLAYCONFIG_PATH_PRIMARY_VIEW;
            // Use the existing mode info index for this path
            // pathArray[i].sourceInfo.modeInfoIdx remains unchanged
            // pathArray[i].targetInfo.modeInfoIdx remains unchanged
        } else {
            // Disable all other displays
            pathArray[i].flags = 0;
        }
    }
    
    // Set the primary display position in mode info
    for (UINT32 i = 0; i < numModeInfoArrayElements; ++i) {
        if (modeInfoArray[i].infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) {
            // Find the mode info that corresponds to our target display
            bool isTargetMode = false;
            for (UINT32 j = 0; j < numPathArrayElements; ++j) {
                if (j == static_cast<UINT32>(targetPathIndex) && 
                    pathArray[j].sourceInfo.modeInfoIdx == i) {
                    isTargetMode = true;
                    break;
                }
            }
            
            if (isTargetMode) {
                // Set primary display position to (0,0)
                modeInfoArray[i].sourceMode.position.x = 0;
                modeInfoArray[i].sourceMode.position.y = 0;
            }
        }
    }

    // 重试只引用精确选中的路径，不能重新保存布局覆盖原始备份。
    auto retryPath = pathArray[targetPathIndex];
    const auto sourceIndex = retryPath.sourceInfo.modeInfoIdx;
    const bool hasSource = sourceIndex < numModeInfoArrayElements &&
        modeInfoArray[sourceIndex].infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE;
    DISPLAYCONFIG_MODE_INFO retryMode{};
    if (hasSource) retryMode = modeInfoArray[sourceIndex];
    CPPLOG_INFO("VDD_MODE", "exclusive submit uid=%d device=%s paths=%u modes=%u source=%u target=%u refresh=%u/%u",
        display_uid, targetDeviceName.c_str(), numPathArrayElements, numModeInfoArrayElements,
        sourceIndex, retryPath.targetInfo.modeInfoIdx, retryPath.targetInfo.refreshRate.Numerator,
        retryPath.targetInfo.refreshRate.Denominator);
    // 保存独占布局，避免游戏退出全屏时从系统数据库重新启用实体屏。
    result = SetDisplayConfig(
        numPathArrayElements,
        pathArray.data(),
        numModeInfoArrayElements,
        modeInfoArray.data(),
        SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE
    );

    if ((result == ERROR_GEN_FAILURE || result == ERROR_BAD_CONFIGURATION) && hasSource) {
        CPPLOG_WARN("VDD_MODE", "exclusive supplied timing rejected uid=%d status=%ld; re-enumerating target timing", display_uid, result);
        retryPath.sourceInfo.modeInfoIdx = 0;
        retryPath.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        retryPath.flags = DISPLAYCONFIG_PATH_ACTIVE;
        result = SetDisplayConfig(1, &retryPath, 1, &retryMode,
            SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES |
            SDC_SAVE_TO_DATABASE | SDC_FORCE_MODE_ENUMERATION | SDC_NO_OPTIMIZATION);
        CPPLOG_INFO("VDD_MODE", "exclusive target timing retry uid=%d status=%ld source=%lux%lu", display_uid,
            result, retryMode.sourceMode.width, retryMode.sourceMode.height);
    }
    if (result != ERROR_SUCCESS) {
        std::cerr << "SetDisplayConfig failed: " << result << std::endl;
        CPPLOG_WARN("VDD_MODE", "exclusive topology uid=%d status=%ld", display_uid, result);
        return false;
    }

    std::cout << "Successfully set display " << display_uid << " as primary and disabled other displays" << std::endl;
    return true;
    });
}

bool VirtualDisplayControl::RestoreDisplayConfiguration() {
    return RunDisplayOperationOnInputDesktop([&] {
    
    if (!has_backup_) {
        return true;
    }

    auto apply = [](const auto& paths, const auto& modes, bool persist) {
        // SetDisplayConfig 可能调整传入数组；失败重试不能修改备份。
        auto apply_paths = paths;
        auto apply_modes = modes;
        LONG result = SetDisplayConfig(static_cast<UINT32>(apply_paths.size()), apply_paths.data(),
            static_cast<UINT32>(apply_modes.size()), apply_modes.data(),
            SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES |
            (persist ? SDC_SAVE_TO_DATABASE : 0));
        if (result == ERROR_ACCESS_DENIED) {
            LONG service_result = ERROR_GEN_FAILURE;
            if (hardware_simulator::DesktopServiceInputClient::Instance().RestoreDisplayConfiguration(
                    paths, modes, service_result, persist)) result = service_result;
        }
        if (result != ERROR_SUCCESS)
            CPPLOG_WARN("DISPLAY_RESTORE", "restore failed status=%ld persist=%d; keeping backups", result, persist);
        return result == ERROR_SUCCESS;
    };
    // 先还原用户的桌面默认值，再临时恢复游戏当时的活动模式。
    if (!apply(persistent_paths_, persistent_modes_, true) ||
        !apply(original_paths_, original_modes_, false)) return false;

    if (exclusive_created_uid >= 0 && !RestoredActiveLayout(original_paths_, original_modes_)) {
        CPPLOG_WARN("DISPLAY_RESTORE", "exclusive restore readback mismatch uid=%d", exclusive_created_uid);
        return false;
    }
    CPPLOG_INFO("DISPLAY_RESTORE", "display configuration restored");
    
    // Clear the backup to prevent accidental double-restore
    has_backup_ = false;
    original_paths_.clear();
    original_modes_.clear();
    persistent_paths_.clear();
    persistent_modes_.clear();
    
    return true;
    });
}

bool VirtualDisplayControl::HasPendingConfiguration() {
    return has_backup_;
}

bool VirtualDisplayControl::RetainDisplayForHandoff(int uid, const std::string& viewer,
    int width, int height, int hz) {
#if defined(CLOUDPLAYPLUS_SERVICE_CONSOLE_RECOVERY)
    using namespace cloudplayplus::unattended;
    if (!IsManagedDisplayClient()) return true;
    if (!has_backup_ || viewer.empty() || viewer.size() >= sizeof(handed_display.viewer)) return false;
    DisplayHandoffData data;
    data.present = 1; data.uid = uid; data.width = width; data.height = height; data.hz = hz;
    data.handle = reinterpret_cast<std::uint64_t>(vdd_handle_);
    std::copy(viewer.begin(), viewer.end(), data.viewer);
    const auto copy = [](const auto& paths, const auto& modes, DisplayHandoffLayout& layout) {
        if (paths.size() > kHandoffPaths || modes.size() > kHandoffModes) return false;
        layout.path_count = static_cast<UINT32>(paths.size());
        layout.mode_count = static_cast<UINT32>(modes.size());
        std::copy(paths.begin(), paths.end(), layout.paths);
        std::copy(modes.begin(), modes.end(), layout.modes);
        return true;
    };
    if (!copy(original_paths_, original_modes_, data.active) ||
        !copy(persistent_paths_, persistent_modes_, data.persistent) || !ValidDisplayHandoff(data)) return false;
    try { ExchangeDisplayHandoff(Command::retain_display, data); }
    catch (const Error& error) {
        CPPLOG_WARN("VDD_HANDOFF", "retain failed uid=%d error=%lu", uid, error.code);
        throw;
    }
    handed_display = data;
    CPPLOG_INFO("VDD_HANDOFF", "retained uid=%d generation=%llu mode=%dx%d@%d", uid,
        static_cast<unsigned long long>(data.generation), width, height, hz);
#else
    (void)uid; (void)viewer; (void)width; (void)height; (void)hz;
#endif
    return true;
}

bool VirtualDisplayControl::RecoverDisplayHandoff(int& uid, std::string& viewer,
    int& width, int& height, int& hz) {
#if defined(CLOUDPLAYPLUS_SERVICE_CONSOLE_RECOVERY)
    using namespace cloudplayplus::unattended;
    if (!IsManagedDisplayClient()) return false;
    if (!handed_display.present) {
        DisplayHandoffData data;
        try { ExchangeDisplayHandoff(Command::acquire_display, data); }
        catch (const Error& error) {
            CPPLOG_WARN("VDD_HANDOFF", "recover failed error=%lu", error.code);
            throw;
        }
        if (!data.present) return false;
        if (!ValidDisplayHandoff(data) || !data.handle) throw Error(ERROR_INVALID_DATA);
        const auto handle = reinterpret_cast<HANDLE>(data.handle);
        if (initialized_ || has_backup_) { CloseHandle(handle); throw Error(ERROR_BUSY); }
        vdd_handle_ = handle;
        original_paths_.assign(data.active.paths, data.active.paths + data.active.path_count);
        original_modes_.assign(data.active.modes, data.active.modes + data.active.mode_count);
        persistent_paths_.assign(data.persistent.paths, data.persistent.paths + data.persistent.path_count);
        persistent_modes_.assign(data.persistent.modes, data.persistent.modes + data.persistent.mode_count);
        has_backup_ = true;
        handed_display = data;
        exclusive_created_uid = static_cast<int>(data.uid);
        exclusive_requested_mode = {static_cast<int>(data.width), static_cast<int>(data.height),
                                    static_cast<int>(data.hz)};
    }
    const auto ready = PrepareRecoveredDisplay([] { return Initialize(); }, [] {
        GetAllDisplays();
        return std::any_of(displays_.begin(), displays_.end(), [](const auto& display) {
            return display->GetDisplayInfo().is_virtual &&
                display->GetDisplayUid() == static_cast<int>(handed_display.uid);
        });
    });
    if (ready != ERROR_SUCCESS) throw Error(ready);
    uid = static_cast<int>(handed_display.uid); viewer = handed_display.viewer;
    width = static_cast<int>(handed_display.width); height = static_cast<int>(handed_display.height);
    hz = static_cast<int>(handed_display.hz);
    CPPLOG_INFO("VDD_HANDOFF", "recovered uid=%d generation=%llu mode=%dx%d@%d", uid,
        static_cast<unsigned long long>(handed_display.generation), width, height, hz);
    return true;
#else
    (void)uid; (void)viewer; (void)width; (void)height; (void)hz;
    return false;
#endif
}

bool VirtualDisplayControl::SaveDisplayConfiguration() {
    if (!QueryLayout(QDC_DATABASE_CURRENT, persistent_paths_, persistent_modes_) ||
        !QueryLayout(QDC_ONLY_ACTIVE_PATHS, original_paths_, original_modes_)) return false;
    has_backup_ = true;
    return true;
}
