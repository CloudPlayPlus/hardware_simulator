#include "virtual_display.h"
#include "parsec-vdd.h"
#include <cstring>
#include <cstdio>

#include "cpp_log_client.h"  // CPPLOG_STREAM_* -> shared app.log

#ifndef WINVER
#define WINVER 0x0600
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif

#include <windows.h>
#include <cfgmgr32.h>
#include <setupapi.h>

#include <vector>
#include <algorithm>
#include <devpkey.h>


VirtualDisplay::VirtualDisplay() : display_uid_(-1), current_orientation_(Landscape){
    CPPLOG_STREAM_INFO("VDISPLAY") << "VirtualDisplay created";
    config_ = DisplayConfig();
}

VirtualDisplay::~VirtualDisplay() {
}

bool VirtualDisplay::ChangeDisplaySettings(const DisplayConfig& config) {
    
    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    dm.dmPelsWidth = config.width;
    dm.dmPelsHeight = config.height;
    dm.dmDisplayFrequency = config.refresh_rate;    
    dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
    
    std::wstring device_name_w(info_.device_name.begin(), info_.device_name.end());
    LONG result = ChangeDisplaySettingsExW(device_name_w.c_str(), 
                                           &dm, NULL, CDS_UPDATEREGISTRY, NULL);
    return (result == DISP_CHANGE_SUCCESSFUL);
}

void VirtualDisplay::FetchAllDisplayConfigs() {
    DEVMODEW dev_mode = {};
    dev_mode.dmSize = sizeof(DEVMODEW);

    display_config_list_.clear();

    std::wstring device_name_w(info_.device_name.begin(), info_.device_name.end());
    
    for (int config_num = -1; EnumDisplaySettingsW(device_name_w.c_str(), config_num, &dev_mode); config_num++) {
        DisplayConfig display_config;
        display_config.width = dev_mode.dmPelsWidth;
        display_config.height = dev_mode.dmPelsHeight;
        display_config.refresh_rate = dev_mode.dmDisplayFrequency;

        if (config_num == -1) {
            config_ = display_config;
            current_orientation_ = static_cast<VirtualDisplay::Orientation>(dev_mode.dmDisplayOrientation);
        } else {
            display_config_list_.push_back(display_config);
        }
    }

    std::sort(display_config_list_.begin(), display_config_list_.end(),
              [](const DisplayConfig& a, const DisplayConfig& b) {
                  if (a.width != b.width) return a.width < b.width;
                  if (a.height != b.height) return a.height < b.height;
                  return a.refresh_rate < b.refresh_rate;
              });
}

void VirtualDisplay::UpdateDisplayBounds() {
    std::wstring device_name_w(info_.device_name.begin(), info_.device_name.end());
    
    DEVMODEW dev_mode = {};
    dev_mode.dmSize = sizeof(DEVMODEW);
    
    if (EnumDisplaySettingsW(device_name_w.c_str(), ENUM_CURRENT_SETTINGS, &dev_mode)) {
        info_.left = static_cast<int>(dev_mode.dmPosition.x);
        info_.top = static_cast<int>(dev_mode.dmPosition.y);
        info_.right = info_.left + static_cast<int>(dev_mode.dmPelsWidth);
        info_.bottom = info_.top + static_cast<int>(dev_mode.dmPelsHeight);
        
        DISPLAY_DEVICEW display_device = {};
        display_device.cb = sizeof(DISPLAY_DEVICEW);
        
        for (DWORD device_index = 0; EnumDisplayDevicesW(nullptr, device_index, &display_device, 0); device_index++) {
            if (wcscmp(display_device.DeviceName, device_name_w.c_str()) == 0) {
                info_.is_primary = (display_device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
                break;
            }
        }
    } else {
        HMONITOR monitor = nullptr;
        auto params = std::make_pair(&device_name_w, &monitor);
        
        EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR hMon, HDC, LPRECT, LPARAM lParam) -> BOOL {
            auto* params = reinterpret_cast<std::pair<std::wstring*, HMONITOR*>*>(lParam);
            
            MONITORINFOEXW monitor_info = {};
            monitor_info.cbSize = sizeof(MONITORINFOEXW);
            
            if (GetMonitorInfoW(hMon, &monitor_info)) {
                if (wcscmp(monitor_info.szDevice, params->first->c_str()) == 0) {
                    *(params->second) = hMon;
                    return FALSE;
                }
            }
            return TRUE;
        }, reinterpret_cast<LPARAM>(&params));
        
        if (monitor) {
            MONITORINFOEXW monitor_info = {};
            monitor_info.cbSize = sizeof(MONITORINFOEXW);
            
            if (GetMonitorInfoW(monitor, &monitor_info)) {
                info_.left = monitor_info.rcMonitor.left;
                info_.top = monitor_info.rcMonitor.top;
                info_.right = monitor_info.rcMonitor.right;
                info_.bottom = monitor_info.rcMonitor.bottom;
                info_.is_primary = (monitor_info.dwFlags & MONITORINFOF_PRIMARY) != 0;
            }
        }
    }
}

