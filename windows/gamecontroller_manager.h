#ifndef GAME_CONTROLLER_MANAGER_H
#define GAME_CONTROLLER_MANAGER_H

#include <array>
#include <memory>
#include <string>

#include <ViGEm/Client.h>

class GameControllerManager {
public:
  static int CreateGameController();
  static bool RemoveGameController(int id);
  static bool DoControllerAction(int id, std::string& action);

private:
  static int InitializeVigem();

  static PVIGEM_CLIENT vigem_client;
  static bool initialized;
  static std::array<PVIGEM_TARGET, 4> controllers;
};

#endif // GAME_CONTROLLER_MANAGER_H
