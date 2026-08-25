# HyperOS 4 Launcher Scheduling

[![CI](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/actions/workflows/ci.yml/badge.svg)](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/silverpoetry/HyperOS4-Launcher-Scheduling?display_name=tag)](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/releases)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

这是一个用于 HyperOS 4 的 KernelSU 调度模块。它在桌面、最近任务和应用开关动画中约束来源应用，并为 Launcher、SystemUI 和 system_server 的关键线程分配明确的 CPU 集合，减少同一性能核心上的 runnable 竞争。

模块不替换系统框架或桌面 APK，不写死设备 CPU 编号，不修改 SurfaceFlinger、显示 HAL 或渲染后端。所有核心集合都从当前在线 CPU、系统 cpuset 和 `cpu_capacity` 推导。

## 工作方式

Launcher 接管应用窗口时，ActivityManager 仍可能把原应用标为 resumed。目标应用恢复 resumed 后，最近任务卡片也可能仍在展开。因此模块使用 Launcher 的真实生命周期日志判断可见转场，不把 resumed Activity 当作动画边界。

一次逻辑转场包含以下步骤：

1. 原生协调器读取 Launcher 事件并创建单调转场 ID；
2. 来源应用进入专用 cpuset/cpuctl，线程 nice 调整到配置目标；
3. Launcher、SystemUI 和 system_server 的目标线程应用 affinity/uclamp；
4. 活动转场内按缓存 TID 复核亲和，系统覆盖后默认在 20 ms 内修正；
5. 协议完成后继续等待默认 450 ms 的视觉稳定时间；
6. 返回原卡片时在视觉稳定后恢复来源应用；打开另一张卡片时旧来源留在 background，目标应用始终保持系统分配的 top-app。

来源守卫只接受当前或更新的转场 ID。延迟日志、重复事件和上一轮完成定时器不能覆盖新事务。

详细设计见 [运行架构](docs/ARCHITECTURE.md) 和 [转场状态机](docs/STATE-MACHINE.md)。

## 默认策略

来源应用：

- 使用 Android 当前的系统后台 CPU 集合；
- 使用独立 cpuset 和 cpuctl，现有线程整体迁移，新线程自动继承；
- `cpu.shares` 根据压制等级设置；
- nice 压制默认 40，对应目标 `nice=19`；
- ActivityManager 改写 task profile 后由 `cgroup_attach_task` 事件定点纠正。

Launcher：

- Raster 默认使用 Prime 核；
- UI 和 Rust 默认使用非 Prime 性能核；
- ResMgr 和 FenceWait 默认使用非 Prime 性能核；
- uclamp 覆盖完整视觉转场，结束后恢复原值。

SystemUI：

- 主线程、RenderThread、`wmshell.main` 和 GPU 完成线程默认使用非 Prime 性能核；
- GC、终结器、JIT 和 Profile Saver 默认使用次级性能核。

system_server：

- `android.anim` 和 `android.display` 默认使用非 Prime 性能核；
- `TaskSnapshotPersister` 默认使用次级性能核；
- Binder 线程不统一固定，SurfaceFlinger 保持系统调度策略。

辅助策略：

- 转场期间可把 MIUI 壁纸和 MIMD 移入 background；
- 可选效率核限频默认关闭；
- 服务重载、关闭和卸载均按记录恢复。

## CPU 集合

所有可配置放置使用同一组枚举：

1. 性能核；
2. 非 Prime 性能核；
3. 渲染核；
4. Prime 核；
5. 效率核；
6. 次级性能核；
7. 系统后台核；
8. 效率核（预留一核）。

“效率核（预留一核）”从最低容量核心中保留最高编号的一颗给系统后台任务。效率核只有一颗时不缩减，避免空 cpuset。

## 管理界面

KernelSU 管理器可直接打开模块 WebUI。界面包括状态、设置和诊断三页。

- 状态页显示当前阶段、来源应用、守卫状态、动态 CPU 拓扑和各集群频率；
- 设置页控制来源、Launcher、SystemUI、system_server、辅助进程和限频策略；
- 所有放置项使用相同的八类 CPU 集合；
- 视觉稳定时间、亲和复核间隔、来源完成兜底和 uclamp 均可调整；
- 配置保存在 `/data/adb/hyperos4-launcher-scheduling`，升级时保留，卸载时清除；
- 前后端都校验固定参数，不提供任意 shell 执行入口。

## 运行进程

模块只有两个常驻原生进程：

- `launcher-logwatch`：读取 logd、合并转场事件、维护内存状态机并执行线程策略；
- `source-guard`：维护当前来源身份、专用控制组、nice 快照、覆盖纠正和定时恢复。

shell 服务只负责启动、配置重载和退出恢复。转场热路径不执行 `pidof`、`dumpsys`、`taskset`、`uclampset`，不创建 shell 定时器，也不逐事件写状态文件。

日志读取器只订阅 Launcher PID 的 main 记录。协调器主线程、计时线程和看门狗固定在效率核，日志读取线程固定在次级性能核，来源守卫固定在一颗次级性能核；这些约束只作用于模块自身。配置重载使用阻塞信号和统一退出路径，先停止事件提交，再恢复所有临时策略；重载发生在最近任务界面时会保留当前来源身份和场景。

## 安装

要求：

- ARM64 Xiaomi HyperOS 4；
- KernelSU 和可用的模块挂载实现；
- 异常时能够使用 KernelSU 安全模式停用模块。

从 [Releases](https://github.com/silverpoetry/HyperOS4-Launcher-Scheduling/releases) 下载 ZIP 和同名 `.sha256`，校验后在 KernelSU 管理器中安装并重启。

## 构建

要求 Windows PowerShell、Android SDK 和包含 arm64 clang 的 NDK。

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& .\build-module.ps1 -AndroidSdk 'C:\Android\Sdk'
```

构建脚本会：

1. 校验源码结构和配置不变量；
2. 从 `launcher_logwatch.c`、`transition_policy.c` 和 `proc_control.c` 构建协调器；
3. 从 `source_guard.c` 和共享的 `proc_control.c` 构建来源守卫；
4. 生成模块 ZIP 和 SHA-256 文件。

## 验证

仓库包含设备侧部署、手势回放和 Perfetto 分析脚本。发布前至少验证：

- 应用快速进入最近任务；
- 慢滑、半程取消和连续往返；
- 桌面或最近任务打开不同应用；
- 高负载来源应用的来源守卫身份、允许 CPU 和 nice；
- 转场结束后 Launcher uclamp、SystemUI/system_server 亲和与来源 top-app 恢复；
- 服务重载、模块关闭和卸载恢复。

历史 A/B 和根因记录位于 [docs](docs)。

## 贡献与许可

提交修改前请运行：

```powershell
& .\tools\Test-SourceLayout.ps1
& .\build-module.ps1
```

贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题见 [SECURITY.md](SECURITY.md)。项目采用 [Apache License 2.0](LICENSE)。
