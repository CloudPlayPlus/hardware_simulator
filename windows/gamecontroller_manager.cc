#include "gamecontroller_manager.h"
#include "cpp_log_shim.h"

#include <sstream>
#include <Xinput.h>

PVIGEM_CLIENT GameControllerManager::vigem_client = nullptr;
bool GameControllerManager::initialized = false;
std::array<PVIGEM_TARGET, 4> GameControllerManager::controllers = {};

namespace {
struct RumbleContext { HWND window = nullptr; UINT message = 0; int token = 0; bool registered = false; };
std::array<RumbleContext, 4> rumble_contexts;
void CALLBACK OnRumble(PVIGEM_CLIENT, PVIGEM_TARGET, UCHAR large_motor, UCHAR small_motor, UCHAR, LPVOID user) {
  const auto* context = static_cast<RumbleContext*>(user);
  PostMessageW(context->window, context->message, static_cast<WPARAM>(context->token),
      static_cast<LPARAM>((static_cast<unsigned>(large_motor) << 8) | small_motor));
}
}

bool GameControllerManager::SubscribeRumble(int id, int token, HWND window, UINT message) {
  if (id < 1 || id > 4 || !controllers[id - 1] || !window || !message) return false;
  auto& context = rumble_contexts[id - 1];
  if (context.registered) vigem_target_x360_unregister_notification(controllers[id - 1]);
  context = {window, message, token, false};
  const auto status = vigem_target_x360_register_notification(vigem_client, controllers[id - 1], OnRumble, &context);
  context.registered = VIGEM_SUCCESS(status);
  return context.registered;
}

void GameControllerManager::StopRumbleNotifications() {
  for (int i = 0; i < 4; ++i) {
    if (controllers[i] && rumble_contexts[i].registered) {
      vigem_target_x360_unregister_notification(controllers[i]);
      rumble_contexts[i].registered = false;
    }
  }
}

int GameControllerManager::InitializeVigem() {
  vigem_client = vigem_alloc();
  if (vigem_client == nullptr) {
    CPPLOG_ERROR("GAMEPAD", "ViGEm client allocation failed");
    return -1;
  }

  const auto retval = vigem_connect(vigem_client);
  if (!VIGEM_SUCCESS(retval)) {
    CPPLOG_ERROR("GAMEPAD", "ViGEm Bus connection failed: 0x%X",
                 static_cast<unsigned int>(retval));
    return -1;
  }
  initialized = true;
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
        CPPLOG_ERROR("GAMEPAD", "ViGEm target add failed: 0x%X",
                     static_cast<unsigned int>(pir));
        return -1;
      }
      CPPLOG_INFO("GAMEPAD", "Game controller created in slot %d", i + 1);
      return i + 1;
    }
  }

  CPPLOG_WARN("GAMEPAD", "No available game controller slot");
  return -1;
}

bool GameControllerManager::RemoveGameController(int id) {
  if (id < 1 || id > 4) {
    CPPLOG_WARN("GAMEPAD", "Invalid game controller slot: %d", id);
    return false;
  }

  int index = id - 1;
  if (controllers[index] != nullptr) {
    const bool had_rumble = rumble_contexts[index].registered;
    if (had_rumble) {
      vigem_target_x360_unregister_notification(controllers[index]);
      rumble_contexts[index].registered = false;
    }
    const auto pir = vigem_target_remove(vigem_client, controllers[index]);
    //
    // Error handling
    //
    if (!VIGEM_SUCCESS(pir)) {
        CPPLOG_ERROR("GAMEPAD", "Game controller removal failed: 0x%X",
                     static_cast<unsigned int>(pir));
        const auto& context = rumble_contexts[index];
        if (had_rumble && !SubscribeRumble(id, context.token, context.window, context.message)) {
          CPPLOG_WARN("GAMEPAD", "Unable to restore gamepad rumble notification");
        }
        return false;
    }
    vigem_target_free(controllers[index]);
    controllers[index] = nullptr;
    CPPLOG_INFO("GAMEPAD", "Game controller removed from slot %d", id);
    return true;
  }

  CPPLOG_WARN("GAMEPAD", "Game controller slot %d is already empty", id);
  return false;
}

bool GameControllerManager::DoControllerAction(int id, std::string& action) {
    if (id < 1 || id > 4 || controllers[id - 1] == nullptr) {
        CPPLOG_WARN("GAMEPAD", "Cannot update unavailable game controller slot: %d", id);
        return false;
    }
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
        CPPLOG_ERROR("GAMEPAD", "Game controller update failed: 0x%X",
                     static_cast<unsigned int>(pir));
        return false;
    }
    return true;
}
