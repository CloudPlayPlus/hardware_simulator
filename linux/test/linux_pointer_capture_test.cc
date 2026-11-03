// 在隔离 Xvfb 或嵌套 Weston 中运行，不能使用用户的真实 DISPLAY。
#include "../linux_pointer_capture.h"
#include <gdk/gdkx.h>
#include <X11/extensions/XTest.h>
#include <cassert>
#include <cmath>
#include <chrono>
#include <thread>
#include <vector>

static void pump(int ms) {
  const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  do {
    while (gtk_events_pending()) gtk_main_iteration();
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  } while (std::chrono::steady_clock::now() < end);
}
int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  auto* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(window), 600, 400);
  auto* view = gtk_drawing_area_new();
  gtk_widget_add_events(view, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_SCROLL_MASK);
  gtk_container_add(GTK_CONTAINER(window), view);
  gtk_widget_show_all(window);
  pump(300);
  const bool x11 = GDK_IS_X11_DISPLAY(gtk_widget_get_display(view));
  Display* driver = XOpenDisplay(nullptr);
  assert(driver);
  if (x11) {
    XSetInputFocus(driver, GDK_WINDOW_XID(gtk_widget_get_window(window)), RevertToParent, CurrentTime);
    XWarpPointer(driver, None, GDK_WINDOW_XID(gtk_widget_get_window(window)), 0, 0, 0, 0, 200, 200);
  } else {
    // 嵌套 compositor 的全屏测试窗口。
    XTestFakeMotionEvent(driver, -1, 300, 300, CurrentTime);
    XTestFakeButtonEvent(driver, 1, True, CurrentTime);
    XTestFakeButtonEvent(driver, 1, False, CurrentTime);
  }
  XFlush(driver);
  pump(300);
  std::vector<bool> states;
  int moves = 0, buttons = 0, scrolls = 0;
  double total_x = 0;
  g_signal_connect(view, "button-press-event", G_CALLBACK(+[](GtkWidget*, GdkEventButton*, gpointer p) -> gboolean {
    ++*static_cast<int*>(p); return FALSE;
  }), &buttons);
  g_signal_connect(view, "scroll-event", G_CALLBACK(+[](GtkWidget*, GdkEventScroll*, gpointer p) -> gboolean {
    ++*static_cast<int*>(p); return FALSE;
  }), &scrolls);
  {
    LinuxPointerCapture capture(view,
      [&](int64_t id, bool locked, const char*) { assert(id == 42 || id == 43); states.push_back(locked); },
      [&](int64_t id, double dx, double) { assert(id == 42); ++moves; total_x += std::abs(dx); });
    assert(capture.supported());
    if (x11) {
      assert(XGrabPointer(driver, DefaultRootWindow(driver), False, 0,
          GrabModeAsync, GrabModeAsync, None, None, CurrentTime) == GrabSuccess);
      XSync(driver, False);
      assert(!capture.lock(42).empty());
      assert(states.size() == 1 && !states.back());
      states.clear();
      XUngrabPointer(driver, CurrentTime); XSync(driver, False);
    }
    const auto error = capture.lock(42);
    assert(error.empty());
    pump(300);
    assert(states.size() == 1 && states.back());
    capture.unlock_generation(41); // 旧会话不能释放新会话。
    pump(30);
    assert(states.size() == 1);
    for (int i = 0; i < 30; ++i) {
      XTestFakeRelativeMotionEvent(driver, x11 ? 50 : (i % 2 ? -50 : 50), 0, CurrentTime);
      XFlush(driver); pump(5);
    }
    XTestFakeButtonEvent(driver, 1, True, CurrentTime);
    XTestFakeButtonEvent(driver, 1, False, CurrentTime);
    XTestFakeButtonEvent(driver, 4, True, CurrentTime);
    XTestFakeButtonEvent(driver, 4, False, CurrentTime);
    XFlush(driver); pump(200);
    assert(moves > 0 && total_x > 1000); // X11 单向越界；嵌套 Wayland 来回移动，避免测试源 X11 后端边缘裁剪。
    assert(buttons == 1 && scrolls > 0);
    capture.unlock_generation(42);
    assert(states.size() == 2 && !states.back());
    const auto stopped = moves;
    XTestFakeRelativeMotionEvent(driver, 5, 0, CurrentTime);
    XFlush(driver); pump(50);
    assert(moves == stopped);
    assert(capture.lock(43).empty()); pump(200);
    assert(states.back());
    gtk_widget_hide(window); pump(100);
    assert(!states.back());
  }
  gtk_widget_destroy(window); pump(20);
  XCloseDisplay(driver);
}
