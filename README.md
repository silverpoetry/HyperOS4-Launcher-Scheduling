# HyperOS 4 Launcher Scheduling

[![CI](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/actions/workflows/ci.yml/badge.svg)](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/silverpoetry/HyperOS4-Launcher-Scheduling?display_name=tag)](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/releases)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

这是一个 HyperOS 4 KernelSU 调度模块。Launcher 参与桌面、最近任务或应用转场时，模块把来源应用限制到设备定义的 background CPU 集，分配 Launcher 的关键线程，并在转场期把 SystemUI 渲染线程与 ART 维护线程分流，减少同一性能核心上的 runnable 竞争。

Launcher 指 `com.miui.home`，包括桌面主屏、最近任务和 Quickstep 转场。应用仍是 ActivityManager 记录的 resumed Activity 时，Launcher 可能已经接管应用窗口并绘制桌面或卡片，因此不能只根据前台 Activity 判断策略时机。

模块不替换框架或桌面 APK，不写死 CPU 编号，不读取 blur 半径，也不轮询前台应用。来源应用被限制到小核簇后，可选策略能在 Launcher 转场期间按比例降低该簇的 `scaling_max_freq`；该策略默认关闭，动画提交、取消、超时、服务重载和卸载都会按记录恢复原值。

## 管理界面

KernelSU 管理器可直接打开模块 WebUI。界面按 Material 3 的标题卡片、信息卡片和底部导航组织为状态、设置和诊断三页，支持跟手横向滑动切换，并适配系统动态配色、深色模式与安全区。

- 状态页每五秒读取一次模块已有的轻量状态文件，仅在页面可见时刷新；慢请求尚未结束时不会叠加下一轮读取；
- 日志页只在打开或手动刷新时读取 Launcher 关键线程与最近事件；
- 设置页可分别控制来源应用、壁纸/MIMD、Launcher、SystemUI 和小核限频，并独立调整 Raster、UI/Rust、ResMgr、FenceWait、SystemUI 渲染链及 ART 维护线程的核心集合；
- 所有写操作都映射到 `webui.sh configure` 的固定命名参数；前端和后端分别校验键、枚举及数值范围，不提供任意 Shell 执行入口；
- 配置仅在内容发生变化时显示保存操作，保存后一次性重载服务，页面轮询不会覆盖尚未保存的表单。

