# Design Spec: Windows Headless VDD 显示器保活

> v9 | 2026-07-15 | issue #29, PR #30 | 完整调研见 [review 页](http://192.168.100.202:52000/hardware_simulator/ensure-console-session-kickoff.html)

## 问题

Headless 下当前会话无 display 时 streaming 用不了。根因：VDD 绑定 console 会话，目标会话不在 console 上时 VDD 不可见。

## 方案

现有 `Initialize()` / `AddDisplay()` 主流程**不动**。新增 `EnsureConsoleForDisplay()`，在 Initialize / streaming 前调用：

```cpp
bool EnsureConsoleForDisplay() {
    if (HasActiveDisplay()) return true;               // 有屏就啥都不做
    DWORD target = FindTargetSession();                // WTSEnumerate, sid>0, 有用户，优先 Disconnected
    if (target == 0) return false;                     // 无交互用户
    if (WTSGetActiveConsoleSessionId() == target) return true; // 已在 console，缺屏交 AddDisplay
    if (HasActiveRdpSession()) return false;           // 不切 RDP，退让
    return RunTscon(target);                           // tscon <target> /dest:console
}
```

**Why**: VDD 绑 console (E7/E8)；tscon 会顶断活跃 RDP 所以要门禁；Phase 1 在 session 1 GUI 跑，EnumDD 可信，不需要 helper。详见 review 页。

## 验收标准

1. 已有 active display → 跳过，零动作。
2. 目标已在 console → 跳过 tscon（缺屏由 AddDisplay 处理）。
3. 有活跃 RDP → 跳过 tscon，不顶断 RDP。
4. RDP 断连后：无屏 + 目标非 console + 无 RDP → tscon → VDD 可见 → AddDisplay OK。
5. 日志：target session / console id / RDP check / tscon 结果。

## 显示器就绪保证（为什么不加 post-tscon 轮询）

`EnsureConsoleForDisplay` 做完 tscon 就返回，**不**回头轮询显示器是否已枚举 —— 刻意如此，别再加：

- `tscon.exe` 退出 ≠ 显示器立刻可枚举（切到 console 后显示子系统重初始化有滞后）。
- 但**就绪已被下游两层兜住**：① `AddDisplay()` 加完 VDD 后重试 `GetAllDisplays()` **5×500ms 直到 VDD 枚举出现**，而 VDD 能枚举的前提就是切换已生效 —— 即此重试隐含等掉了 tscon 滞后；② dart `prepare()` 的 `_changeDisplaySettingsWithRetry()` 配不上就 `throw`，串流 gate 在"显示器可配置"上。
- 所以串流不会在没切好时开始。在 `EnsureConsoleForDisplay` 里再塞轮询是**重复**（等的是同一件事），且它跑在 addDisplay **之前**、VDD 还没加时会空等超时。
- 唯一隐患：`AddDisplay` 5 次没枚举到也只打 Warning 就返回成功。要加固就加固**这里**（没枚举到→失败/让 dart 重试），而不是 tscon 后加轮询。

## 线程与并发约束

`VirtualDisplayControl` 的 `initialized_` / `vdd_handle_` / `displays_` 是 **static 共享可变状态、无任何锁**；无 race 全靠 **method-channel handler 在 Flutter 平台线程串行执行**。据此：

- `initParsecVdd`(→`Initialize`) / `createDisplay`(→`AddDisplay`) **必须留在平台线程**，改 `displays_`，挪 worker 线程会与并发的 `removeDisplay`/`changeDisplaySettings`/`getDetailedDisplayList` race → 崩溃/损坏。**已加注释禁止再挪。**
- `ensureConsoleForDisplay` 只碰 WTS/tscon、**不碰任何共享 VDD 状态**，可安全放 worker 线程 → 避免 tscon `WaitForSingleObject(~10s)` 冻结平台线程。
- **非阻塞 known-limitation**：tscon 最长 ~10s、`AddDisplay` 枚举重试 ~2s 仍在平台线程。要让 init/add 也安全非阻塞，正解是**单一串行 VDD worker 队列**（所有 VDD 操作排到一条后台线程串行执行 + event channel 回吐结果），而不是给各 handler 各开线程。列为后续独立改动。

## tscon 并发

`WTSConnectSession`（tscon 底层）官方文档**未定义并发/线程安全**；console 一次只挂一个 session。并发 tscon 只可能出现在"多 viewer 几乎同时发起 `acceptAndStartSharing`、都还没 await 完 ensureConsole"这一边缘场景，且 `FindTargetSession` 拿到**同一会话**、都往 console 切 → 冗余。最坏是 setup 阶段显示器抖一下（**不影响运行中的流**，只可能让这几个并发首连变 flaky）。

若 `ensureConsoleForDisplay` 保持 async，应加**串行门禁**（`std::mutex` + 拿锁后重查 `HasActiveDisplay`，非 skip-if-busy），保证同一时刻只跑一个 tscon，且"返回=console 就绪"契约不破。

## 关联修复（本 PR 独立 commit）

物理屏 uid `+1024` 偏移：QXL 的 target id 为 UID0，与 VDD 硬件索引 0 相撞；自定义分辨率经 `ChangeDisplaySettings` 的 `find_if(GetDisplayUid()==uid)` 会命中错屏 → `BADMODE`。物理屏 uid +1024 规避 VDD 索引空间（0..15）。不保证两块物理屏之间唯一，后续用 devicePath 生成唯一 id。
