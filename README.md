# HyperOS 4 Launcher Scheduling

这是一个 HyperOS 4 KernelSU 调度模块。Launcher 参与桌面、最近任务或应用转场时，模块将上一前台应用、壁纸和可选的 Xiaomi MIMD 服务放入设备已有的 `background` cgroup，减少它们与 Launcher、SystemUI 和显示合成链争抢非后台核心。

Launcher 指 `com.miui.home`，包括桌面主屏、最近任务和 Quickstep 转场。应用仍是 ActivityManager 记录的 resumed Activity 时，Launcher 可能已经接管应用窗口并绘制桌面或卡片，因此不能只根据前台 Activity 判断策略时机。

模块不替换框架或桌面 APK，不写死 CPU 编号，不锁 CPU/GPU 频率，不读取 blur 半径，也不轮询前台应用。

## 生命周期

```text
app
  → entering   Launcher 接管应用到桌面/最近任务的手势
  → home       桌面稳定显示
  → recents    最近任务稳定显示
  → leaving    Launcher 正在打开目标应用
  → app        Launcher 退出动画完成
```

策略在 `entering`、`home`、`recents` 和 `leaving` 中持续生效，只在稳定 `app` 状态解除。事件映射、手势会话和状态不变量见 [docs/STATE-MACHINE.md](docs/STATE-MACHINE.md)。

## 调度策略

Launcher 活跃期间：

```text
上一前台应用          → cpuset/background + cpuctl/background
com.miui.miwallpaper → cpuset/background + cpuctl/background
MIMD（存在时）       → cpuset/background + cpuctl/background
```

模块不会移动 Launcher、SystemUI、当前输入法、SurfaceFlinger 或 Display HAL。稳定应用态下，壁纸和 MIMD 恢复为模块首次记录的原始 cgroup。

Launcher 自身采用逐线程策略：

```text
1.ui / 1.raster / rt-launcher-mai → top-app 中不属于 background 的 CPU
IplrVkResMgr                      → 上述集合去掉最高 capacity 的 prime CPU
IplrVkFenceWait                  → 最低 cpu_capacity 的 CPU 簇
```

转场事件到来后，raster、UI、Rust 和 ResMgr 分别短时使用 768、640、512 和 384 的 uclamp minimum，一秒后恢复为 0/1024。CPU 集合来自设备当前 cpuset 和 `cpu_capacity`，不包含 Sheng 或 Shennong 的固定编号。

Shennong 实测推导为 `perf=9c (CPU2-4,7)`、`mid=1c (CPU2-4)`、`little=03 (CPU0-1)`。原来的 Sheng 布局会自然推导为与旧版 `f8/78/07` 相同的类别关系。

## 事件监听

`module-src/bin/launcher-logwatch` 是一个从 `native/launcher_logwatch.c` 构建的 arm64 小程序。它通过系统 `liblog` 直接读取 logd main buffer，仅输出状态机使用的 Launcher 生命周期消息。

采用原生监听器是因为文本 `logcat` 接到 shell 管道后在实机上出现约 0.4 秒块缓冲；反复以单事件模式启动 logcat 又会漏掉紧邻的 resumed 和动画完成事件。原生监听器只有一个连续读取进程，用 `write()` 逐条交给状态机，不注入 Launcher，也不修改系统日志配置。

`module-src/bin/launcher-threadctl` 从 `native/launcher_threadctl.c` 构建。它在一个进程内枚举目标 TID，并直接批量设置 affinity/uclamp。旧 shell 实现一次动画需要启动约二十个工具进程，实测约 0.8 秒；原生批处理 apply/reset 各约 10 ms。

## ActivityManager 二次提升

Shennong A/B 测试发现，第一次把 source 写入 background 后约 100–110 ms，ActivityManager 会再次提升它。模块在 120 ms 和 320 ms 进行两次受保护重写。重写必须同时匹配当前 policy epoch、当前 source 内容，并确认状态仍不是 `app`。

取消手势时先使 epoch 失效，再恢复 source，避免已经唤醒的旧任务在恢复后把前台应用重新送回 background。

## source 与目标应用

`source-app` 保存进入 Launcher 前的应用，`pending-source-app` 保存离开 Launcher 时刚恢复的目标。pending PID 始终受保护，不会被策略当作 source 退避。

如果用户重新打开的目标与 source 是同一 PID，模块会用进入 Launcher 前保存的 cgroup 快照主动恢复它。进入稳定 `app` 后，pending 才提交为下一轮 source。

## 构建

要求 Windows PowerShell、Android SDK 和包含 arm64 clang 的 NDK。构建脚本依次查找 `-AndroidSdk`、`ANDROID_SDK_ROOT`、`ANDROID_HOME`、`E:\Develop\Android\Sdk` 和本地默认 SDK 目录。

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& .\build-module.ps1
```

输出：

```text
../output/HyperOS4-Launcher-Scheduling-v3.0.zip
../output/HyperOS4-Launcher-Scheduling-v3.0.zip.sha256
```

安装需要 HyperOS 4、KernelSU 和可用的模块挂载实现。模块 ID 保持为 `hyperos4_recents_source_app_yield`，升级时会原位覆盖，不会并行启动另一份守护。

## 验证

生命周期状态机已在 Sheng HyperOS 4 实机完成：

- 快滑回桌面；
- 慢滑进入最近任务；
- 上滑后取消；
- 从桌面打开应用；
- 从最近任务打开同一应用；
- source、目标、壁纸、MIMD 和 Launcher 的实际 cpuset/cpuctl 检查；
- 单守护、单原生监听器检查。

逐线程策略已在 Shennong HyperOS 4 实机完成隔离 A/B：

- 快滑回桌面、慢滑进入最近任务、上滑半程取消；
- 从桌面打开应用、从最近任务打开应用；
- 目标线程按 CPU 的 `task-clock`；
- 轻量 SurfaceFlinger FrameTimeline；
- 禁用后的亲和/uclamp 恢复和重新启用。

验证结果见 [docs/VALIDATION.md](docs/VALIDATION.md)、[Sheng 生命周期报告](test-results/sheng-20260822-v2.8/REPORT.md) 和 [Shennong 逐线程 A/B 报告](test-results/shennong-thread-policy-v3.0/REPORT.md)。

## 项目结构

```text
module-src/       KernelSU 模块源码和构建后的 arm64 工具
native/           launcher-logwatch 与 launcher-threadctl C 源码
../output/        Magisk 项目集合共用的正式 ZIP 与 SHA-256
docs/             状态机和验证文档
tools/            原生构建与短时验证脚本
test-results/     A/B 数据与实机报告
CHANGELOG.md      版本变更记录
VERSION           当前版本
```
