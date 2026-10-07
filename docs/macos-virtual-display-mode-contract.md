# macOS 虚拟显示器 mode 更新合同

## 背景

macOS Direct 通过独立 helper 持有私有 `CGVirtualDisplay` 对象。请求宽高始终表示
实际 backing pixel 尺寸。分辨率目录由 Flutter / 插件保存；helper 每次只提交当前目标
mode，不把完整目录交给 WindowServer，避免历史偏好或合成 mode 覆盖本次请求。

## Helper 命令合同

1. stdout 首行返回十进制 display ID；它只表示对象已分配，尚未承诺尺寸正确。
2. stdin 接受 `SET <width> <height> <refreshRate>`；宽高与刷新率必须为正整数。
3. helper 依次尝试精确 HiDPI / 1×，最终 mode 核验成功才返回 `OK <原 displayID>`。
4. 参数非法、无法应用或最终尺寸仍不符时返回 `ERR`。不再返回需要父进程补选的 `BACKING`。
5. 主进程在 `macVirtualDisplayQueue` 上串行写命令、读回复；单次回复最多等待 8 秒。
   helper 每个缩放候选最多轮询 1 秒等枚举；切换调用及结果核验共享 2 秒预算。创建后的首次 SET 同样走此流程。

stdout 只用于命令协议；诊断不得混入协议。主进程在 `OK` 后再次核验实际像素尺寸。
创建核验失败时回收新 helper 并返回 -1，不能忽略 mode 选择失败而报告创建成功。

## Mode 与回退

- 宽高均为偶数时优先尝试逻辑尺寸减半的 2× mode；奇数尺寸直接尝试 1×。
- 枚举候选时必须检查 `CGDisplayModeIsUsableForDesktopGUI`。可枚举不代表可用于桌面。
  HiDPI 不可用或限时核验失败时，重新提交 `hiDPI = 0` 与原请求宽高，尝试精确 1×。
- macOS 26.5.1 / M2 Pro 实测 `1848×992` 的 `924×496 @2×` 不可用，回退
  `1848×992 @1×`；`1848×1048` 与 `1848×1050` 分别在逻辑高度 524 / 525
  处失败 / 成功。该阈值是本机证据，不硬编码；以系统可用性和最终 mode 为准。
- `CGDisplaySetDisplayMode` 返回错误也可能伴随异步切换，结果以限时核验为准。
  在提交 1× 回退前必须等待前一个切换调用返回；调用阻塞超过 2 秒则返回 ERR 并退出
  helper，不能让旧请求在回退成功后继续覆盖 mode。调用返回后再限时核验实际 mode。
- descriptor 上限等于首次请求尺寸，偶数尺寸按 220 PPI 声明；每次创建采用新的 product ID，
  隔离 WindowServer 的历史 mode 偏好。1× 回退不改变 descriptor 身份。
- 每次改分辨率重新优先尝试 HiDPI，不能因曾回退 1× 而永久锁定低密度。
- 优先通过同一个 helper 原地更新；失败时插件按目标尺寸重建，重建也须完整核验。
  上层按最终枚举到的尺寸解析 display ID，不能假设重建后旧 ID 仍有效。
- 活跃串流不支持热切采集源；本合同仅覆盖管理及串流准备阶段。

## 本机回归

使用当前源码构建的 Direct helper 执行：

```bash
macos/VirtualDisplayHelper/test_mode_updates.sh /path/to/cloudplayplus_vd_helper
```

覆盖正常 HiDPI、低高度 1× 回退、再次切回 HiDPI、首次创建低高度显示器、非法命令以及
同一 helper 下 display ID 保持不变。测试创建的显示器在退出时回收；需要本机图形会话。
