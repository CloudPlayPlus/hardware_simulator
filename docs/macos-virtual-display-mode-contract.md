# macOS 虚拟显示器 mode 更新合同

## 背景

macOS Direct 版本通过独立 helper 持有私有 `CGVirtualDisplay` 对象。分辨率目录与当前
生效 mode 是两个不同概念：

- 分辨率目录由 Flutter / `hardware_simulator` 保存，用于 UI 展示和输入校验；
- helper 每次只向 `CGVirtualDisplaySettings` 提交当前目标 mode。

不要把整个分辨率目录同时提交给 WindowServer。macOS 26 会为这种 rich mode list
生成不可程序化切换的 HiDPI mode，`CGDisplaySetDisplayMode` 可能返回
`kCGErrorIllegalArgument`，并且系统保存的历史 mode 可能覆盖本次请求。

## Helper 命令合同

helper 启动后：

1. stdout 第一行返回十进制 `CGDirectDisplayID`；
2. stdin 接受一行一个命令：`SET <width> <height> <refreshRate>`；
3. 成功后 stdout 返回 `OK <原 displayID>`；
4. backing pixel 已更新、但 HiDPI mode 尚未选中时返回 `BACKING <原 displayID>`；
5. 参数非法、`applySettings` 失败或最终 backing pixel 尺寸不一致时返回 `ERR`。

同一时刻只允许一个未完成命令。父进程必须在
`macVirtualDisplayQueue` 上串行写命令和读回复。

## Mode 与回退

- 创建和更新都只提交单个目标 mode。宽高均为偶数时设置 `hiDPI = 1`，并以请求尺寸
  的一半作为逻辑 mode，使 backing pixel 尺寸等于请求值；例如请求 2448×1848 时，
  macOS 使用 1224×924 @2×。这样既保持串流分辨率，又避免 1× 下字体过小。
- descriptor 的最大像素尺寸等于首次请求尺寸，物理尺寸按 220 PPI 计算。低 DPI 的
  固定物理尺寸会让 macOS 26 默认选择 1× mode；按 Retina 密度声明后无需强制切换。
- 每次新建使用新的 product ID，隔离 WindowServer 按 vendor+product 保存的历史 mode
  偏好；Display ID 仍由同一个 helper 持有，分辨率原地更新不会改变 product ID。
- 奇数尺寸无法精确表达为 2× mode，回退到 `hiDPI = 0` 的 1× mode。
- helper 通过 `applySettings` 原地更新 backing pixel 尺寸，并尝试选择“逻辑尺寸减半、
  backing pixel 等于请求尺寸”的 HiDPI mode；主 App 进程会再次核验和补选。不再调用
  `preferNativeScale` 强制切换 1×。
- macOS 26 上 `CGDisplaySetDisplayMode` 可能返回 `kCGErrorIllegalArgument`，但 WindowServer
  随后仍异步完成 mode 切换，因此主进程检查返回值但以限时轮询到的最终 mode 为准。
- 如果 backing pixel 已原地更新、但 HiDPI mode 暂未选中，helper 先保留原 display ID 并
  返回 `BACKING`，主进程再补选并核验；只有最终仍无法得到精确 2× mode 时才重建。
- 只要目标未超过首次创建的 descriptor 上限，插件先对同一个 `CGVirtualDisplay` 调用
  `applySettings`，实测 2448×1848、1920×1080、1600×1200 可保持同一 display ID。
- 若目标超过 descriptor 上限，或原地更新后无法核验精确 2× mode，插件才终止旧
  helper 并按目标尺寸重建。
  上层必须按最终枚举到的虚拟屏尺寸重新解析 display ID，不能假设旧 ID 仍有效。
- 活跃串流不支持热切 capture source；本合同只保证虚拟显示器管理和串流准备阶段的
  mode 更新。
