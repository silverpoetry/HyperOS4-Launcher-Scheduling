# Sheng 后台负载下的 Launcher 调度验证

## 测试环境

设备为 Sheng，横屏逻辑尺寸 `3048×2032`。CPU 拓扑：

```text
CPU0-2  capacity 280   max 2.016 GHz
CPU3-6  capacity 855   max 2.803 GHz
CPU7    capacity 1024  max 3.187 GHz
```

官方 cpuset：

```text
top-app:    0-7
foreground: 0-6
background: 0-2
```

模块由此推导：

```text
perf:   f8  # CPU3-7
mid:    78  # CPU3-6
little: 07  # CPU0-2
```

腾讯会议主进程包含 199 个线程，位于 `cpuset/background` 和 `cpuctl/background`，允许 CPU0-2。测试前连续 2 秒测得 `1508 ms task-clock`；正式 A/B 窗口中保持约 53%–63% 单核占用。

## 测试方法

对三个手势场景各做三轮交替 A/B。奇数轮按 profile 1 → profile 2，偶数轮反向，降低温度和测试顺序的影响。

- profile 1：3.0 动画策略，UI、Raster 和 Rust 共用 `perf`；
- profile 2：3.1 动画策略，Raster 保持 `perf/min=928`，UI/Rust 使用 `mid/min=768/512`；
- `simpleperf` 记录 Launcher 目标线程的 per-thread/per-core task-clock；
- `/proc/<pid>/stat` 时钟差记录同一 2 秒窗口的腾讯会议负载；
- 轻量 FrameTimeline 记录 Launcher、SystemUI 层和 display frame。

Sheng 的 FrameTimeline 数据不提供可用的进程描述符，分析脚本使用 `layer_name` 识别 Launcher、状态栏、导航栏和 Floating Dock，并把无 surface token 的 display frame 归入 SurfaceFlinger。

## 负载等价性

| 场景 | profile 1 腾讯会议 CPU | profile 2 腾讯会议 CPU |
|---|---:|---:|
| 快回桌面 | 56.8% | 55.5% |
| 慢进最近任务 | 53.5% | 56.3% |
| 半程取消 | 56.2% | 55.0% |

两种策略下后台负载接近，可以进行配对比较。

## Launcher 线程结果

| 场景 | Raster CPU7：profile 1 | profile 2 | Raster task-clock | UI task-clock |
|---|---:|---:|---:|---:|
| 快回桌面 | 33.3% | 86.1% | -14.2% | +29.8% |
| 慢进最近任务 | 32.3% | 83.6% | -21.5% | +14.1% |
| 半程取消 | 28.9% | 77.1% | -16.0% | +13.6% |

profile 1 中 UI 会大量使用 CPU7，Raster 只有约三成 CPU 时间落在 CPU7。profile 2 将 CPU7 优先留给 Raster，使 Raster task-clock 明显下降。UI 在 capacity 855 的 CPU3-6 上需要更多 CPU 时间，这是分流的直接代价。

## FrameTimeline

| 场景 | Launcher 最大帧：profile 1 | profile 2 | Launcher p95：profile 1 | profile 2 | Full/Partial jank |
|---|---:|---:|---:|---:|---:|
| 快回桌面 | 11.845 ms | 11.386 ms | 6.253 ms | 6.233 ms | 0 / 0 |
| 慢进最近任务 | 18.172 ms | 16.479 ms | 11.380 ms | 10.149 ms | 0 / 0 |
| 半程取消 | 10.756 ms | 10.169 ms | 7.170 ms | 5.277 ms | 0 / 0 |

Launcher 自身没有 Full/Partial jank。快回桌面基本持平，慢进最近任务和半程取消的最大帧与 p95 均下降。

SurfaceFlinger 和 SystemUI 层的离群没有单向变化：快回桌面 profile 2 的离群更多，慢进最近任务的 SurfaceFlinger 离群更少，取消场景接近。因此本次测试能证明 3.1 改善 Launcher Raster 放置和 Launcher 帧分布，不能证明它消除系统合成侧的所有偶发掉帧。

## 运行状态核对

动画中实机读取：

```text
1.raster          affinity=f8  uclamp min=928
1.ui              affinity=78  uclamp min=768
rt-launcher-mai   affinity=78  uclamp min=512
IplrVkResMgr      affinity=78  uclamp min=384
IplrVkFenceWait   affinity=07  uclamp min=0
```

最后一个动画事件结束后，Raster/UI/Rust 恢复 `affinity=f8, uclamp min=0`，ResMgr 保持 `78/min=0`，Fence 保持 `07/min=0`。测试结束后 `stay_on_while_plugged_in=0`，没有 Perfetto 或 simpleperf 进程残留。
