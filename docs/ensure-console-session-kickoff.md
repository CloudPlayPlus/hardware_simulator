# Design Spec: Windows Headless VDD 显示器保活

> v8 | 2026-07-13 | issue #29, PR #30 | 完整调研见 [review 页](http://192.168.100.202:52000/hardware_simulator/ensure-console-session-kickoff.html)

## 问题

Headless 下当前会话无 display 时 streaming 用不了。根因：VDD 绑定 console 会话，目标会话不在 console 上时 VDD 不可见。

## 方案

现有 `Initialize()` / `AddDisplay()` 主流程**不动**。新增 `EnsureConsoleForDisplay()`，在 Initialize / streaming 前调用：

```cpp
void EnsureConsoleForDisplay() {
    if (HasActiveDisplay()) return;                    // 有屏就啥都不做
    DWORD target = FindTargetSession();                // WTSEnumerate, sid>0, 有用户
    if (target == 0) return;                           // 无交互用户
    if (WTSGetActiveConsoleSessionId() == target) return; // 已在 console，缺屏交 AddDisplay
    if (HasActiveRdpSession()) return;                 // 不切 RDP，退让
    RunTscon(target);                                  // tscon <target> /dest:console
}
```

**Why**: VDD 绑 console (E7/E8)；tscon 会顶断活跃 RDP 所以要门禁；Phase 1 在 session 1 GUI 跑，EnumDD 可信，不需要 helper。详见 review 页。

## 验收标准

1. 已有 active display → 跳过，零动作。
2. 目标已在 console → 跳过 tscon（缺屏由 AddDisplay 处理）。
3. 有活跃 RDP → 跳过 tscon，不顶断 RDP。
4. RDP 断连后：无屏 + 目标非 console + 无 RDP → tscon → VDD 可见 → AddDisplay OK。
5. 日志：target session / console id / RDP check / tscon 结果。
