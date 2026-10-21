# hardware_simulator

This plugin simulates mouse & keyboard input. Currently it is not well documented. 

Current it supports to simulate: mouse & keyboard for Windows/macOS/Linux (Linux mouse uses uinput via inputtino; Linux keyboard still requires X11 + XTest). XBOX Game Controller for windows. See the example for details.

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
