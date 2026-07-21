#include "SmartKeyboardBlocker.h"
#include <chrono>

#include "cpp_log_client.h"  // CPPLOG_STREAM_* -> shared app.log

#pragma comment(lib, "imm32.lib")

// Static member variable definitions
HHOOK SmartKeyboardBlocker::hook_handle_ = nullptr;
HWND SmartKeyboardBlocker::target_window_ = nullptr;
SmartKeyboardBlocker::BlockedKeyCallback SmartKeyboardBlocker::callback_ = nullptr;
std::unordered_map<DWORD, bool> SmartKeyboardBlocker::key_states_;

bool SmartKeyboardBlocker::StartBlocking(HWND target_window, BlockedKeyCallback callback) {
    if (hook_handle_) {
        return true; // Already blocking
    }

    // Set target window and callback
    target_window_ = target_window;
    callback_ = callback;

    // If no target window specified, auto-detect current process main window
    if (!target_window_) {
        target_window_ = GetMainWindow();
    }

    if (!target_window_) {
        CPPLOG_STREAM_ERROR("KBLOCK") << "Error: No target window found!";
        return false;
    }

    ::ImmAssociateContextEx(target_window_, NULL, IACE_CHILDREN);

    // Install low-level keyboard hook
    hook_handle_ = SetWindowsHookEx(WH_KEYBOARD_LL, KeyboardHookProc, GetModuleHandle(nullptr), 0);

    if (!hook_handle_) {
        DWORD error = GetLastError();
        CPPLOG_STREAM_ERROR("KBLOCK") << "Failed to install keyboard hook. Error: " << error;
        return false;
    }

    CPPLOG_STREAM_INFO("KBLOCK") << "Smart keyboard blocking started - Will only block when your app has focus!";
    return true;
}

void SmartKeyboardBlocker::StopBlocking() {
    if (hook_handle_) {
        UnhookWindowsHookEx(hook_handle_);
        hook_handle_ = nullptr;
        if (target_window_ != nullptr) {
            ImmAssociateContextEx(target_window_, nullptr, IACE_DEFAULT | IACE_CHILDREN);
        }
        target_window_ = nullptr;
        callback_ = nullptr;
        key_states_.clear(); // Clear key states
        CPPLOG_STREAM_INFO("KBLOCK") << "Keyboard blocking stopped.";
    }
}

LRESULT CALLBACK SmartKeyboardBlocker::KeyboardHookProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code < 0 || !hook_handle_) {
        return CallNextHookEx(nullptr, code, wParam, lParam);
    }

    // Key check: only block when target window is active
    if (!IsTargetWindowActive()) {
        // Target window not active, let other apps use shortcuts normally
        return CallNextHookEx(nullptr, code, wParam, lParam);
    }

    KBDLLHOOKSTRUCT* kb_struct = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    DWORD vk_code = kb_struct->vkCode;
    bool is_key_down = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
    
    /*
    // Only process on key down to avoid duplicate callbacks
    if (!is_key_down) {
        return CallNextHookEx(nullptr, code, wParam, lParam);
    }
    */

    if (ShouldBlockKey(vk_code)) {
        // Check if this is a repeat key event using key states tracking
        auto it = key_states_.find(vk_code);
        bool was_down = (it != key_states_.end()) ? it->second : false;
        
        // Only call callback if state changed (new press or release)
        if (was_down != is_key_down) {
            // Call callback to notify user
            if (callback_) {
                callback_(vk_code, is_key_down);
            }
            
            // Update key state
            key_states_[vk_code] = is_key_down;
        }

        // Block this key - return 1 to prevent system processing
        return 1;
    }

    // No need to block, let system process normally
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

bool SmartKeyboardBlocker::ShouldBlockKey(DWORD vk_code) {
    switch (vk_code) {
    case VK_LWIN:
    case VK_RWIN:
        return true;

    // TODO: Therotically we don't need to block VK_MENU
    // However there is a bug on flutter windows that ALT
    // is not triggered when press ALT frequently.
    case VK_LMENU:
        return true;
    case VK_RMENU:
        return true;

    case VK_RCONTROL:
        return true;

    case VK_TAB:
        // Check if Alt is also pressed
        if (GetAsyncKeyState(VK_MENU) & 0x8000) {
            return true;
        }
        break;

    case VK_F4:
        // Check if Alt is also pressed
        if (GetAsyncKeyState(VK_MENU) & 0x8000) {
            return true;
        }
        break;

    case VK_ESCAPE:
        // Check if Ctrl+Alt are also pressed
        if ((GetAsyncKeyState(VK_CONTROL) & 0x8000) && (GetAsyncKeyState(VK_MENU) & 0x8000)) {
            return true;
        }
        break;
    }

    return false;
}

bool SmartKeyboardBlocker::IsTargetWindowActive() {
    if (!target_window_) {
        return false;
    }

    // Get current active window
    HWND active_window = GetForegroundWindow();

    // Check if active window is our target window or its child window
    HWND current = active_window;
    while (current) {
        if (current == target_window_) {
            return true;
        }
        current = GetParent(current);
    }

    return false;
}

HWND SmartKeyboardBlocker::GetMainWindow() {
    //DWORD process_id = GetCurrentProcessId();
    HWND main_window = nullptr;

    // Enumerate all top-level windows to find current process main window
    EnumWindows(EnumWindowsProc, reinterpret_cast<LPARAM>(&main_window));

    return main_window;
}

BOOL CALLBACK SmartKeyboardBlocker::EnumWindowsProc(HWND hwnd, LPARAM lParam) {
    DWORD process_id;
    GetWindowThreadProcessId(hwnd, &process_id);

    // Check if this is current process window
    if (process_id == GetCurrentProcessId()) {
        // Check if this is a visible top-level window
        if (IsWindowVisible(hwnd) && GetParent(hwnd) == nullptr) {
            // Check if window has title (exclude system windows)
            char title[256];
            if (GetWindowTextA(hwnd, title, sizeof(title)) > 0) {
                HWND* result = reinterpret_cast<HWND*>(lParam);
                *result = hwnd;
                return FALSE; // Found, stop enumeration
            }
        }
    }

    return TRUE; // Continue enumeration
}
