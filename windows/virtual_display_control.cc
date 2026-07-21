#include "virtual_display_control.h"
#include <thread>
#include <chrono>
#include <algorithm>
#include <cstring>
#include <cstdio>

#include "cpp_log_client.h"  // CPPLOG_STREAM_* -> shared app.log

#define INITGUID
#include <windows.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <devpkey.h>    // DEVPKEY_Device_*
#include <winuser.h>    // DisplayConfig APIs

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
bool VirtualDisplayControl::has_backup_ = false;

namespace {

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
                CPPLOG_STREAM_WARN("VDISPLAY") << "ParseDisplayAddress: Error parsing number: " << e.what();
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

bool VirtualDisplayControl::Initialize() {
    if (initialized_) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "VirtualDisplayControl already initialized";
        return true;
    }
    
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
            break;
    }
    
    vdd_handle_ = parsec_vdd::OpenDeviceHandle(&parsec_vdd::VDD_ADAPTER_GUID);
    
    if (vdd_handle_ == NULL || vdd_handle_ == INVALID_HANDLE_VALUE) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Failed to open Parsec VDD device handle";
        return false;
    }
    
    int version = parsec_vdd::VddVersion(vdd_handle_);
    if (version >= 0) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Parsec VDD initialized successfully, version: " << version;
    } else {
        CPPLOG_STREAM_WARN("VDISPLAY") << "Warning: Failed to get VDD version";
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
    displays_.clear();
}

int VirtualDisplayControl::AddDisplay() {
    if (!initialized_ || vdd_handle_ == INVALID_HANDLE_VALUE) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: VirtualDisplayControl not initialized";
        return -1;
    }
    
    int vdd_index = parsec_vdd::VddAddDisplay(vdd_handle_);
    if (vdd_index >= 0) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Virtual display added: " << vdd_index;
        std::ignore = VirtualDisplayControl::GetAllDisplays();
        return vdd_index;
    } else {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Failed to add display to VDD";
        return -1;
    }
}

bool VirtualDisplayControl::RemoveDisplay(int display_uid) {
    if (!initialized_ || vdd_handle_ == INVALID_HANDLE_VALUE) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: VirtualDisplayControl not initialized";
        return false;
    }

    CPPLOG_STREAM_INFO("VDISPLAY") << "get remove call with id" << display_uid;
    
    auto it = std::find_if(displays_.begin(), displays_.end(), 
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display->GetDisplayUid() == display_uid;
        });
    
    if (it == displays_.end()) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Display not found";
        return false;
    }

    if(it->get()->GetDisplayInfo().is_virtual == false) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Cannot remove non-virtual display";
        return false;
    }
    
    parsec_vdd::VddRemoveDisplay(vdd_handle_, display_uid);
    displays_.erase(it);
    CPPLOG_STREAM_INFO("VDISPLAY") << "Virtual display removed: " << display_uid;
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
                if (device_id.find(p) != std::string::npos) {
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

                if (ParseDisplayCode(device_id).compare(parsec_vdd::VDD_DISPLAY_ID) == 0) {
                    d.is_virtual = true;
                } else {
                    d.is_virtual = false;
                }

                d.active      = !!(ddMonitor.StateFlags & DISPLAY_DEVICE_ACTIVE);
                std::wstring w_device_name(ddAdapter.DeviceName);
                d.device_name  = WideStringToString(w_device_name);
                d.display_name = ParseDisplayCode(device_id);

                DEVINST dev_inst;
                if (GetDeviceInstance(devicePath, dev_inst)) {
                    GetDeviceLastArrival(dev_inst, d.last_arrival);
                    GetDeviceDescription(dev_inst, d.device_description);
                }else{
                    CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to get device instance for: " << device_id;
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
                    
                    CPPLOG_STREAM_INFO("VDISPLAY") << "Device: " << WideStringToString(ddAdapter.DeviceName) 
                              << ", Raw orientation: " << dm.dmDisplayOrientation 
                              << ", Casted orientation: " << static_cast<int>(current_orientation_)
                              << ", Resolution: " << dm.dmPelsWidth << "x" << dm.dmPelsHeight;
                } 

                std::unique_ptr<VirtualDisplay> display = std::make_unique<VirtualDisplay>(config, d);
                if(d.is_virtual) {
                    display->SetDisplayUid(d.display_uid - 256);
                } else { 
                    display->SetDisplayUid(d.display_uid);
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
    
    CPPLOG_STREAM_INFO("VDISPLAY") << "Total displays loaded: " << displays_.size() << " (sorted by arrival time)\n";
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
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Invalid display UID:" << display_uid;
        return false;
    }

    auto& display = *it;
    if (!display) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Display not found";
        return false;
    }
    
    if (!display->ChangeDisplaySettings(config)) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Failed to change display settings";
        return false;
    }

    CPPLOG_STREAM_INFO("VDISPLAY") << "Display settings changed for UID: " << display_uid;
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
            CPPLOG_STREAM_INFO("VDISPLAY") << "Display[" << i << "]: null pointer";
        }
    }

    CPPLOG_STREAM_INFO("VDISPLAY") << "Returning " << result.size() << " displays";
    return result;
}

