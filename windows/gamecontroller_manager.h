#ifndef GAME_CONTROLLER_MANAGER_H
#define GAME_CONTROLLER_MANAGER_H

#include <array>
#include <memory>
#include <string>

#include <windows.h>
#include <ViGEm/Client.h>

class GameControllerManager {
public:
  static int CreateGameController();
  static bool RemoveGameController(int id);
  static bool SubscribeRumble(int id, int token, HWND window, UINT message);
  static bool ResolveRumble(WPARAM cookie, int& id, int& token);
  static void StopRumbleNotifications();
  static bool DoControllerAction(int id, std::string& action);

private:
  static int InitializeVigem();

  static PVIGEM_CLIENT vigem_client;
  static bool initialized;
  static std::array<PVIGEM_TARGET, 4> controllers;
};

#endif // GAME_CONTROLLER_MANAGER_H
