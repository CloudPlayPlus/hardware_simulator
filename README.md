# hardware_simulator

This plugin simulates mouse & keyboard input. Currently it is not well documented. 

Current it supports to simulate: mouse & keyboard for Windows/macOS/Linux (Linux mouse uses uinput via inputtino; Linux keyboard still requires X11 + XTest). XBOX Game Controller for windows. See the example for details.

Linux uinput permission setup:

```bash
./scripts/setup_linux_input_permissions.sh
```

Log out and back in after adding your user to the `input` group.

Any pull request is welcome. It is designed for https://github.com/zhuhaichao518/cloudplayplus_stone.

## Windows 输入管道测试

无需 Flutter 或 SYSTEM 权限，不会注入真实键鼠事件：

```powershell
cmake -S windows/test -B build-input -A x64
cmake --build build-input --config Release
ctest --test-dir build-input -C Release --output-on-failure --timeout 30
```

服务输入由专用发送线程按序写入，调用成功表示已入队。积压的相邻纯鼠标
移动会合并，按键、按钮、滚轮、触摸和笔保留顺序。配置请求使用独立的短期
连接。管道故障会丢弃未发送队列并后台重连，不重放送达结果不确定的输入。
