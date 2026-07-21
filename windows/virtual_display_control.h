#ifndef FLUTTER_PLUGIN_VIRTUAL_DISPLAY_CONTROL_H_
#define FLUTTER_PLUGIN_VIRTUAL_DISPLAY_CONTROL_H_

#include "parsec-vdd.h"
#include "virtual_display.h" 
#include <windows.h>
#include <vector>
#include <memory>
#include <string>

class VirtualDisplayControl {
public:
    // Multi-display mode enumeration
    enum class MultiDisplayMode {
        Extend = 0,        
        PrimaryOnly,       
        SecondaryOnly,     
        Duplicate,         
        Unknown
    };

    static bool Initialize();
    static bool EnsureConsoleForDisplay();
    static void Shutdown();
    static int AddDisplay();
    static bool RemoveDisplay(int display_uid);

    static int GetDisplayCount();
    static std::vector<int> GetDisplayList();
    static bool IsInitialized() { 
        return initialized_; 
    }
    
    static bool CheckVddStatus();
    static int GetAllDisplays();
    static bool ChangeDisplaySettings(int display_uid, const VirtualDisplay::DisplayConfig& config);
    static std::vector<VirtualDisplay::DisplayConfig> GetDisplayConfigs(int display_uid);
    static std::vector<VirtualDisplay::DisplayConfig> GetCustomDisplayConfigs();
    static bool SetCustomDisplayConfigs(const std::vector<VirtualDisplay::DisplayConfig>& configs);

    // Display orientation and topology management
    static bool SetDisplayOrientation(int display_uid, VirtualDisplay::Orientation orientation);
    static VirtualDisplay::Orientation GetDisplayOrientation(int display_uid);

    // Multi-display configuration using DisplayConfig API
    static bool SetMultiDisplayMode(MultiDisplayMode mode, int primary_display_id = 0);
    static MultiDisplayMode GetCurrentMultiDisplayMode();

    // Display control APIs for setting primary display and disabling others
    static bool SetPrimaryDisplayOnly(int display_uid);
    static bool RestoreDisplayConfiguration();
    static bool HasPendingConfiguration();

    // Detailed display information structure
    // This structure mirrors the Dart DisplayData class for consistency
    struct DetailedDisplayInfo {
        // Array index
        int index = -1;
        
        // Display configuration (from VirtualDisplay::DisplayConfig)
        int width = 1920;
        int height = 1080;
        int refresh_rate = 60;
        
        // Display information (from VirtualDisplay::DisplayInfo)
        bool active = false;
        int display_uid = 0;           // Unique display identifier
        std::string device_name;       // Device name like "\\\\.\\DISPLAYn"
        std::string display_name;      // Human-readable display name
        std::string device_description; // Device description
        FILETIME last_arrival;         // Last arrival time
        
        // Display bounds coordinates
        int left = 0;
        int top = 0;
        int right = 0;
        int bottom = 0;
        bool is_primary = false;
        
        // Additional fields
        bool is_virtual = false;       // Whether this is a virtual display
        int orientation = 0;           // Display orientation (0=landscape, 1=portrait, 2=landscape_flipped, 3=portrait_flipped)
    };
    static std::vector<DetailedDisplayInfo> GetDetailedDisplayList();

    VirtualDisplayControl() = delete;
    VirtualDisplayControl(const VirtualDisplayControl&) = delete;
    VirtualDisplayControl& operator=(const VirtualDisplayControl&) = delete;

private:
    static bool initialized_;
    static HANDLE vdd_handle_;
    static std::vector<std::unique_ptr<VirtualDisplay>> displays_;
    
    // Display configuration backup for restore functionality
    static std::vector<DISPLAYCONFIG_PATH_INFO> original_paths_;
    static std::vector<DISPLAYCONFIG_MODE_INFO> original_modes_;
    static bool has_backup_;
    
    // Helper method to save current display configuration
    static bool SaveDisplayConfiguration();
};

#endif