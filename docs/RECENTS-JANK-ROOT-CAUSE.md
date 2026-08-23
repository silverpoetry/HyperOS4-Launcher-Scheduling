# 最近任务卡顿的逐帧归因

## 测试范围

测试设备为 Sheng，刷新率为 120 Hz，单帧预算为 8.33 ms。前台运行金铲铲，连续四轮执行屏幕三指上滑进入最近任务、停留、点击当前任务卡片返回应用。

测试使用 v4 调度模块。源应用在 Launcher 接管后被限制到后台 CPU，Launcher 的 `1.ui`、`1.raster` 和 Rust 线程策略保持开启。分析按实际 FrameTimeline 帧区间统计线程的 Running、Runnable、Sleeping 状态，不把父子切片或并行线程的墙钟时间相加。

本次采集目录如下；结论写入本文后，约 85 MB 的原始 trace 已按项目空间策略清理：

```text
test-results/sheng-jkchess-recents-warm-20260823-211819
```

## 结论

卡顿不是某个游戏对应了特殊的卡片实现，也不是 Floating Dock 本身承担了主要绘制。主要问题由两部分叠加形成：

1. Launcher 主最近任务 Surface 的 Flutter/Impeller Vulkan 命令编码经常超过 8.33 ms；
2. `system_server` 同时进行高分辨率任务快照持久化，占用性能核并增加 Launcher Raster 线程的 Runnable 等待。

SurfaceFlinger、WindowManager 动画、状态栏和安全中心 Dock 在同一转场中并行工作，部分帧因此继续出现 CPU、GPU 或 Display HAL deadline miss。FrameTimeline 将某些失败帧标在 Floating Dock、StatusBar 或 DockAssistant 上，只说明该 Surface 的呈现错过了时限，不能据此认定它是主要计算来源。

## Launcher 实际绘制内容

Launcher 的 `1.raster` 线程在一次 Raster frame 中按顺序处理多个 Surface：

- `SurfaceFrame::Encode V:0` 对应 Launcher 主 Surface，包括最近任务主场景、任务卡片、背景和 transition leash；
- `SurfaceFrame::Encode V:1` 对应 Floating Dock。

这个映射可以从 Surface 的出现和消失交叉确认：只存在 Floating Dock 的帧只有 `V:1`；Floating Dock 消失后 `V:1` 归零，而主 Launcher Surface 和任务 transition leash 仍由 `V:0` 持续提交。

四轮测试中，Launcher Raster 的统计如下：

| 阶段 | Raster 帧数 | 超过 8 ms | P95 | 最大值 | `V:0 Encode` 最大值 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 第 1 轮进入 | 123 | 18 | 10.90 ms | 22.24 ms | 11.60 ms |
| 第 2 轮进入 | 135 | 9 | 9.30 ms | 15.01 ms | 11.20 ms |
| 第 3 轮进入 | 134 | 55 | 10.14 ms | 17.91 ms | 13.62 ms |
| 第 4 轮进入 | 129 | 21 | 11.66 ms | 22.56 ms | 14.39 ms |

典型严重帧为第 3 轮进入最近任务的 token `1027429`：

```text
GPURasterizer::Draw     17.906 ms
  V:0 Encode            13.619 ms
  V:1 Encode             1.452 ms
  LayerTree::Paint       0.224 ms
  Surface Present        0.819 ms
```

该 Raster 帧内线程状态为：

```text
Running                 12.274 ms
Runnable                 5.632 ms
Sleeping                 0.000 ms
```

因此它不是在等待 GPU fence，也不是 Flutter Widget 布局或 Paint 阶段过重。瓶颈在 Raster 线程的 CPU 侧 Vulkan 命令构造和提交，同时受到 CPU 调度排队影响。

`V:0 Encode` 内反复出现：

- `Canvas::saveLayer`；
- `Canvas::DrawHyperMaterial`；
- `CommandQueueVK::Submit` / `QueueSubmit`；
- 少量字形收集和命令缓冲分配。

部分单次 `DrawHyperMaterial` 达到约 5.08 ms，部分 `QueueSubmit` 达到约 11.14 ms。这里的 `QueueSubmit` 墙钟时间仍以 Running 和 Runnable 为主，不是单纯等待 GPU 完成。

Floating Dock 的 `V:1` 大多约为 0.2–2 ms，少数帧会更高，但不是四轮测试中持续出现的主要耗时。精简材质时应定位 `V:0` 最近任务主 Surface 内的 HyperMaterial/saveLayer，而不是全局关闭 Dock、控制中心或桌面玻璃效果。

