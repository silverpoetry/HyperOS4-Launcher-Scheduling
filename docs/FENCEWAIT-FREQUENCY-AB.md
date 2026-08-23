# FenceWait 与小核限频 A/B

## 条件

设备为 Sheng，应用为 Android 设置。每组执行五轮进入最近任务和返回应用。两组的 policy0 `scaling_max_freq` 在测试前后均为 307200 kHz；来源应用、UI、Raster、Rust 和 ResMgr 策略保持不变，唯一变量是 `IplrVkFenceWait` 的 affinity。

| 组别 | FenceWait CPU | policy0 上限 |
| --- | --- | --- |
| A | CPU0-2 | 307200 kHz |
| B | CPU3-6 | 307200 kHz |

Perfetto 记录 FrameTimeline、Launcher/SystemUI atrace、调度切换和 CPU 频率。统计窗口为每轮手势开始至返回应用前。

## 结果

| 指标 | CPU0-2 | CPU3-6 | 变化 |
| --- | ---: | ---: | ---: |
| FenceWait 运行时间 | 554.940 ms | 94.141 ms | -83.0% |
| FenceWait runnable 等待 | 601.867 ms | 216.906 ms | -64.0% |
| FenceWait 最长 runnable 等待 | 12.156 ms | 4.045 ms | -66.7% |
| Launcher Full jank | 30 | 14 | -53.3% |
| Launcher 最大帧 | 88.272 ms | 70.309 ms | -20.4% |
| SurfaceFlinger Full jank | 39 | 32 | -17.9% |
| SystemUI Full + Partial | 77 | 76 | 基本不变 |

FenceWait 在 CPU0-2 上并非可以忽略的睡眠线程。极低频下，它在五轮窗口内累计占用约 555 ms CPU，并产生约 602 ms runnable 等待。移到 CPU3-6 后，同一工作只需约 94 ms CPU，Launcher Full jank 同时减半。SystemUI 没有相同幅度的变化，说明改善来自 Launcher 内部 Vulkan fence 链，而不是整体场景负载降低。

## 结论

来源应用被限制到小核后，可以对该小核 policy 限频；Launcher 的 `IplrVkFenceWait` 不能继续共享这组小核。正式默认值改为 CPU3-6 对应的动态 `mid` 集合，并在 WebUI 提供 `小核集合` 与 `中核集合` 两种放置。设备 CPU 编号仍由 cpuset 和 `cpu_capacity` 动态推导。