std::vector<VirtualDisplay::DisplayConfig> VirtualDisplayControl::GetDisplayConfigs(int display_uid) {
    auto it = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (it == displays_.end()) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Display not found for UID: " << display_uid;
        return {};
    }

    auto& display = *it;
    if (!display) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Display pointer is null";
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
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to open Parsec VDD registry key";
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
    CPPLOG_STREAM_INFO("VDISPLAY") << "Retrieved " << configs.size() << " custom display configs from registry";
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
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to create/open Parsec VDD registry key. Admin rights required.";
        return false;
    }
    
    for (int i = 0; i < 5; i++) {
        std::wstring subkey_name = std::to_wstring(i);
        
        if (i >= static_cast<int>(configs.size())) {
            result = RegDeleteKeyW(vdd_key, subkey_name.c_str());
            if (result == ERROR_SUCCESS) {
                CPPLOG_STREAM_INFO("VDISPLAY") << "Deleted registry subkey: " << i;
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
                
                CPPLOG_STREAM_INFO("VDISPLAY") << "Set custom display config " << i << ": " 
                          << config.width << "x" << config.height << "@" << config.refresh_rate << "Hz";
                
                RegCloseKey(index_key);
            } else {
                CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to create registry subkey: " << i;
                RegCloseKey(vdd_key);
                return false;
            }
        }
    }
    
    RegCloseKey(vdd_key);
    CPPLOG_STREAM_INFO("VDISPLAY") << "Successfully set " << configs.size() << " custom display configs";
    return true;
}

bool VirtualDisplayControl::SetDisplayOrientation(int display_uid, VirtualDisplay::Orientation orientation) {
    auto it = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (it == displays_.end()) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Invalid display UID:" << display_uid;
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
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: Invalid display UID:" << display_uid;
        return VirtualDisplay::Landscape; // Default orientation
    }

    auto& display = *it;

    return display->GetCurrentOrientation();
}

bool VirtualDisplayControl::SetMultiDisplayMode(MultiDisplayMode mode, int primary_display_id) {
    UINT32 flags = SDC_APPLY;
    
    switch (mode) {
        case MultiDisplayMode::Extend:
            flags |= SDC_TOPOLOGY_EXTEND;
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
            CPPLOG_STREAM_ERROR("VDISPLAY") << "Unknown multi-display mode: " << static_cast<int>(mode);
            return false;
    }
    
    LONG result = SetDisplayConfig(0, nullptr, 0, nullptr, flags);
    if (result == ERROR_SUCCESS) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Successfully set multi-display mode: " << static_cast<int>(mode);
        return true;
    } else {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to set multi-display mode: " << result;
        return false;
    }
}

VirtualDisplayControl::MultiDisplayMode VirtualDisplayControl::GetCurrentMultiDisplayMode() {
    CPPLOG_STREAM_INFO("VDISPLAY") << "=== GetCurrentMultiDisplayMode called ===";
    
    UINT32 path_count = 0;
    UINT32 mode_count = 0;
    
    LONG result = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count);
    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to get display config buffer sizes: " << result;
        return MultiDisplayMode::Unknown;
    }
    
    CPPLOG_STREAM_INFO("VDISPLAY") << "Buffer sizes - paths: " << path_count << ", modes: " << mode_count;
    
    if (path_count == 0) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "No display paths found";
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
    
    CPPLOG_STREAM_INFO("VDISPLAY") << "QueryDisplayConfig result: " << result;
    
    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to query display config: " << result;
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
            CPPLOG_STREAM_INFO("VDISPLAY") << "Active path: adapter=" << path.sourceInfo.adapterId.HighPart 
                      << ":" << path.sourceInfo.adapterId.LowPart 
                      << ", sourceId=" << path.sourceInfo.id;
        }
    }
    
    CPPLOG_STREAM_INFO("VDISPLAY") << "Active paths: " << active_paths << ", Unique sources: " << unique_sources.size();
    
    if (active_paths <= 1) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Returning: PrimaryOnly (single display)";
        return MultiDisplayMode::PrimaryOnly;
    }
    
    if (unique_sources.size() == 1 && active_paths > 1) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Returning: Duplicate (one source, multiple targets)";
        return MultiDisplayMode::Duplicate;
    }
    
    if (unique_sources.size() > 1 && unique_sources.size() == static_cast<size_t>(active_paths)) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Returning: Extend (one-to-one multiple displays)";
        return MultiDisplayMode::Extend;
    }
    
    CPPLOG_STREAM_INFO("VDISPLAY") << "Returning: SecondaryOnly (complex configuration)";
    return MultiDisplayMode::SecondaryOnly;
}

