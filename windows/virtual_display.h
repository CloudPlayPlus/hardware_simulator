#ifndef VIRTUAL_DISPLAY_H_
#define VIRTUAL_DISPLAY_H_

#include <windows.h>
#include <string>
#include <vector>

class VirtualDisplay {
public:
    enum Orientation {
        Landscape = 0,      // Angle0
        Portrait,           // Angle90
        Landscape_Flipped,  // Angle180
        Portrait_Flipped    // Angle270
    };

    enum TopologyMode {
        Extend = 0,         // Extend desktop
        Duplicate,          // Mirror/Duplicate displays
        Internal,           // Internal display only
        External,           // External display only
        Clone               // Clone mode
    };

    struct DisplayConfig {
        int width;
        int height;
        int refresh_rate;
        
        DisplayConfig() : width(0), height(0), refresh_rate(0) {}
        DisplayConfig(int w, int h, int rate = 60) : width(w), height(h), refresh_rate(rate) {}
        
        uint64_t GetBits() const { return (static_cast<uint64_t>(width) << 32) | height; }
    };

    struct DisplayInfo {
        bool   active        = false;
        bool   is_virtual    = false;  // Whether this is a virtual display
        int    display_uid   = 0;       // Display unique identifier  
        std::string device_name;         // "\\\\.\\DISPLAYn"
        std::string display_name; 
        std::string device_description;   
        FILETIME last_arrival;
        int    left          = 0;
        int    top           = 0;
        int    right         = 0;
        int    bottom        = 0;
        bool   is_primary    = false;
    };


    VirtualDisplay();
    VirtualDisplay(const DisplayConfig& config, const DisplayInfo& info, int display_uid = -1)
        : config_(config), info_(info), display_uid_(display_uid), 
          current_orientation_(Landscape) {}
    ~VirtualDisplay();

    bool ChangeDisplaySettings(const DisplayConfig& config);
    void FetchAllDisplayConfigs();
    void UpdateDisplayBounds();
    DisplayConfig GetConfig() const { return config_; }
    DisplayInfo GetDisplayInfo() const { return info_; }
    int GetDisplayUid() const { return display_uid_; }
    void SetDisplayUid(int uid) { display_uid_ = uid; }
    
    const std::vector<DisplayConfig>& GetDisplayConfigList() const;
    const DisplayConfig& GetCurrentDisplayConfig() const { return config_; }
    
    // Orientation management
    Orientation GetCurrentOrientation() const { return current_orientation_; }
    void SetCurrentOrientation(Orientation orientation) {
        current_orientation_ = orientation;
    }
    bool SetOrientation(Orientation orientation);
    
    // Static methods for system-wide display topology
    static bool SetSystemDisplayTopology(TopologyMode mode);
    static TopologyMode GetSystemDisplayTopology();

private:
    DisplayConfig config_;
    DisplayInfo info_;
    int display_uid_;
    
    std::vector<DisplayConfig> display_config_list_;
    Orientation current_orientation_;

    VirtualDisplay(const VirtualDisplay&) = delete;
    VirtualDisplay& operator=(const VirtualDisplay&) = delete;
};

#endif