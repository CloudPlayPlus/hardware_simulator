# hardware_simulator

This plugin simulates mouse & keyboard input. Currently it is not well documented. 

Current it supports to simulate: mouse & keyboard for Windows/macOS/Linux (Linux mouse and keyboard use uinput; monitor geometry still uses X11/XWayland). XBOX Game Controller for windows. See the example for details.

Linux uinput permission setup:

```bash
./scripts/setup_linux_input_permissions.sh
```

Log out and back in after adding your user to the `input` group.

Any pull request is welcome. It is designed for https://github.com/zhuhaichao518/cloudplayplus_stone.

## macOS 输入源回归

仅保留 `input_source_chord_harness.swift`（Fn/Control+Space和事件配对）与
`input_source_safety_harness.swift`（mock映射的启动失败/所有权/恢复）。MethodChannel保留必要接口回归。
真实跨进程输入、签名测试App及其启动脚本属于本地调研工具，不随插件维护或交付。
原生接管由 `MacOSInputCaptureRegistry` 按ID注册/替换/注销，handler同步决定消费/放行。
无新增周期检查或进程外助手；正常运行不记录逐键或逐次切源日志，仅保留状态与失败诊断。

## Windows 输入管道测试

无需 Flutter 或 SYSTEM 权限，不会注入真实键鼠事件：

```powershell
cmake -S windows/test -B build-input -A x64
cmake --build build-input --config Release
ctest --test-dir build-input -C Release --output-on-failure --timeout 30
```

服务输入由专用发送线程按序写入，调用成功表示已入队。键鼠、触摸和笔的
原始事件全部逐条保留，不合并、不累加、不节流。配置请求使用独立的短期
连接。管道故障会丢弃未发送队列并后台重连，不重放送达结果不确定的输入。

## Linux 输入回归

在 CloudPlayPlus 主仓已完成 Linux 构建配置后运行：

```bash
cmake -S linux -B build/linux/x64/release -DHARDWARE_SIMULATOR_INPUT_TESTS=ON
cmake --build build/linux/x64/release --target linux_input_test
./build/linux/x64/release/plugins/hardware_simulator/linux_input_test
```

测试拦截 libevdev 的设备创建与写入，不会向桌面注入真实输入；覆盖键码映射、
重复按下、权限失败重试、释放失败重试，以及两轴滚轮余量与相对/绝对设备切换。
原生 Wayland/X11 应用中的实际输入仍需远控实机验收。

### Linux Viewer pointer capture

Build dependencies: `libxi-dev`, `libwayland-dev`, `wayland-protocols` (and
`wayland-scanner`). The runtime backend follows the GTK display, including X11
for an XWayland window. No evdev/root access is required for Viewer capture.

Use `linuxPointerCaptureEvents` and `setLinuxPointerCapture(enabled, generation)`.
Each lock request needs a unique generation. Only a matching `locked: true` event
confirms activation; `lockCursor` completing is not confirmation. Motion events
carry the same generation and floating-point `dx/dy`. Unlock cancels pending
requests too. Unsupported, unfocused, or busy displays fail explicitly; Wayland
requests that do not activate are released after five seconds. Focus loss,
unmap, destruction and compositor unlock release capture. Buttons/wheel continue
through GTK; consumers must suppress ordinary motion while capturing.

The native integration test requires an **isolated** display (it injects input):
configure with `HARDWARE_SIMULATOR_POINTER_TESTS=ON`, build
`linux_pointer_capture_test`, then run with `GDK_BACKEND=x11 DISPLAY=<Xvfb>` or
`GDK_BACKEND=wayland WAYLAND_DISPLAY=<nested-Weston> DISPLAY=<Weston's Xvfb>`.
The latter uses Weston's X11 backend with kiosk shell. It checks activation,
relative movement, buttons/wheel, generation isolation, release and unmap.
Nested Wayland uses alternating motion because the parent X11 backend clips at
its screen edge; this does not replace physical GNOME/KDE game testing.
