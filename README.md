# HyperOS 4 最近任务源应用让路模块

这是一个通用 HyperOS 4 KernelSU 模块。进入最近任务时，模块把刚才位于前台的源应用临时放入设备自身定义的 `background` cgroup，避免源应用继续占用桌面、SystemUI 和显示合成链可使用的全部核心。

模块不替换系统框架或桌面 APK，不写死 CPU 编号，不锁定 CPU/GPU 频率，也不关闭模糊、玻璃材质或 Vulkan。

## 工作链路

1. 监听 Android EventLog 的 `wm_on_resume_called`，缓存最近恢复到前台的应用 PID。
2. 监听 `com.miui.home` 的 `onOverviewToggle`；`PassBlurWindow: on_create` 作为兼容后备信号。
3. 收到进入信号后，把源应用写入 `cpuset/background` 和 `cpuctl/background`。
4. 同时把动态壁纸和可选的 MIMD 服务放入后台组。
5. ActivityManager 在切换过程中可能再次把源应用提升到 `foreground`。模块在 120 ms 和 320 ms 两次确认源应用仍位于后台组。
6. 每次延迟操作都检查 generation 和前台恢复令牌。用户提前退出最近任务或恢复应用时，旧任务不会继续降低新的前台进程。
7. 一秒后恢复壁纸和 MIMD 原本的 cgroup。源应用由 ActivityManager 在再次打开时自然恢复。

进入信号采用 750 ms 去重，不依赖必须出现的退出日志。这样即使某轮缺少 `exitOverviewState`，下一次进入最近任务仍能正常触发。

## 核心兼容方式

模块只使用 cgroup 名称，不假设 CPU 编号与性能等级的对应关系。

小米 14 Pro（Shennong，Snapdragon 8 Gen 3）实测：

```text
background: 0-1,5-6
foreground: 0-7
top-app:    0-7
```

因此源应用退避后由设备自己的调度配置决定可运行核心。模块不会把 8 Gen 2 的核心编号复制到 8 Gen 3。

## Shennong A/B 结果

测试对象为微信，使用同一最近任务入口交替测试启用和禁用状态。原始记录在 `test-results/shennong-20260822-ab/`。

退避时序：

```text
进入信号到整组操作完成：30-110 ms（源应用首次写入早于整组完成）
ActivityManager 再次提升源应用：约 100-110 ms 后
第一次重新退避：120 ms
第二次重新退避：320 ms
禁用模块时系统自然降到 background：约 670-750 ms
```

进入后 250-750 ms 是两组差异最明确的窗口。只统计源应用在 Shennong 后台组不包含的 CPU `2-4,7` 上的运行时间：

```text
启用：0.000 ms、0.000 ms
禁用：5.304 ms、4.130 ms
禁用平均：4.717 ms / 次动画
```

模块没有减少源应用的总工作量。两轮 2 秒全核心统计波动较大，启用平均约 321.8 ms，禁用平均约 300.0 ms，不能据此认为总 CPU 负载下降。模块的作用是改变运行位置，减少关键窗口内对非后台核心的竞争。

## 监听开销

守护进程和两个监听器都位于 `background` cgroup。

```text
空闲 10 秒：所有模块常驻进程均为 0 CPU tick
连续 3 次最近任务动画：常驻进程合计 420 ms CPU
其中桌面 main 日志过滤器：380 ms CPU
```

活跃开销发生在桌面大量输出日志的动画期间，并且只运行在设备定义的后台核心。这个实现优先保证进入信号足够早；代价是动画期间有可测量的后台 CPU 和功耗开销。

## 安全边界

- 桌面、SystemUI、SurfaceFlinger、显示 HAL 和当前输入法不会被移动。
- 源应用不会被停止、冻结或限制总 CPU 占用率。
- 壁纸和 MIMD 的原始 cgroup 会在首次运行时记录，恢复和卸载时使用原值。
- 模块启动时清理自己遗留的旧监听实例，避免重复监听。
- 模块依赖 HyperOS 4 桌面的日志名称；桌面大版本更新后应重新验证进入信号。

## 目录结构

```text
module-src/       KernelSU 模块源码
dist/             构建后的 ZIP 和 SHA-256
tools/            短时验证脚本
test-results/     原始 A/B 数据和报告
support/          独立的设备测试辅助模块
build-module.ps1  Windows 构建脚本
```

## 构建与安装

在 PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& .\build-module.ps1
```

输出文件：

```text
dist/HyperOS4-Recents-Source-App-Yield-v1.1.zip
dist/HyperOS4-Recents-Source-App-Yield-v1.1.zip.sha256
```

在已经安装 KernelSU 和可用挂载实现的 HyperOS 4 设备上，通过 KernelSU 管理器安装 ZIP 并重启。模块操作按钮可以切换启用状态。

## 正式包校验值

```text
126d59b7c9cdfadc4aaa3a6e98f593be8c2bd2ce7b66822cc6860f4e0cd655bb
```
