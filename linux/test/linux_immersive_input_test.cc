// 仅在隔离 Xvfb 中运行。
#include "../linux_immersive_input.h"
#include <gdk/gdkx.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#include <cassert>
#include <chrono>
#include <thread>

static void pump() {
  const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
  do {
    while (gtk_events_pending()) gtk_main_iteration();
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  } while (std::chrono::steady_clock::now() < until);
}
int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  auto* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  auto* view = gtk_drawing_area_new();
  gtk_container_add(GTK_CONTAINER(window), view);
  gtk_widget_show_all(window);
  pump();
  auto* display = XOpenDisplay(nullptr);
  assert(display);
  const auto xid = GDK_WINDOW_XID(gtk_widget_get_window(window));
  XSetInputFocus(display, xid, RevertToParent, CurrentTime);
  XSync(display, False); pump();
  int downs = 0, ups = 0;
  g_signal_connect(window, "key-press-event", G_CALLBACK(+[](GtkWidget*, GdkEventKey*, gpointer p) -> gboolean {
    ++*static_cast<int*>(p); return TRUE;
  }), &downs);
  g_signal_connect(window, "key-release-event", G_CALLBACK(+[](GtkWidget*, GdkEventKey*, gpointer p) -> gboolean {
    ++*static_cast<int*>(p); return TRUE;
  }), &ups);
  auto grab = [&]() { return XGrabKeyboard(display, xid, True, GrabModeAsync, GrabModeAsync, CurrentTime); };
  {
    LinuxImmersiveInput input(view);
    assert(grab() == GrabSuccess);
    assert(!input.set_enabled(true)); // 另一连接持有键盘时不能报告成功。
    XUngrabKeyboard(display, CurrentTime); XSync(display, False); pump();
    assert(input.set_enabled(true));
    assert(input.set_enabled(true)); // 幂等，不创建第二个抓取。
    assert(grab() == AlreadyGrabbed);
    const auto key = XKeysymToKeycode(display, XK_Tab);
    XTestFakeKeyEvent(display, key, True, CurrentTime);
    XTestFakeKeyEvent(display, key, False, CurrentTime);
    XSync(display, False); pump();
    assert(downs == 1 && ups == 1); // GTK 正常键盘链路，无重复事件。
    assert(XGrabPointer(display, xid, True, 0, GrabModeAsync, GrabModeAsync,
                        None, None, CurrentTime) == GrabSuccess);
    assert(input.set_enabled(false));
    // 释放键盘不会释放独立连接的鼠标抓取。
    auto* probe = XOpenDisplay(nullptr);
    assert(XGrabPointer(probe, xid, True, 0, GrabModeAsync, GrabModeAsync,
                        None, None, CurrentTime) == AlreadyGrabbed);
    XCloseDisplay(probe);
    XUngrabPointer(display, CurrentTime); XSync(display, False);
    assert(grab() == GrabSuccess);
    XUngrabKeyboard(display, CurrentTime); XSync(display, False); pump();
    assert(input.set_enabled(true));
    XSetInputFocus(display, DefaultRootWindow(display), RevertToParent, CurrentTime);
    XSync(display, False); pump();
    assert(grab() == GrabSuccess); // 原生失焦释放，不依赖 Dart 通知。
    XUngrabKeyboard(display, CurrentTime);
    XSetInputFocus(display, xid, RevertToParent, CurrentTime);
    XSync(display, False); pump();
    assert(grab() == AlreadyGrabbed); // 无 Dart 重发也在原生重新激活后恢复。
    XSetInputFocus(display, DefaultRootWindow(display), RevertToParent, CurrentTime);
    XSync(display, False); pump();
    assert(input.set_enabled(false)); // 停用优先于迟到的焦点恢复。
    XSetInputFocus(display, xid, RevertToParent, CurrentTime);
    XSync(display, False); pump();
    assert(grab() == GrabSuccess);
    XUngrabKeyboard(display, CurrentTime); XSync(display, False); pump();
    XSetInputFocus(display, DefaultRootWindow(display), RevertToParent, CurrentTime);
    XSync(display, False); pump();
    assert(input.set_enabled(true)); // Dart resume 早于 GTK 激活，接受等待。
    assert(grab() == GrabSuccess); // 后台不能提前抓取。
    XUngrabKeyboard(display, CurrentTime);
    XSetInputFocus(display, xid, RevertToParent, CurrentTime);
    XSync(display, False); pump();
    assert(grab() == AlreadyGrabbed);
    gtk_widget_hide(window); pump();
    assert(!input.set_enabled(true));
    gtk_widget_show_all(window); pump();
    XSetInputFocus(display, xid, RevertToParent, CurrentTime);
    XSync(display, False); pump();
    assert(input.set_enabled(true));
  }
  assert(grab() == GrabSuccess); // 析构释放。
  XUngrabKeyboard(display, CurrentTime); XSync(display, False); pump();
  {
    LinuxImmersiveInput input(view);
    assert(input.set_enabled(true));
    gtk_widget_destroy(window); pump();
    assert(!input.set_enabled(true));
    assert(input.set_enabled(false));
  }
  XCloseDisplay(display);
}