const std::vector<VirtualDisplay::DisplayConfig>& VirtualDisplay::GetDisplayConfigList() const {
    const_cast<VirtualDisplay*>(this)->FetchAllDisplayConfigs();
    return display_config_list_;
}

bool VirtualDisplay::SetOrientation(Orientation orientation) {
    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);

    if(current_orientation_ == orientation){
        return true;
    }
    
    std::wstring device_name_w(info_.device_name.begin(), info_.device_name.end());
    
    if (EnumDisplaySettingsW(device_name_w.c_str(), ENUM_CURRENT_SETTINGS, &dm)) {
        DWORD original_width = dm.dmPelsWidth;
        DWORD original_height = dm.dmPelsHeight;
        
        dm.dmDisplayOrientation = static_cast<DWORD>(orientation);
        
        bool current_is_portrait = (current_orientation_ == Portrait || current_orientation_ == Portrait_Flipped);
        bool target_is_portrait = (orientation == Portrait || orientation == Portrait_Flipped);
        
        if (current_is_portrait != target_is_portrait) {
            dm.dmPelsWidth = original_height;
            dm.dmPelsHeight = original_width;
        } else {
            dm.dmPelsWidth = original_width;
            dm.dmPelsHeight = original_height;
        }

        dm.dmFields = DM_DISPLAYORIENTATION | DM_PELSWIDTH | DM_PELSHEIGHT;
        
        LONG result = ::ChangeDisplaySettingsExW(device_name_w.c_str(), &dm, NULL, CDS_UPDATEREGISTRY, NULL);
        if (result == DISP_CHANGE_SUCCESSFUL) {
            current_orientation_ = orientation;
            return true;
        } else {
            CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to set orientation. Error code: " << result;
        }
    } else {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to get current display settings for device: " << info_.device_name;
    }
    return false;
}

bool VirtualDisplay::SetSystemDisplayTopology(TopologyMode mode) {
    UINT32 path_count = 0;
    UINT32 mode_count = 0;
    
    LONG result = GetDisplayConfigBufferSizes(QDC_ALL_PATHS, &path_count, &mode_count);
    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to get display config buffer sizes: " << result;
        return false;
    }
    
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
    
    result = QueryDisplayConfig(QDC_ALL_PATHS, &path_count, paths.data(), 
                               &mode_count, modes.data(), nullptr);
    if (result != ERROR_SUCCESS) {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to query display config: " << result;
        return false;
    }
    
    UINT32 flags = SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG;
    switch (mode) {
        case Extend:
            flags |= SDC_TOPOLOGY_EXTEND;
            break;
        case Duplicate:
            flags |= SDC_TOPOLOGY_CLONE;
            break;
        case Internal:
            flags |= SDC_TOPOLOGY_INTERNAL;
            break;
        case External:
            flags |= SDC_TOPOLOGY_EXTERNAL;
            break;
        case Clone:
            flags |= SDC_TOPOLOGY_CLONE;
            break;
    }
    
    result = SetDisplayConfig(path_count, paths.data(), mode_count, modes.data(), flags);
    if (result == ERROR_SUCCESS) {
        CPPLOG_STREAM_INFO("VDISPLAY") << "Successfully set display topology mode: " << mode;
        return true;
    } else {
        CPPLOG_STREAM_ERROR("VDISPLAY") << "Failed to set display topology: " << result;
        return false;
    }
}

VirtualDisplay::TopologyMode VirtualDisplay::GetSystemDisplayTopology() {
    UINT32 path_count = 0;
    UINT32 mode_count = 0;
    
    LONG result = GetDisplayConfigBufferSizes(QDC_ALL_PATHS, &path_count, &mode_count);
    if (result != ERROR_SUCCESS) {
        return Extend;
    }
    
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
    
    result = QueryDisplayConfig(QDC_ALL_PATHS, &path_count, paths.data(), 
                               &mode_count, modes.data(), nullptr);
    if (result != ERROR_SUCCESS) {
        return Extend;
    }
    
    int active_displays = 0;
    bool has_clone = false;
    
    for (const auto& path : paths) {
        if (path.flags & DISPLAYCONFIG_PATH_ACTIVE) {
            active_displays++;
            if (path.flags & DISPLAYCONFIG_PATH_CLONE_GROUP_INVALID) {
                has_clone = true;
            }
        }
    }
    
    if (active_displays <= 1) {
        return Internal;
    } else if (has_clone) {
        return Duplicate;
    } else {
        return Extend;
    }
}