## 任务快照持久化

进入最近任务时，`system_server` 的 `TaskSnapshotPersister` 会处理任务 136 的 3048×2032 快照。`takeTaskSnapshot` 负责抓取，随后 `StoreWriteQueueItem#136` 将 Buffer 映射、转换并写入持久化存储。

每轮进入最近任务都出现两个 `StoreWriteQueueItem`。两项合计的实际 CPU 时间为：

| 轮次 | CPU Running 合计 | Runnable 合计 |
| --- | ---: | ---: |
| 第 1 轮 | 291.24 ms | 536.30 ms |
| 第 2 轮 | 283.35 ms | 126.36 ms |
| 第 3 轮 | 278.35 ms | 162.40 ms |
| 第 4 轮 | 269.39 ms | 222.26 ms |

这不是一个长时间休眠的异步任务。每个写入项实际消耗约 120–162 ms CPU，并且会运行在 CPU 3–7，包括超大核 CPU 7。例如第 3 轮第一项在 CPU 4 上运行 86.15 ms，第二项在 CPU 7 上运行 115.91 ms。

第 4 轮 DockAssistant 被标记为 Full jank 的 20.57 ms 区间内同时发生：

```text
TaskSnapshotPersister   CPU 7 上运行 12.09 ms
Launcher 1.raster       CPU 3 上运行 10.54 ms
SurfaceFlinger          运行 7.40 ms
DockAssistant draw      墙钟 10.35 ms
```

快照持久化占用超大核后，Launcher Raster 只能继续在中核执行并排队。这能解释模块已经让源应用退到 CPU 0–2，转场仍不能稳定达到无负载状态。

任务卡片当前显示依赖内存中的快照；`StoreWriteQueueItem` 是后续持久化工作，不需要与当前转场争抢性能核。这是下一步最适合单独 A/B 的系统线程。

## Launcher 主线程的长 Callback

Launcher 主线程出现过 117–121 ms 的 `CALLBACK_ANIMATION`，但逐状态统计显示其中约 113–114 ms 为 Sleeping，实际 Running 只有约 3.2–3.6 ms。这个切片表示主线程同步等待转场或系统回调完成，不代表 Launcher 主线程进行了 120 ms 计算。

因此不应把该切片作为增加主线程频率或持续绑定超大核的依据。

## SurfaceFlinger

首轮存在一帧 `SurfaceFlinger CPU Deadline Missed`：SurfaceFlinger 主线程在 CPU 1 上运行约 10.28 ms，其中 commit 约 5.73 ms、composite 约 4.82 ms，超过 8.33 ms 帧预算。另一帧出现 `SurfaceFlinger GPU Deadline Missed`，同时有 Launcher Raster、RenderEngine、SurfaceFlinger 和 HWC 并行工作。

记录中有一帧受到采集进程 `traced_probes` 明显干扰，因此不能用单个 GPU miss 推导常驻策略。Launcher `V:0 Encode` 和 TaskSnapshotPersister 的结果在四轮中重复出现，不依赖该异常帧。

## 下一步最小 A/B

按风险和因果关系排序：

1. 将 `TaskSnapshotPersister` 长期限制到后台 CPU 0–2，保留任务快照抓取和持久化功能，只让异步持久化不再占用 Launcher 使用的 CPU 3–7；
2. 转场期间让 Launcher `1.raster` 独占或优先使用动态识别出的超大核，而不是仅允许在 CPU 3–7 之间由调度器选择；
3. 重新执行同一套四轮测试，检查 Raster Runnable、`V:0 Encode` P95 和 Full/Partial jank；
4. 若 CPU 隔离后 `V:0 Encode` 仍稳定超过 8.33 ms，再只对最近任务主 Surface 的 HyperMaterial/saveLayer 做单变量 A/B。

不应优先关闭 Floating Dock、状态栏或全局玻璃材质。这些对象有自己的少量工作，但现有记录不能支持它们是主要瓶颈。

## 复现分析

先用 `tools\Capture-JkchessRecents.ps1` 产生新的结果目录，再执行：

```powershell
python tools\summarize-recents-bottleneck.py <新的结果目录>
```

脚本会输出各阶段 Raster 分位数、最长 Raster 帧的内部工作、任务快照线程状态和 Launcher 主线程等待状态。
