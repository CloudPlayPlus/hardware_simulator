#include "../desktop_service_input_client.h"
#include "input_dispatcher.h"
#include "input_injector.h"
#include <stdexcept>
#include <vector>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (0)
namespace {
std::vector<desktop_ipc::KeyboardInput> keys;
std::vector<desktop_ipc::MouseInput> mice;
std::vector<desktop_ipc::TouchInput> touches;
std::vector<desktop_ipc::PenInput> pens;
DWORD dispatch_thread = 0;
}
namespace desktop_svc {
bool InputInjector::synchronize_desktop(bool& changed) { changed = false; return true; }
void InputInjector::send_keyboard(const desktop_ipc::KeyboardInput& value) {
  dispatch_thread = GetCurrentThreadId(); keys.push_back(value);
}
void InputInjector::send_mouse(const desktop_ipc::MouseInput& value) { mice.push_back(value); }
void InputInjector::send_touch(const desktop_ipc::TouchInput& value) { touches.push_back(value); }
void InputInjector::send_pen(const desktop_ipc::PenInput& value) { pens.push_back(value); }
void InputInjector::shutdown() {}
}
namespace hardware_simulator {
class DesktopServiceInputClientTestPeer {
 public:
  static void Run() {
    DesktopServiceInputClient client;
    // Production selection is the process token; only this private test peer
    // substitutes it. No command-line or Dart flag can enable the backend.
    client.direct_input_ = std::make_unique<desktop_svc::InputDispatcher>();
    client.SetServiceAvailable(false);
    CHECK(!client.input_thread_.joinable());
    CHECK(client.pipe_ == INVALID_HANDLE_VALUE);
    INPUT key{}; key.type = INPUT_KEYBOARD; key.ki.wVk = VK_F24;
    CHECK(client.SendInputMessage(key));
    INPUT mouse{}; mouse.type = INPUT_MOUSE;
    mouse.mi.dwFlags = MOUSEEVENTF_MOVE; mouse.mi.dx = 4;
    CHECK(client.SendInputMessage(mouse));
    POINTER_TYPE_INFO touch{}; touch.type = PT_TOUCH;
    touch.touchInfo.pointerInfo.pointerId = 12;
    touch.touchInfo.pointerInfo.pointerFlags = POINTER_FLAG_UP;
    CHECK(client.SendTouchInput(&touch, 1));
    CHECK(!client.SendTouchInput(&touch, 11));
    POINTER_TYPE_INFO pen{}; pen.type = PT_PEN;
    pen.penInfo.pointerInfo.pointerFlags = POINTER_FLAG_UP;
    CHECK(client.SendPenInput(pen));
    client.Close(); // Joins worker and releases the outstanding F24.
    CHECK(dispatch_thread != 0 && dispatch_thread != GetCurrentThreadId());
    CHECK(keys.size() == 2 && keys[0].vk == VK_F24);
    CHECK(keys[1].flags == KEYEVENTF_KEYUP);
    CHECK(mice.size() == 1 && mice[0].dx == 4);
    CHECK(touches.size() == 1 && touches[0].contacts[0].pointer_id == 12);
    CHECK(pens.size() == 1);
    CHECK(client.pipe_ == INVALID_HANDLE_VALUE && !client.input_thread_.joinable());
  }
};
}
int main() { hardware_simulator::DesktopServiceInputClientTestPeer::Run(); }