关闭 WebUI 后不会留下额外采样器或日志进程。界面控制的是现有模块策略，不会停用 KernelSU 模块，也不会修改系统调度器配置。用户设置保存在 `/data/adb/hyperos4-launcher-scheduling`，与 KernelSU 会替换的模块程序目录分离，升级时会保留；卸载模块时一并清除。

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
上一前台应用          → per-TID background affinity + cpuset/background + cpuctl/background
com.miui.miwallpaper → cpuset/background + cpuctl/background
MIMD（存在时）       → cpuset/background + cpuctl/background
小核 cpufreq policy   → 可选地临时限制 scaling_max_freq，默认关闭
```

模块不移动当前输入法、SurfaceFlinger 或 Display HAL。稳定应用态下，壁纸和 MIMD 恢复原始 cgroup，SystemUI 受管线程恢复逐 TID 原始亲和。

来源应用不能只写 cgroup。Xiaomi `metis` 会根据 `minor_window_app` 静默扩展指定 UID 的 affinity。模块仅在该节点等于当前来源 UID 时按 Joyose 的结束语义写入 `0`，保存每个 TID 的原始 affinity，再使用 `/dev/cpuset/background/cpus` 作为真实约束。动画结束或取消后按 TID 启动时间恢复；详细链路见 [来源应用退避根因](docs/SOURCE-APP-YIELD-ROOT-CAUSE.md)。

Launcher 自身采用逐线程策略：

```text
1.raster                         → prime
1.ui / rt-launcher-mai          → 去掉 prime 的 performance 集合
IplrVkResMgr                    → 去掉 prime 的 performance 集合
IplrVkFenceWait                 → 去掉 prime 的 performance 集合
```

转场事件到来后只进行短时 uclamp 提升：

```text
1.raster                → uclamp minimum 928
1.ui / rt-launcher-mai → uclamp minimum 768/512
IplrVkResMgr           → uclamp minimum 384
IplrVkFenceWait        → 不提升 uclamp
```

提升持续时间默认 1 ms，之后只恢复 0/1024 uclamp；基础 affinity 覆盖 Launcher 线程的整个运行期。所有放置策略和四类 `uclamp.min` 均可在 WebUI 调整。CPU 集合来自设备当前 cpuset 和 `cpu_capacity`，不包含设备固定编号。模块不改变 SurfaceFlinger affinity。

SystemUI 只在 Launcher 转场期间分流：主线程、RenderThread、WMShell 与 GPU completion 默认使用非 prime 性能集合，HeapTaskDaemon、Finalizer、ReferenceQueue 与 JIT 默认使用 `secondary`。转场完成或超时后由原生控制器按 TID 启动时间恢复原亲和，SystemUI 重启也不会把旧 TID 状态应用到新进程。

小核限频默认关闭。手动开启后，只选择 CPU 集合完全落在动态 `little` mask 内的 cpufreq policy，默认取硬件上限的 78%，并向下选择驱动公开的最近可用频点。当前上限已经低于目标值时不再继续下压，因此重复事件和第三方调度不会叠乘比例。恢复时仅当当前上限仍等于模块写入值才回写原值，避免覆盖用户调度器在动画期间做出的新设置；默认 1500 ms 的独立超时用于兜底丢失的结束事件。

Settings 轻载场景按“关闭、开启、开启、关闭”完成两组交叉 A/B。限频后 Launcher Full jank 合计从 4 增至 8，SurfaceFlinger Full jank 从 11 增至 24，Launcher 最大帧均值从 26.08 ms 增至 37.46 ms。轻载来源应用没有足够的性能核争用可供限频缓解，压低其收尾、Buffer 交接和快照工作只会增加等待；完整数据见 [轻载小核限频 A/B](docs/FREQUENCY-LIMIT-LIGHT-LOAD-AB.md)。

Sheng 在 policy0 固定 307200 kHz 的五轮 A/B 中，FenceWait 从 CPU0-2 移到 CPU3-6 后，线程运行时间下降 83.0%，runnable 等待下降 64.0%，Launcher Full jank 从 30 降到 14。由于它在 Vulkan fence 链上承担实际工作，默认不再与被限频的来源应用共享小核；完整数据见 [FenceWait 与小核限频 A/B](docs/FENCEWAIT-FREQUENCY-AB.md)。

当前 8 Gen 3 调度配置实测推导为 `perf=fc (CPU2-7)`、`render=9c (CPU2-4,7)`、`secondary=60 (CPU5-6)`、`little=03 (CPU0-1)`。不同设备与第三方调度改变 cpuset 时会按同一规则重新计算。

## 事件监听

`module-src/bin/launcher-logwatch` 是一个从 `native/launcher_logwatch.c` 构建的 arm64 小程序。它通过系统 `liblog` 直接读取 logd main buffer，仅输出状态机使用的 Launcher 生命周期消息。

采用原生监听器是因为文本 `logcat` 接到 shell 管道后在实机上出现约 0.4 秒块缓冲；反复以单事件模式启动 logcat 又会漏掉紧邻的 resumed 和动画完成事件。原生监听器只有一个连续读取进程，用 `write()` 逐条交给状态机，不注入 Launcher，也不修改系统日志配置。

`module-src/bin/launcher-threadctl` 从 `native/launcher_threadctl.c` 构建。它在一个进程内枚举目标 TID，并直接批量设置 affinity/uclamp。旧 shell 实现一次动画需要启动约二十个工具进程，实测约 0.8 秒；原生批处理 apply/reset 各约 10 ms。

`module-src/bin/source-affinityctl` 从 `native/source_affinityctl.c` 构建。它维护来源应用的短生命周期 affinity 事务，处理 Xiaomi UID 标记、新增 TID、不同目标切换和精确恢复。Sheng 上 74 个 Settings 线程的初次事务耗时 2.812 ms；无变化重复事件约 1.017 ms。监听器通过 Android `posix_spawn()` 启动控制器；71 线程游戏现场的完整原生入口事务为 16.877 ms。原生入口已经完整成功时，shell 状态机不再重复扫描和绑定来源应用线程；只有原生事务缺失或部分失败才进入修复路径。

`module-src/bin/systemui-threadctl` 从 `native/systemui_threadctl.c` 构建。它只枚举两类明确命名的 SystemUI 线程，原子记录亲和快照、应用转场放置并在结束时恢复，不轮询进程或帧状态。

## Xiaomi 标记回写与 ActivityManager

ActivityManager 可以在转场期间把应用从 background 移到 foreground，但已经生效的显式 affinity 会保留。模块不再以 120/320 ms 定时任务反复抢写 cgroup。

Joyose 在应用恢复时可能重新写入 `minor_window_app`。重复的 Launcher 生命周期事件会检查该节点、新 TID 和实际 affinity；仅在发现变化时执行事件驱动 reassert，没有 20 ms 轮询。

## source 与目标应用

`source-app` 保存进入 Launcher 前的应用，`pending-source-app` 保存离开 Launcher 时刚恢复的目标。pending PID 始终受保护，不会被策略当作 source 退避。

目标应用收到 resumed 事件后，affinity 事务转移到目标，并保持到 Launcher 的卡片展开动画完成。`openingRemoteAnimationClose` 到来后，目标恢复原始 affinity 与 `top-app` cpuset/cpuctl；完成事件缺失时使用两秒安全兜底。进入稳定 `app` 后，pending 才提交为下一轮 source。

同一应用返回时复用原事务并吸收新 TID；打开不同应用时先恢复旧来源线程但不恢复旧来源的 Xiaomi UID 标记，再为目标创建事务，避免把后台游戏错误标回特殊场景。稳定 `app` 提交的最后一步再次落实恢复，避免快速连续操作把应用留在 background affinity。

## 安装

系统要求：

- ARM64 Xiaomi HyperOS 4；
- KernelSU，以及可用的模块挂载实现；
- 能够在异常时通过 KernelSU 安全模式停用模块。

从 [Releases](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/releases) 下载模块 ZIP
和同名 `.sha256` 文件。校验完成后，在 KernelSU 管理器中安装 ZIP 并重启设备。首次进入系统后打开
模块 WebUI，状态页应显示守护进程在线，并列出当前设备推导出的 CPU 集合。

升级会保留 `/data/adb/hyperos4-launcher-scheduling` 中的设置。卸载模块后重启，安装脚本创建的配置、
线程快照和临时频率状态会一并清理。

## 构建

要求 Windows PowerShell、Android SDK 和包含 arm64 clang 的 NDK。构建脚本依次读取 `-AndroidSdk`、
`ANDROID_SDK_ROOT`、`ANDROID_HOME` 和当前用户的 Android SDK 默认目录。

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& .\build-module.ps1 -AndroidSdk 'C:\Android\Sdk'
```