bool VirtualDisplayControl::SetPrimaryDisplayOnly(int display_uid) {
    CPPLOG_STREAM_INFO("VDISPLAY") << "SetPrimaryDisplayOnly called with display_uid: " << display_uid;
    
    // Check if there's already a pending configuration that hasn't been restored
    if (has_backup_) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Error: A display configuration is already set and not restored. Please call RestoreDisplayConfiguration() first.";
        return false;
    }
    
    // Save current configuration
    if (!SaveDisplayConfiguration()) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to save current display configuration";
        return false;
    }
    
    UINT32 numPathArrayElements = 0;
    UINT32 numModeInfoArrayElements = 0;
    LONG result = ERROR_SUCCESS;

    // Get required buffer sizes
    result = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &numPathArrayElements, &numModeInfoArrayElements);
    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "GetDisplayConfigBufferSizes failed: " << result;
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
        CPPLOG_STREAM_ERROR("VDISPLAY") << "QueryDisplayConfig failed: " << result;
        return false;
    }

    // Find the target display by matching with our display list
    auto displayIt = std::find_if(displays_.begin(), displays_.end(),
        [display_uid](const std::unique_ptr<VirtualDisplay>& display) {
            return display && display->GetDisplayUid() == display_uid;
        });

    if (displayIt == displays_.end()) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Display with UID " << display_uid << " not found in managed displays";
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
                    CPPLOG_STREAM_INFO("VDISPLAY") << "Found target display by device name: " << WideStringToString(GetDisplayTargetName(pathArray[i].targetInfo.adapterId, pathArray[i].targetInfo.id));
                    break;
                }
            }
        }
    }
    
    // If not found by device name, try to match by display index
    if (targetPathIndex == -1) {
        int displayIndex = static_cast<int>(std::distance(displays_.begin(), displayIt));
        int activePathCount = 0;
        
        for (UINT32 i = 0; i < numPathArrayElements; ++i) {
            if (pathArray[i].flags & DISPLAYCONFIG_PATH_ACTIVE) {
                if (activePathCount == displayIndex) {
                    targetPathIndex = i;
                    CPPLOG_STREAM_INFO("VDISPLAY") << "Found target display by index: " << WideStringToString(GetDisplayTargetName(pathArray[i].targetInfo.adapterId, pathArray[i].targetInfo.id));
                    break;
                }
                activePathCount++;
            }
        }
    }

    if (targetPathIndex == -1) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "No active display found to set as primary";
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

    // Apply the new configuration
    result = SetDisplayConfig(
        numPathArrayElements,
        pathArray.data(),
        numModeInfoArrayElements,
        modeInfoArray.data(),
        SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES
    );

    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "SetDisplayConfig failed: " << result;
        return false;
    }

    CPPLOG_STREAM_INFO("VDISPLAY") << "Successfully set display " << display_uid << " as primary and disabled other displays";
    return true;
}

bool VirtualDisplayControl::RestoreDisplayConfiguration() {
    CPPLOG_STREAM_INFO("VDISPLAY") << "RestoreDisplayConfiguration called";
    
    if (!has_backup_) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "No display configuration backup available to restore";
        return true;
    }

    if (original_paths_.empty()) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Original display configuration is empty. No need to restore configuration.";
        has_backup_ = false;
        return true;
    }

    // Apply the original configuration
    LONG result = SetDisplayConfig(
        static_cast<UINT32>(original_paths_.size()),
        original_paths_.data(),
        static_cast<UINT32>(original_modes_.size()),
        original_modes_.data(),
        SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES
    );

    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "SetDisplayConfig failed to restore original configuration: " << result;
        return false;
    }

    CPPLOG_STREAM_INFO("VDISPLAY") << "Successfully restored original display configuration";
    
    // Clear the backup to prevent accidental double-restore
    has_backup_ = false;
    original_paths_.clear();
    original_modes_.clear();
    
    return true;
}

bool VirtualDisplayControl::HasPendingConfiguration() {
    return has_backup_;
}

bool VirtualDisplayControl::SaveDisplayConfiguration() {
    UINT32 numPathArrayElements = 0;
    UINT32 numModeInfoArrayElements = 0;
    LONG result = ERROR_SUCCESS;

    // Get required buffer sizes
    result = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &numPathArrayElements, &numModeInfoArrayElements);
    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "GetDisplayConfigBufferSizes failed: " << result;
        return false;
    }

    // Allocate buffers
    original_paths_.resize(numPathArrayElements);
    original_modes_.resize(numModeInfoArrayElements);

    // Query current display configuration
    result = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, 
                               &numPathArrayElements, original_paths_.data(), 
                               &numModeInfoArrayElements, original_modes_.data(), 
                               nullptr);
    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "QueryDisplayConfig failed: " << result;
        return false;
    }

    has_backup_ = true;
    CPPLOG_STREAM_INFO("VDISPLAY") << "Display configuration saved successfully. Found " << numPathArrayElements << " active displays.";
    return true;
}

