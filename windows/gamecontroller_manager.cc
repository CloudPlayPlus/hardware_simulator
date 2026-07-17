#include "gamecontroller_manager.h"

#include <sstream>
#include <Xinput.h>

#include "cpp_log_adapter.h"

PVIGEM_CLIENT GameControllerManager::vigem_client = nullptr;
bool GameControllerManager::initialized = false;
std::array<PVIGEM_TARGET, 4> GameControllerManager::controllers = {};

int GameControllerManager::InitializeVigem() {
  vigem_client = vigem_alloc();
  if (vigem_client == nullptr) {
    CPPLOG_ERROR("GAMEPAD", "vigem_alloc failed: not enough memory");
    return -1;
  }

  const auto retval = vigem_connect(vigem_client);
  if (!VIGEM_SUCCESS(retval)) {
    CPPLOG_ERROR("GAMEPAD", "ViGEm Bus connection failed: 0x%X",
                 static_cast<unsigned int>(retval));
    return -1;
  }
  initialized = true;
  CPPLOG_INFO("GAMEPAD", "ViGEm Bus connected");
  return 0;
}

int GameControllerManager::CreateGameController() {
  if (!initialized && InitializeVigem() != 0) {
    return -1;
  }

  for (int i = 0; i < 4; ++i) {
    if (controllers[i] == nullptr) {
      const auto pad = vigem_target_x360_alloc();
      controllers[i] = pad;

      //
      // Add client to the bus, this equals a plug-in event
      //
      const auto pir = vigem_target_add(vigem_client, pad);

      //
      // Error handling
      //
      if (!VIGEM_SUCCESS(pir)) {
        CPPLOG_ERROR("GAMEPAD", "vigem_target_add failed: 0x%X",
                     static_cast<unsigned int>(pir));
        return -1;
      }
      CPPLOG_INFO("GAMEPAD", "GameController created in slot %d", i + 1);
      return i + 1;
    }
  }

  CPPLOG_ERROR("GAMEPAD", "No available slot for GameController");
  return -1;
}

bool GameControllerManager::RemoveGameController(int id) {
  if (id < 1 || id > 4) {
    CPPLOG_ERROR("GAMEPAD", "Invalid slot id: %d", id);
    return false;
  }

  int index = id - 1;
  if (controllers[index] != nullptr) {
    const auto pir = vigem_target_remove(vigem_client, controllers[index]);
    //
    // Error handling
    //
    if (!VIGEM_SUCCESS(pir)) {
      CPPLOG_ERROR("GAMEPAD", "vigem_target_remove failed: 0x%X",
                   static_cast<unsigned int>(pir));
      return false;
    }
    CPPLOG_INFO("GAMEPAD", "GameController removed from slot %d", id);
    return true;
  }

  CPPLOG_ERROR("GAMEPAD", "Slot %d is already empty", id);
  return false;
}

bool GameControllerManager::DoControllerAction(int id, std::string& action) {
    std::istringstream iss(action);

    _XINPUT_GAMEPAD gamepad;

    iss >> gamepad.wButtons;
    int nextparam;
    iss >> nextparam;
    gamepad.bLeftTrigger = (BYTE)nextparam;
    iss >> nextparam;
    gamepad.bRightTrigger = (BYTE)nextparam;

    iss >> gamepad.sThumbLX;
    iss >> gamepad.sThumbLY;
    iss >> gamepad.sThumbRX;
    iss >> gamepad.sThumbRY;

    const auto pir = vigem_target_x360_update(
        vigem_client, controllers[id - 1],
        *reinterpret_cast<XUSB_REPORT*>(&gamepad));

    if (!VIGEM_SUCCESS(pir)) {
        CPPLOG_ERROR("GAMEPAD", "vigem_target_x360_update failed: 0x%X",
                     static_cast<unsigned int>(pir));
        return false;
    }
    // Per-input-frame; keep at trace so it does not flood app.log at the
    // default (info) level.
    CPPLOG_TRACE("GAMEPAD", "GameController updated slot %d", id);
    return true;
}