输出：

```text
../output/HyperOS4-Launcher-Scheduling-v5.5.zip
../output/HyperOS4-Launcher-Scheduling-v5.5.zip.sha256
```

模块 ID 为 `hyperos4_recents_source_app_yield`，升级时原位覆盖现有版本。

## 验证

生命周期状态机已在 Sheng HyperOS 4 实机完成：

- 快滑回桌面；
- 慢滑进入最近任务；
- 上滑后取消；
- 从桌面打开应用；
- 从最近任务打开同一应用；
- source、目标、壁纸、MIMD 和 Launcher 的实际 cpuset/cpuctl 与 `Cpus_allowed_list` 检查；
- 单守护、单原生监听器检查。
- 文件管理连续快速返回、取消、回桌面和重新打开组合；稳定 `app` 状态保持 `top-app`/CPU `0-7`。

逐线程策略已在 Shennong HyperOS 4 实机完成隔离 A/B：

- 快滑回桌面、慢滑进入最近任务、上滑半程取消；
- 从桌面打开应用、从最近任务打开应用；
- 目标线程按 CPU 的 `task-clock`；
- 轻量 SurfaceFlinger FrameTimeline；
- 禁用后的亲和/uclamp 恢复和重新启用。

验证结果见 [docs/VALIDATION.md](docs/VALIDATION.md)、[5.1 轻载对照](docs/PRIME-RASTER-EARLY-YIELD-LIGHT-LOAD-AB.md)、[来源应用 affinity 性能 A/B](docs/SOURCE-AFFINITY-PERFORMANCE-AB.md)、[Sheng 高负载 A/B](docs/SHENG-HIGH-LOAD-VALIDATION.md)、[Sheng 生命周期报告](test-results/sheng-20260822-v2.8/REPORT.md)、[Sheng 快速操作恢复竞态](test-results/sheng-source-return-v3.2/REPORT.md) 和 [Shennong 逐线程 A/B 报告](test-results/shennong-thread-policy-v3.0/REPORT.md)。

## 项目结构

```text
module-src/       KernelSU 模块入口、WebUI 和构建后的 arm64 工具
module-src/lib/   配置、拓扑、线程、进程、频率、状态机与 WebUI 后端
module-src/webroot/css/  Material 3 设计令牌、布局、卡片、控件与诊断样式
module-src/webroot/js/   KernelSU 桥接、数据模型、导航及三个页面控制器
native/           四个原生监听与线程控制工具的 C 源码
../output/        构建生成的 ZIP 与 SHA-256
docs/             状态机和验证文档
tools/            原生构建与短时验证脚本
test-results/     A/B 数据与实机报告
CHANGELOG.md      版本变更记录
VERSION           当前版本
```

运行时分层、依赖方向和状态不变量见 [架构说明](docs/ARCHITECTURE.md)。

## 许可证

项目以 [Apache License 2.0](LICENSE) 发布。
