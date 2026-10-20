# hardware_simulator

This plugin simulates mouse & keyboard input. Currently it is not well documented. 

Current it supports to simulate: mouse & keyboard for Windows/macOS/Linux (Linux mouse uses uinput via inputtino; Linux keyboard still requires X11 + XTest). XBOX Game Controller for windows. See the example for details.

Linux uinput permission setup:

```bash
./scripts/setup_linux_input_permissions.sh
```

Log out and back in after adding your user to the `input` group.

Any pull request is welcome. It is designed for https://github.com/zhuhaichao518/cloudplayplus_stone.

## macOS 输入源本机集成验收

以下验收完全在**本机**运行：不会连接远端设备、不会创建 DataChannel，也不会请求或持久化任何 TCC 授权。
它补足单元测试无法证明的两件事：真实输入法是否把插件注入的按键提交为中文，以及退出串流后用户的
`UserKeyMapping` 是否精确恢复。

前置条件：测试机已启用“简体拼音”，并且与正式 macOS 客户端相同的 Apple Development 签名身份已经拥有
“Post Event”权限。脚本只检查 `CGPreflightPostEventAccess()`；没有权限时以 `77` 跳过，绝不弹授权窗。

```bash
# 在 hardware_simulator 仓库根目录执行；默认只运行真实 IME 提交测试。
./scripts/run_macos_input_source_integration.sh --ime

# 用独立的前台 AppKit 进程承载 NSTextView，收集跨进程 IME 行为诊断。
./scripts/run_macos_input_source_integration.sh --cross-process-ime

# 此项会暂时写入真实 Caps Lock -> F20 映射，随后经正常 stream-stop 路径恢复。
./scripts/run_macos_input_source_integration.sh --keyboard-restoration

# 在专用测试 Mac 上执行同进程文本与键位恢复验收。
./scripts/run_macos_input_source_integration.sh --all
```

`--ime` 构建同一份 Debug 插件 framework，使用 Apple Development 签名生成临时 AppKit `.app`，在真实
`NSTextView` 中通过插件的“direct TIS 选择 + CGEvent 键盘注入”路径断言 `nihao<Space>` 最终提交
`你好`；随后切回 ABC，经真实 Caps→A→Caps→B 注入断言结果为 `Ab`。它不是菜单栏图标或 flags 断言。

`--cross-process-ime` 额外启动两个带 Apple Development 签名的 AppKit App：目标 App 只持有前台
`NSTextView`，注入 App 才加载当前插件、执行生产的输入源 action 并发送同一组 CGEvent。它是一个诊断
对照：若目标没有收到 `你好`，会报告“输入法菜单已切换、目标未进入 composition context”的差异。它不含
DataChannel、Viewer capture 或真实远控 session，不能替代 macOS-to-macOS 的实际串流验收，也不定义该功能的
通过条件。

`--keyboard-restoration` 运行签名的独立 AppKit harness：读取原始映射、arm Caps Lock 映射、调用正常的
stop 路径，再同时由插件和 `hidutil` 读回验证原始状态。此项不进入常规 CI；它会修改用户级键位，必须在
可接受该短暂变更的本机或专用测试 Mac 上运行。若用户已自定义 Caps Lock 映射，测试以 `77` 跳过且不改动它。

运行脚本会按当前 checkout 解析 example 的 Flutter 依赖；若本机工具链更新了不属于本改动的
`example/pubspec.lock`，提交前应只恢复该生成文件的无关漂移。

## Windows 输入管道测试

macOS 原生输入接管由 `MacOSInputCaptureRegistry` 按 ID 注册/替换/注销 tap，处理器同步返回消费或放行。
它不持有会话状态或协议；调用方继续负责 focus/权限。Fn/Control+Space 与 Globe 事件配对逻辑见
`MacOSInputSourceChordRouter.swift`；Caps 使用带 owner lease/journal 的可逆 F20 映射。
固定 App/窗口生命周期节点检查残留映射，不新增定时扫描；旧 Fn 全局设置仅保留恢复路径。

最小回归：

```sh
xcrun swiftc macos/Classes/MacOSInputSourceChordRouter.swift test/macos/input_source_chord_harness.swift -o /tmp/input-source-chords
/tmp/input-source-chords
```

`input_capture_registry_harness.swift` 是需要辅助功能权限的本机 tap 回归，向自身发送无文本事件，
不进入常规 CI。`input_source_safety_harness.swift` 以 mock 映射验证生产恢复函数，不改真实键位。
保留现有 MethodChannel、映射 journal/权限测试；探索性 sample、失败无映射实验不进入产品代码。

无需 Flutter 或 SYSTEM 权限，不会注入真实键鼠事件：

```powershell
cmake -S windows/test -B build-input -A x64
cmake --build build-input --config Release
ctest --test-dir build-input -C Release --output-on-failure --timeout 30
```

服务输入由专用发送线程按序写入，调用成功表示已入队。键鼠、触摸和笔的
原始事件全部逐条保留，不合并、不累加、不节流。配置请求使用独立的短期
连接。管道故障会丢弃未发送队列并后台重连，不重放送达结果不确定的输入。
