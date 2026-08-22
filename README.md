# Sheng 最近任务源应用让路模块

这是一个面向小米平板 6S Pro（`sheng`）的 KernelSU 模块。在进入最近任务界面时，它临时降低源应用、壁纸和 MIMD 的 CPU 调度优先级，减少这些进程与桌面、SystemUI 和显示合成链争抢性能核的情况。

模块不替换系统文件，不修改桌面 APK，不调整桌面线程绑核，不锁定 CPU/GPU 频率，也不关闭模糊、玻璃材质或 Vulkan。

## 工作流程

模块包含两个低权限范围的日志监听器和一个 cgroup 调整脚本。

1. 监听 Android EventLog 的 `wm_on_resume_called`，记录最后一个真正恢复到前台的应用 PID。
2. 监听 `com.miui.home` 的最近任务日志，优先以 `onOverviewToggle` 作为进入信号。
3. 如果没有出现 `onOverviewToggle`，以 `PassBlurWindow: on_create` 作为后备进入信号。
4. 进入时将源应用写入 `cpuset/background` 和 `cpuctl/background`。
5. 同时将 `com.miui.miwallpaper` 和 `vendor.xiaomi.hardware.mimd@2.0-service` 临时移入后台组。
6. 一秒后恢复壁纸和 MIMD。源应用保持后台状态，直到 ActivityManager 在用户重新打开它时自然提升。
7. `exitOverviewState` 用于清除本次进入状态并处理提前退出。

模块通过 generation 编号隔离连续动画的延迟恢复任务，避免快速反复进入和退出最近任务时发生旧任务覆盖新状态的问题。

## 调整范围

进入最近任务时：

```text
源应用：cpuset/background + cpuctl/background
壁纸：  cpuset/background + cpuctl/background
MIMD：  cpuset/background + cpuctl/background
```

一秒后：

```text
壁纸：cpuset/foreground + cpuctl/foreground
MIMD：cpuset/system-background + cpuctl 根组
```

桌面、SystemUI、当前输入法、SurfaceFlinger 和显示 HAL 不会被移动。

## 日志监听开销

监听进程会常驻，但没有日志时阻塞休眠。桌面产生符合 PID 和 tag 条件的日志时，`logcat` 会醒来执行正则匹配；Shell 只会收到匹配成功的少数日志。

最后一轮约 11 秒的 Perfetto 记录中：

```text
桌面 main 日志监听：1351.0 ms CPU，性能核 0 ms
Activity EventLog 监听：16.9 ms CPU，性能核 0 ms
```

因此该实现适合作为已验证的调度方案，但主日志监听在桌面操作密集时有可测量的小核开销。屏幕关闭或桌面没有产生日志时，监听器接近休眠状态。

## 测试结果

使用图库、文件管理、设置和日历组成四张最近任务卡片，连续记录三次进入动画：

```text
源应用性能核残留：约 1–2.7 ms
MIMD 性能核占用：约 570 ms 降至 39 ms
模块 cgroup 操作脚本：每次约 3.6–4.1 ms，性能核 0 ms
Launcher Full/Partial jank：0
Display Full/Partial jank：0
```

上述“模块 cgroup 操作脚本”数据不包含常驻 `logcat` 的 CPU 时间；日志监听开销已单独列出。

## 目录结构

```text
module-src/       KernelSU 模块源码
dist/             构建后的 ZIP 和 SHA-256
build-module.ps1  Windows PowerShell 构建脚本
README.md         原理、限制和测试记录
```

## 构建

在 PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& .\build-module.ps1
```

输出文件：

```text
dist/Sheng-Recents-Source-App-Yield-v1.0.zip
dist/Sheng-Recents-Source-App-Yield-v1.0.zip.sha256
```

## 安装

1. 确认设备是 `sheng`，已经安装 KernelSU 和可用的模块挂载实现。
2. 在 KernelSU 管理器中选择构建后的 ZIP。
3. 安装完成后重启。

模块操作按钮可以在启用和停用之间切换。卸载脚本会停止守护进程，并恢复壁纸和 MIMD 的预期 cgroup。

## 正式包校验值

```text
SHA-256: 4CB4EDCAA9916A044FE553E90F9ACFF3D278E1C5AEE92CF4408ECC6C5CDF9F60
```
